"""
Session Curator Service.

A long-running parallel agent that maintains session titles and updates context
files based on conversation content. Each chat session gets a companion curator
that watches the conversation as it evolves and has full memory of its actions.

Key design decisions:
- Curator is a LONG-RUNNING parallel agent with session continuity
- Uses real tool access (update_title, update_context) instead of JSON parsing
- Gets message digests: user prompt, tool list (no full I/O), final response
- One curator task runs at a time (queue-based) to avoid context file conflicts
- Uses configurable model (curator_model setting, defaults to account default)
- Auto-applies changes with conservative guidelines
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
        """
        Build a message digest for the curator agent.

        Format:
        - User's prompt (full text)
        - Tool calls (just names, no full I/O)
        - Final assistant response

        This gives the curator enough context without overwhelming it.
        """
        parts = []

        # Session info (only on first run for this session)
        parts.append(f"## Message Digest for Session: {parent_session.id}")
        parts.append(f"Current Title: {parent_session.title or '(untitled)'}")
        parts.append("")

        # Process messages to extract digest format
        for msg in messages:
            role = msg.get("role", "unknown")
            content = msg.get("content", "")

            if role == "user":
                # Include full user prompt
                user_text = self._extract_text_content(content)
                if user_text:
                    parts.append(f"### User Message")
                    parts.append(user_text[:3000] if len(user_text) > 3000 else user_text)
                    parts.append("")

            elif role == "assistant":
                # For assistant, extract tool calls (names only) and final text
                tool_calls = self._extract_tool_names(content)
                final_text = self._extract_text_content(content)

                if tool_calls:
                    parts.append(f"### Tools Used")
                    parts.append(", ".join(tool_calls))
                    parts.append("")

                if final_text:
                    parts.append(f"### Assistant Response")
                    # Truncate long responses
                    if len(final_text) > 2000:
                        final_text = final_text[:2000] + "...(truncated)"
                    parts.append(final_text)
                    parts.append("")

        return "\n".join(parts)

    def _extract_text_content(self, content: Any) -> str:
        """Extract text from message content (handles string or list format)."""
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            text_parts = []
            for c in content:
                if isinstance(c, dict):
                    if c.get("type") == "text":
                        text_parts.append(c.get("text", ""))
            return "\n".join(text_parts)
        return ""

    def _extract_tool_names(self, content: Any) -> list[str]:
        """Extract tool names from assistant message content."""
        tool_names = []
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict):
                    # Handle tool_use blocks
                    if c.get("type") == "tool_use":
                        tool_names.append(c.get("name", "unknown_tool"))
                    # Handle tool calls in different formats
                    elif c.get("type") == "tool_call":
                        tool_names.append(c.get("name", "unknown_tool"))
        return tool_names

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

        # Detect placeholder titles (auto-generated from first message)
        # These end with "..." and are just truncated user messages
        is_placeholder_title = (
            parent_session.title and
            parent_session.title.endswith("...") and
            len(parent_session.title) <= 65  # max_length + "..."
        )

        # Use simple title generation for untitled OR placeholder-titled sessions
        # Once a session has a proper title (not placeholder), use conservative evaluation
        use_simple_title_gen = is_untitled or is_placeholder_title

        logger.info(
            f"Curator decision for {parent_session.id}: "
            f"is_untitled={is_untitled}, is_placeholder={is_placeholder_title}, "
            f"use_simple_title_gen={use_simple_title_gen}, "
            f"current_title='{parent_session.title[:50] if parent_session.title else None}...'"
        )

        try:
            from claude_agent_sdk import query as sdk_query, ClaudeAgentOptions

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
        from claude_agent_sdk import query as sdk_query, ClaudeAgentOptions
        from parachute.core.curator_tools import CURATOR_TITLE_PROMPT

        options = ClaudeAgentOptions(
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
        Run full curator evaluation as a long-running parallel agent.

        The curator:
        - Resumes its SDK session for continuity (memory of past actions)
        - Has real tool access via in-process MCP server (update_title, update_context, etc.)
        - Receives message digests, not raw conversation data
        """
        from claude_agent_sdk import query as sdk_query, ClaudeAgentOptions
        from parachute.core.curator_tools import CURATOR_SYSTEM_PROMPT, create_curator_tools
        from parachute.config import get_settings

        settings = get_settings()

        # Build the prompt with message digest
        prompt = f"""New message exchange completed. Here's the digest:

{context}

## Your Task
Evaluate if any updates are needed:
1. Use `list_context_files` to see available context files
2. Use `update_title` if the title needs changing (be very conservative!)
3. Use `update_context` to log significant milestones (be conservative!)

Remember:
- Be very conservative with title changes (only if project prefix is wrong or title is misleading)
- Only log significant milestones to context, not routine work
- Check your memory of past actions - don't duplicate entries
- Most message digests require NO action

If no updates are needed, just say "No updates needed" and explain briefly why.
"""

        logger.info(f"Running curator agent for session {parent_session.id} (resume: {curator_session.sdk_session_id})")

        # Create in-process MCP tools bound to this session
        context_folders = curator_session.context_files if curator_session.context_files else None
        _tools, curator_mcp_config = create_curator_tools(
            db=self.db,
            vault_path=self.vault_path,
            parent_session_id=parent_session.id,
            context_folders=context_folders,
        )

        # Build options with session resumption and in-process MCP tool access
        options_kwargs = {
            "system_prompt": CURATOR_SYSTEM_PROMPT,
            "max_turns": 5,  # Allow multiple turns for tool use
            "mcp_servers": {"curator": curator_mcp_config},
            "permission_mode": "bypassPermissions",
        }

        # Resume existing curator session if available (for memory continuity)
        if curator_session.sdk_session_id:
            options_kwargs["resume"] = curator_session.sdk_session_id

        # Use curator model if configured
        if settings.curator_model:
            options_kwargs["model"] = settings.curator_model

        options = ClaudeAgentOptions(**options_kwargs)

        response_text = ""
        new_session_id = None
        tool_calls_made = []

        try:
            async for event in sdk_query(prompt=prompt, options=options):
                # Track the session ID for future resumption
                if hasattr(event, "session_id") and event.session_id:
                    new_session_id = event.session_id

                # Process content blocks
                if hasattr(event, "content"):
                    for block in event.content:
                        # Track text responses
                        if hasattr(block, "text"):
                            response_text += block.text

                        # Track tool usage
                        if hasattr(block, "name"):
                            tool_name = block.name
                            tool_calls_made.append(tool_name)
                            logger.info(f"Curator tool call: {tool_name}")

                            # Track specific tool results
                            if "update_title" in tool_name:
                                result["title_updated"] = True
                                if hasattr(block, "input"):
                                    new_title = block.input.get("new_title", "")
                                    result["actions"].append(f"Updated title to: {new_title}")
                                    result["new_title"] = new_title
                            elif "update_context" in tool_name:
                                result["context_updated"] = True
                                if hasattr(block, "input"):
                                    file_name = block.input.get("file_name", "")
                                    result["actions"].append(f"Updated context: {file_name}")

            # Update session ID for continuity
            if new_session_id:
                result["sdk_session_id"] = new_session_id

            # Log results
            result["tool_calls"] = tool_calls_made
            if tool_calls_made:
                logger.info(f"Curator made {len(tool_calls_made)} tool calls: {tool_calls_made}")
            else:
                logger.info(f"Curator response (no tool calls): {response_text[:200]}...")

        except Exception as e:
            logger.error(f"Curator agent error: {e}", exc_info=True)
            result["error"] = str(e)

        return result

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
