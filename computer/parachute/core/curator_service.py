"""
Session Curator Service.

Background agent system that maintains session titles and updates context files
based on conversation content. Each chat session gets a companion curator
session that runs after messages complete.

Key design decisions:
- One curator task runs at a time (queue-based) to avoid context file conflicts
- Curators use Haiku for speed and cost efficiency
- Curator sessions persist, maintaining memory of past updates
- Auto-apply changes by default
- Users can peek at curator activity via API
"""

import asyncio
import json
import logging
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import aiosqlite

from parachute.db.database import Database
from parachute.models.session import SessionUpdate

logger = logging.getLogger(__name__)


# Note: CURATOR_SYSTEM_PROMPT is now in curator_tools.py with the restricted tools


@dataclass
class CuratorSession:
    """Represents a curator session linked to a chat session."""
    id: str
    parent_session_id: str
    sdk_session_id: Optional[str]
    last_run_at: Optional[datetime]
    last_message_index: int
    context_files: list[str]
    created_at: datetime


@dataclass
class CuratorTask:
    """A queued curator task."""
    id: int
    parent_session_id: str
    curator_session_id: Optional[str]
    trigger_type: str  # 'message_done', 'compact', 'manual'
    message_count: int
    queued_at: datetime
    started_at: Optional[datetime]
    completed_at: Optional[datetime]
    status: str  # 'pending', 'running', 'completed', 'failed'
    result: Optional[dict]
    error: Optional[str]


class CuratorService:
    """
    Manages curator sessions and task queue.

    Each chat session can have a companion curator session that:
    - Generates/updates session titles
    - Updates context files with new learnings

    Tasks are queued and processed one at a time to avoid conflicts.
    """

    def __init__(self, db: Database, vault_path: Path):
        self.db = db
        self.vault_path = vault_path
        self._worker_task: Optional[asyncio.Task] = None
        self._shutdown = False
        self._queue_event = asyncio.Event()

    async def start_worker(self) -> None:
        """Start the background worker that processes curator tasks."""
        if self._worker_task is not None:
            logger.warning("Curator worker already running")
            return

        self._shutdown = False
        self._worker_task = asyncio.create_task(self._worker_loop())
        logger.info("Curator worker started")

    async def stop_worker(self) -> None:
        """Stop the background worker gracefully."""
        if self._worker_task is None:
            return

        self._shutdown = True
        self._queue_event.set()  # Wake up the worker

        try:
            await asyncio.wait_for(self._worker_task, timeout=10.0)
        except asyncio.TimeoutError:
            logger.warning("Curator worker didn't stop gracefully, cancelling")
            self._worker_task.cancel()
            try:
                await self._worker_task
            except asyncio.CancelledError:
                pass

        self._worker_task = None
        logger.info("Curator worker stopped")

    # =========================================================================
    # Queue Management
    # =========================================================================

    async def queue_task(
        self,
        parent_session_id: str,
        trigger_type: str = "message_done",
        message_count: int = 0,
        context_files: Optional[list[str]] = None,
    ) -> int:
        """
        Queue a curator task for a session.

        Returns the task ID.
        """
        # Get or create curator session
        curator_session = await self.get_or_create_curator_session(
            parent_session_id, context_files
        )

        # Insert task into queue
        now = datetime.now(timezone.utc).isoformat()
        async with self.db.connection.execute(
            """
            INSERT INTO curator_queue
            (parent_session_id, curator_session_id, trigger_type, message_count, queued_at, status)
            VALUES (?, ?, ?, ?, ?, 'pending')
            """,
            (parent_session_id, curator_session.id, trigger_type, message_count, now),
        ) as cursor:
            task_id = cursor.lastrowid

        await self.db.connection.commit()

        logger.info(f"Queued curator task {task_id} for session {parent_session_id}")

        # Wake up the worker
        self._queue_event.set()

        return task_id

    async def get_pending_task(self) -> Optional[CuratorTask]:
        """Get the next pending task from the queue."""
        async with self.db.connection.execute(
            """
            SELECT * FROM curator_queue
            WHERE status = 'pending'
            ORDER BY queued_at ASC
            LIMIT 1
            """
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                return self._row_to_task(row)
            return None

    async def update_task_status(
        self,
        task_id: int,
        status: str,
        result: Optional[dict] = None,
        error: Optional[str] = None,
    ) -> None:
        """Update a task's status."""
        now = datetime.now(timezone.utc).isoformat()

        if status == "running":
            await self.db.connection.execute(
                "UPDATE curator_queue SET status = ?, started_at = ? WHERE id = ?",
                (status, now, task_id),
            )
        elif status in ("completed", "failed"):
            result_json = json.dumps(result) if result else None
            await self.db.connection.execute(
                "UPDATE curator_queue SET status = ?, completed_at = ?, result = ?, error = ? WHERE id = ?",
                (status, now, result_json, error, task_id),
            )
        else:
            await self.db.connection.execute(
                "UPDATE curator_queue SET status = ? WHERE id = ?",
                (status, task_id),
            )

        await self.db.connection.commit()

    async def get_task(self, task_id: int) -> Optional[CuratorTask]:
        """Get a task by ID."""
        async with self.db.connection.execute(
            "SELECT * FROM curator_queue WHERE id = ?", (task_id,)
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                return self._row_to_task(row)
            return None

    async def get_tasks_for_session(
        self, parent_session_id: str, limit: int = 20
    ) -> list[CuratorTask]:
        """Get recent tasks for a session."""
        async with self.db.connection.execute(
            """
            SELECT * FROM curator_queue
            WHERE parent_session_id = ?
            ORDER BY queued_at DESC
            LIMIT ?
            """,
            (parent_session_id, limit),
        ) as cursor:
            rows = await cursor.fetchall()
            return [self._row_to_task(row) for row in rows]

    # =========================================================================
    # Curator Session Management
    # =========================================================================

    async def get_or_create_curator_session(
        self,
        parent_session_id: str,
        context_files: Optional[list[str]] = None,
    ) -> CuratorSession:
        """Get existing curator session or create a new one."""
        # Try to get existing
        async with self.db.connection.execute(
            "SELECT * FROM curator_sessions WHERE parent_session_id = ?",
            (parent_session_id,),
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                return self._row_to_curator_session(row)

        # Create new
        curator_id = f"curator-{uuid.uuid4()}"
        now = datetime.now(timezone.utc).isoformat()
        context_files_json = json.dumps(context_files or [])

        await self.db.connection.execute(
            """
            INSERT INTO curator_sessions
            (id, parent_session_id, context_files, created_at)
            VALUES (?, ?, ?, ?)
            """,
            (curator_id, parent_session_id, context_files_json, now),
        )
        await self.db.connection.commit()

        logger.info(f"Created curator session {curator_id} for {parent_session_id}")

        return CuratorSession(
            id=curator_id,
            parent_session_id=parent_session_id,
            sdk_session_id=None,
            last_run_at=None,
            last_message_index=0,
            context_files=context_files or [],
            created_at=datetime.now(timezone.utc),
        )

    async def update_curator_session(
        self,
        curator_id: str,
        sdk_session_id: Optional[str] = None,
        last_message_index: Optional[int] = None,
    ) -> None:
        """Update curator session after a run."""
        updates = []
        params = []

        now = datetime.now(timezone.utc).isoformat()
        updates.append("last_run_at = ?")
        params.append(now)

        if sdk_session_id is not None:
            updates.append("sdk_session_id = ?")
            params.append(sdk_session_id)

        if last_message_index is not None:
            updates.append("last_message_index = ?")
            params.append(last_message_index)

        params.append(curator_id)

        await self.db.connection.execute(
            f"UPDATE curator_sessions SET {', '.join(updates)} WHERE id = ?",
            params,
        )
        await self.db.connection.commit()

    async def get_curator_session(self, parent_session_id: str) -> Optional[CuratorSession]:
        """Get curator session for a chat session."""
        async with self.db.connection.execute(
            "SELECT * FROM curator_sessions WHERE parent_session_id = ?",
            (parent_session_id,),
        ) as cursor:
            row = await cursor.fetchone()
            if row:
                return self._row_to_curator_session(row)
            return None

    # =========================================================================
    # Worker Loop
    # =========================================================================

    async def _worker_loop(self) -> None:
        """Background worker that processes curator tasks one at a time."""
        logger.info("Curator worker loop started")

        while not self._shutdown:
            try:
                # Get next pending task
                task = await self.get_pending_task()

                if task is None:
                    # No tasks, wait for signal or timeout
                    self._queue_event.clear()
                    try:
                        await asyncio.wait_for(
                            self._queue_event.wait(),
                            timeout=30.0  # Check every 30 seconds even without signal
                        )
                    except asyncio.TimeoutError:
                        pass
                    continue

                # Process the task
                await self._process_task(task)

            except Exception as e:
                logger.error(f"Curator worker error: {e}", exc_info=True)
                # Don't crash the worker on errors, just continue
                await asyncio.sleep(5.0)

        logger.info("Curator worker loop exiting")

    async def _process_task(self, task: CuratorTask) -> None:
        """Process a single curator task."""
        logger.info(f"Processing curator task {task.id} for session {task.parent_session_id}")

        await self.update_task_status(task.id, "running")

        try:
            result = await self._run_curator(task)
            await self.update_task_status(task.id, "completed", result=result)
            logger.info(f"Curator task {task.id} completed: {result}")

        except Exception as e:
            logger.error(f"Curator task {task.id} failed: {e}", exc_info=True)
            await self.update_task_status(task.id, "failed", error=str(e))

    async def _run_curator(self, task: CuratorTask) -> dict[str, Any]:
        """
        Run the curator agent for a task.

        This is where we invoke the Claude SDK to:
        1. Analyze recent messages
        2. Update title if needed
        3. Update context files if needed
        """
        # Import here to avoid circular imports
        from parachute.core.session_manager import SessionManager

        # Get parent session info
        parent_session = await self.db.get_session(task.parent_session_id)
        if not parent_session:
            return {"error": "Parent session not found"}

        # Get curator session
        curator_session = await self.get_curator_session(task.parent_session_id)
        if not curator_session:
            return {"error": "Curator session not found"}

        # Get recent messages from parent session
        session_manager = SessionManager(self.vault_path, self.db)
        messages = await session_manager.get_session_messages(
            task.parent_session_id,
            after_index=curator_session.last_message_index,
        )

        if not messages:
            logger.info(f"No new messages to curate for {task.parent_session_id}")
            return {"skipped": True, "reason": "No new messages"}

        # Build context for curator
        context = self._build_curator_context(
            parent_session=parent_session,
            messages=messages,
            context_files=curator_session.context_files,
        )

        # Run curator agent
        result = await self._invoke_curator_agent(
            curator_session=curator_session,
            context=context,
            parent_session=parent_session,
        )

        # Update curator session tracking
        new_message_index = curator_session.last_message_index + len(messages)
        await self.update_curator_session(
            curator_session.id,
            sdk_session_id=result.get("sdk_session_id"),
            last_message_index=new_message_index,
        )

        return result

    def _build_curator_context(
        self,
        parent_session: Any,
        messages: list[dict],
        context_files: list[str],
    ) -> str:
        """Build the context string to send to the curator agent."""
        parts = []

        # Session info
        parts.append(f"## Session to Curate")
        parts.append(f"Session ID: {parent_session.id}")
        parts.append(f"Current Title: {parent_session.title or '(untitled)'}")
        parts.append(f"Message Count: {parent_session.message_count}")
        parts.append("")

        # Context files being tracked
        if context_files:
            parts.append(f"## Context Files")
            parts.append(f"Files to potentially update: {', '.join(context_files)}")
            parts.append("")

        # Recent messages
        parts.append("## Recent Conversation")
        for msg in messages:
            role = msg.get("role", "unknown")
            content = msg.get("content", "")
            if isinstance(content, list):
                # Handle structured content
                text_parts = [
                    c.get("text", "") for c in content
                    if isinstance(c, dict) and c.get("type") == "text"
                ]
                content = "\n".join(text_parts)
            # Truncate very long messages
            if len(content) > 2000:
                content = content[:2000] + "...(truncated)"
            parts.append(f"**{role.title()}**: {content}")
            parts.append("")

        return "\n".join(parts)

    async def _invoke_curator_agent(
        self,
        curator_session: CuratorSession,
        context: str,
        parent_session: Any,
    ) -> dict[str, Any]:
        """
        Invoke the curator agent using Claude SDK with restricted tools.

        The curator evaluates both title and context updates with appropriate
        conservatism levels. It has access ONLY to curator-specific tools
        with no general file access or shell commands.
        """
        from parachute.core.curator_tools import (
            CURATOR_TITLE_PROMPT,
            CURATOR_SYSTEM_PROMPT,
        )

        result: dict[str, Any] = {
            "title_updated": False,
            "context_updated": False,
            "actions": [],
            "sdk_session_id": curator_session.sdk_session_id,
        }

        # Determine what kind of curation is needed
        is_untitled = not parent_session.title or parent_session.title == "(untitled)"

        # Only use simple title generation for truly untitled sessions
        # Once a session has a title (even from the first message), use conservative evaluation
        use_simple_title_gen = is_untitled

        try:
            from claude_code_sdk import query as sdk_query, ClaudeCodeOptions

            if use_simple_title_gen:
                # Simple title generation for new sessions
                result = await self._generate_title_simple(
                    context, parent_session, result
                )
            else:
                # Full curator evaluation for established sessions
                result = await self._run_full_curator(
                    curator_session, context, parent_session, result
                )

        except ImportError as e:
            logger.warning(f"Claude SDK not available, falling back to heuristic: {e}")
            result = await self._invoke_curator_fallback(curator_session, context, parent_session)

        except Exception as e:
            logger.error(f"Curator agent error: {e}", exc_info=True)
            result["error"] = str(e)
            # Fall back to heuristic for title if needed
            if not parent_session.title or parent_session.title == "(untitled)":
                fallback = await self._invoke_curator_fallback(curator_session, context, parent_session)
                result.update(fallback)

        return result

    async def _generate_title_simple(
        self,
        context: str,
        parent_session: Any,
        result: dict[str, Any],
    ) -> dict[str, Any]:
        """Simple title generation for new sessions."""
        from claude_code_sdk import query as sdk_query, ClaudeCodeOptions
        from parachute.core.curator_tools import CURATOR_TITLE_PROMPT

        options = ClaudeCodeOptions(
            system_prompt=CURATOR_TITLE_PROMPT,
            max_turns=1,
            allowed_tools=[],
        )

        prompt = f"Generate a title for this conversation:\n\n{context}"
        logger.info(f"Running simple title generation for session {parent_session.id}")

        generated_title = ""
        async for event in sdk_query(prompt=prompt, options=options):
            if hasattr(event, "content"):
                for block in event.content:
                    if hasattr(block, "text"):
                        generated_title += block.text
            if hasattr(event, "session_id") and event.session_id:
                result["sdk_session_id"] = event.session_id

        # Clean up and save
        generated_title = generated_title.strip().strip('"').strip("'")
        if generated_title and len(generated_title) < 200:
            await self.db.update_session(
                parent_session.id,
                SessionUpdate(title=generated_title),
            )
            result["title_updated"] = True
            result["new_title"] = generated_title
            result["actions"].append(f"Updated title to: {generated_title}")
            logger.info(f"Curator set title for {parent_session.id}: {generated_title}")
        else:
            logger.warning(f"Generated title invalid: {generated_title[:100] if generated_title else 'empty'}")

        return result

    async def _run_full_curator(
        self,
        curator_session: CuratorSession,
        context: str,
        parent_session: Any,
        result: dict[str, Any],
    ) -> dict[str, Any]:
        """
        Run full curator evaluation for title and context updates.

        The curator responds with a JSON object specifying what updates to make,
        and we execute those updates directly.
        """
        from claude_code_sdk import query as sdk_query, ClaudeCodeOptions
        from parachute.core.curator_tools import CURATOR_SYSTEM_PROMPT
        from parachute.core.context_parser import ContextParser

        # Build a richer prompt with current state and context file info
        current_title = parent_session.title or "(untitled)"

        # Get summary of all available context files
        parser = ContextParser(self.vault_path)
        context_summary = parser.get_context_summary()

        # Get details of loaded context files (facts, etc.)
        loaded_files_detail = ""
        if curator_session.context_files:
            loaded_details = []
            for file_path_str in curator_session.context_files:
                # Extract just the filename
                file_name = file_path_str.split("/")[-1] if "/" in file_path_str else file_path_str
                file_path = self.vault_path / "Chat" / "contexts" / file_name
                if file_path.exists():
                    ctx = parser.parse_file(file_path)
                    if ctx.facts:
                        facts_str = "\n".join(f"  - {f}" for f in ctx.facts[:5])
                        loaded_details.append(f"**{ctx.name}** facts:\n{facts_str}")
            if loaded_details:
                loaded_files_detail = "\n".join(loaded_details)

        prompt = f"""## Current State
- **Current Title**: {current_title}
- **Message Count**: {parent_session.message_count}

## {context_summary}

{f"## Loaded Context Details (subset)\n{loaded_files_detail}" if loaded_files_detail else ""}

## Recent Conversation
{context}

## Your Task
Evaluate whether the title or context files need updating based on the conversation above.

Guidelines:
- Be conservative with title changes (only if direction meaningfully shifted)
- Route context updates to the most specific file
- Use `update_facts` to modify existing facts, `append_history` for events
- Create new files only for significant new projects/topics

Respond with ONLY a JSON object as specified in your instructions.
"""

        logger.info(f"Running full curator evaluation for session {parent_session.id}")

        options = ClaudeCodeOptions(
            system_prompt=CURATOR_SYSTEM_PROMPT,
            max_turns=1,  # Single turn - just get the JSON response
            allowed_tools=[],  # No tools needed - we execute based on JSON
        )

        response_text = ""
        async for event in sdk_query(prompt=prompt, options=options):
            if hasattr(event, "content"):
                for block in event.content:
                    if hasattr(block, "text"):
                        response_text += block.text
            if hasattr(event, "session_id") and event.session_id:
                result["sdk_session_id"] = event.session_id

        # Parse the JSON response and execute actions
        result = await self._execute_curator_actions(
            response_text, parent_session, curator_session, result
        )

        return result

    async def _execute_curator_actions(
        self,
        response_text: str,
        parent_session: Any,
        curator_session: CuratorSession,
        result: dict[str, Any],
    ) -> dict[str, Any]:
        """
        Parse the curator's JSON response and execute any requested actions.

        Supports both old format (update_context) and new format (context_actions).
        """
        import re
        from parachute.core.context_parser import ContextParser

        # Try to extract JSON from the response
        # Handle cases where it might be wrapped in ```json ... ```
        json_match = re.search(r'```json\s*(.*?)\s*```', response_text, re.DOTALL)
        if json_match:
            json_str = json_match.group(1)
        else:
            # Try to find a raw JSON object
            json_match = re.search(r'\{.*\}', response_text, re.DOTALL)
            if json_match:
                json_str = json_match.group(0)
            else:
                logger.warning(f"Curator response not valid JSON: {response_text[:200]}")
                result["error"] = "Invalid JSON response from curator"
                return result

        try:
            response = json.loads(json_str)
        except json.JSONDecodeError as e:
            logger.warning(f"Failed to parse curator JSON: {e}, response: {json_str[:200]}")
            result["error"] = f"JSON parse error: {e}"
            return result

        # Log reasoning
        reasoning = response.get("reasoning", "No reasoning provided")
        logger.info(f"Curator reasoning for {parent_session.id}: {reasoning}")
        result["reasoning"] = reasoning

        # Execute title update if requested
        new_title = response.get("update_title")
        if new_title and isinstance(new_title, str):
            new_title = new_title.strip()
            if new_title and len(new_title) < 200:
                await self.db.update_session(
                    parent_session.id,
                    SessionUpdate(title=new_title),
                )
                result["title_updated"] = True
                result["new_title"] = new_title
                result["actions"].append(f"Updated title to: {new_title}")
                logger.info(f"Curator updated title for {parent_session.id}: {new_title}")

        # Handle new format: context_actions array
        context_actions = response.get("context_actions", [])
        if context_actions:
            parser = ContextParser(self.vault_path)
            for action_obj in context_actions:
                success = await self._execute_single_context_action(action_obj, parser)
                if success:
                    result["context_updated"] = True
                    action_type = action_obj.get("action", "unknown")
                    file_name = action_obj.get("file", "unknown")
                    result["actions"].append(f"{action_type}: {file_name}")

        # Handle old format: update_context object (backwards compatibility)
        context_update = response.get("update_context")
        if context_update and isinstance(context_update, dict) and not context_actions:
            file_name = context_update.get("file", "").strip()
            content = context_update.get("content", "").strip()

            if file_name and content:
                success = await self._append_to_context_file(file_name, content)
                if success:
                    result["context_updated"] = True
                    result["actions"].append(f"Updated context file: {file_name}")
                    logger.info(f"Curator updated context file {file_name} for {parent_session.id}")
                else:
                    logger.warning(f"Failed to update context file {file_name}")

        # If no updates were made
        if not result.get("title_updated") and not result.get("context_updated"):
            logger.info(f"Curator: No updates needed for {parent_session.id}")

        return result

    async def _execute_single_context_action(
        self,
        action_obj: dict[str, Any],
        parser: "ContextParser",
    ) -> bool:
        """
        Execute a single context action from the curator.

        Supports:
        - update_facts: Replace facts section
        - update_focus: Replace current focus section
        - append_history: Append to history section
        - create_file: Create a new context file
        """
        from parachute.core.context_parser import ContextParser

        action_type = action_obj.get("action", "")
        file_name = action_obj.get("file", "").strip()

        if not action_type or not file_name:
            logger.warning(f"Invalid context action: missing action or file")
            return False

        # Security: validate file_name has no path components
        if "/" in file_name or "\\" in file_name or ".." in file_name:
            logger.warning(f"Invalid context file name (path chars): {file_name}")
            return False

        # Ensure .md extension
        if not file_name.endswith(".md"):
            file_name = file_name + ".md"

        contexts_dir = self.vault_path / "Chat" / "contexts"
        contexts_dir.mkdir(parents=True, exist_ok=True)
        file_path = contexts_dir / file_name

        # Verify it resolves to within contexts_dir
        try:
            resolved = file_path.resolve()
            if not str(resolved).startswith(str(contexts_dir.resolve())):
                logger.warning(f"Context file path escapes contexts dir: {file_name}")
                return False
        except Exception:
            logger.warning(f"Invalid context file path: {file_name}")
            return False

        try:
            if action_type == "update_facts":
                facts = action_obj.get("facts", [])
                if not isinstance(facts, list):
                    logger.warning(f"update_facts: facts must be a list")
                    return False

                if not file_path.exists():
                    # Create minimal file first
                    name = file_name.replace(".md", "").replace("-", " ").title()
                    file_path.write_text(f"# {name}\n\n---\n\n## Facts\n", encoding="utf-8")

                return parser.update_facts(file_path, facts)

            elif action_type == "update_focus":
                focus = action_obj.get("focus", [])
                if not isinstance(focus, list):
                    logger.warning(f"update_focus: focus must be a list")
                    return False

                if not file_path.exists():
                    logger.warning(f"update_focus: file doesn't exist: {file_name}")
                    return False

                return parser.update_current_focus(file_path, focus)

            elif action_type == "append_history":
                entry = action_obj.get("entry", "").strip()
                if not entry:
                    logger.warning(f"append_history: empty entry")
                    return False

                if not file_path.exists():
                    logger.warning(f"append_history: file doesn't exist: {file_name}")
                    return False

                return parser.append_history(file_path, entry)

            elif action_type == "create_file":
                if file_path.exists():
                    logger.warning(f"create_file: file already exists: {file_name}")
                    return False

                name = action_obj.get("name", file_name.replace(".md", ""))
                description = action_obj.get("description", "")
                facts = action_obj.get("facts", [])

                # Build new file content
                content_parts = [f"# {name}"]
                if description:
                    content_parts.append(f"\n> {description}")
                content_parts.append("\n\n---\n")

                if facts:
                    content_parts.append("\n## Facts\n")
                    for fact in facts:
                        content_parts.append(f"- {fact}\n")

                content_parts.append("\n## History\n")

                file_path.write_text("".join(content_parts), encoding="utf-8")
                logger.info(f"Curator created new context file: {file_name}")
                return True

            else:
                logger.warning(f"Unknown context action type: {action_type}")
                return False

        except Exception as e:
            logger.error(f"Error executing context action {action_type}: {e}")
            return False

    async def _append_to_context_file(self, file_name: str, content: str) -> bool:
        """
        Safely append content to a context file.

        Security checks:
        - File must be in Chat/contexts/ directory
        - No path traversal allowed
        - Append-only (no overwrite)
        """
        from datetime import datetime, timezone

        # Security: validate file_name has no path components
        if "/" in file_name or "\\" in file_name or ".." in file_name:
            logger.warning(f"Invalid context file name (path chars): {file_name}")
            return False

        # Ensure .md extension
        if not file_name.endswith(".md"):
            file_name = file_name + ".md"

        # Build safe path
        contexts_dir = self.vault_path / "Chat" / "contexts"
        contexts_dir.mkdir(parents=True, exist_ok=True)
        target_path = contexts_dir / file_name

        # Verify it resolves to within contexts_dir (prevent symlink attacks)
        try:
            resolved = target_path.resolve()
            if not str(resolved).startswith(str(contexts_dir.resolve())):
                logger.warning(f"Context file path escapes contexts dir: {file_name}")
                return False
        except Exception:
            logger.warning(f"Invalid context file path: {file_name}")
            return False

        try:
            # Append-only operation with timestamp
            timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
            formatted_addition = f"\n\n<!-- Added by curator on {timestamp} -->\n{content}"

            with open(target_path, "a", encoding="utf-8") as f:
                f.write(formatted_addition)

            return True
        except Exception as e:
            logger.error(f"Failed to write context file: {e}")
            return False

    def _process_curator_event(self, event: Any, result: dict[str, Any]) -> dict[str, Any]:
        """Process SDK event and update result tracking."""
        event_dict: dict[str, Any] = {}

        # Check for tool use in assistant messages
        if hasattr(event, "content"):
            for block in event.content:
                if hasattr(block, "name"):
                    tool_name = block.name
                    if "update_title" in tool_name:
                        result["title_updated"] = True
                        if hasattr(block, "input"):
                            new_title = block.input.get("new_title", "")
                            result["actions"].append(f"Updated title to: {new_title}")
                    elif "update_context" in tool_name:
                        result["context_updated"] = True
                        if hasattr(block, "input"):
                            file_name = block.input.get("file_name", "")
                            result["actions"].append(f"Updated context file: {file_name}")

        return event_dict

    async def _invoke_curator_fallback(
        self,
        curator_session: CuratorSession,
        context: str,
        parent_session: Any,
    ) -> dict[str, Any]:
        """
        Fallback curator using simple heuristics when SDK is unavailable.
        """
        result = {
            "title_updated": False,
            "context_updated": False,
            "actions": [],
            "fallback": True,
        }

        # Simple title generation heuristic
        if not parent_session.title or parent_session.title == "(untitled)":
            new_title = self._generate_simple_title(context)
            if new_title:
                await self.db.update_session(
                    parent_session.id,
                    SessionUpdate(title=new_title),
                )
                result["title_updated"] = True
                result["new_title"] = new_title
                result["actions"].append(f"Updated title to: {new_title}")

        return result

    def _generate_simple_title(self, context: str) -> Optional[str]:
        """
        Generate a simple title from context using heuristics.
        """
        import re
        match = re.search(r'\*\*User\*\*:\s*(.+?)(?:\n|$)', context)
        if match:
            first_message = match.group(1).strip()
            if len(first_message) > 60:
                words = first_message[:60].split()
                if len(words) > 3:
                    first_message = " ".join(words[:-1]) + "..."
                else:
                    first_message = first_message[:57] + "..."
            return first_message
        return None

    # =========================================================================
    # Helpers
    # =========================================================================

    def _row_to_curator_session(self, row: aiosqlite.Row) -> CuratorSession:
        """Convert database row to CuratorSession."""
        context_files = []
        if row["context_files"]:
            try:
                context_files = json.loads(row["context_files"])
            except json.JSONDecodeError:
                pass

        last_run_at = None
        if row["last_run_at"]:
            last_run_at = datetime.fromisoformat(row["last_run_at"])

        return CuratorSession(
            id=row["id"],
            parent_session_id=row["parent_session_id"],
            sdk_session_id=row["sdk_session_id"],
            last_run_at=last_run_at,
            last_message_index=row["last_message_index"] or 0,
            context_files=context_files,
            created_at=datetime.fromisoformat(row["created_at"]),
        )

    def _row_to_task(self, row: aiosqlite.Row) -> CuratorTask:
        """Convert database row to CuratorTask."""
        result = None
        if row["result"]:
            try:
                result = json.loads(row["result"])
            except json.JSONDecodeError:
                pass

        started_at = None
        if row["started_at"]:
            started_at = datetime.fromisoformat(row["started_at"])

        completed_at = None
        if row["completed_at"]:
            completed_at = datetime.fromisoformat(row["completed_at"])

        return CuratorTask(
            id=row["id"],
            parent_session_id=row["parent_session_id"],
            curator_session_id=row["curator_session_id"],
            trigger_type=row["trigger_type"],
            message_count=row["message_count"] or 0,
            queued_at=datetime.fromisoformat(row["queued_at"]),
            started_at=started_at,
            completed_at=completed_at,
            status=row["status"],
            result=result,
            error=row["error"],
        )


# Global curator service instance
_curator_service: Optional[CuratorService] = None


async def get_curator_service() -> CuratorService:
    """Get the global curator service instance."""
    global _curator_service
    if _curator_service is None:
        raise RuntimeError("Curator service not initialized")
    return _curator_service


async def init_curator_service(db: Database, vault_path: Path) -> CuratorService:
    """Initialize the global curator service."""
    global _curator_service
    _curator_service = CuratorService(db, vault_path)
    await _curator_service.start_worker()
    return _curator_service


async def stop_curator_service() -> None:
    """Stop the global curator service."""
    global _curator_service
    if _curator_service:
        await _curator_service.stop_worker()
        _curator_service = None
