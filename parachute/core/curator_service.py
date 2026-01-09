"""
Session Curator Service.

A long-running parallel agent that maintains session titles and logs activity
to the chat-log. Each chat session gets a companion curator that:
- Maintains a PERSISTENT SDK session (resumed across runs)
- Receives message digests (user prompt, tool names, assistant response)
- Has tool access: update_title, log_activity

Key design:
- Curator is a LONG-RUNNING parallel agent with session continuity
- Uses real tool access instead of JSON parsing
- Gets message digests (not full tool I/O to keep context manageable)
- One curator task runs at a time (queue-based)
- Uses configurable model (curator_model setting)
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


# System prompt for the curator agent
CURATOR_SYSTEM_PROMPT = """You are a session curator. You run alongside chat conversations to:
1. Generate and update session titles when the topic becomes clear
2. Log significant activities to the daily chat-log

You have two tools:
- update_title: Update the session title (use when topic is clear)
- log_activity: Log significant events (commits, decisions, milestones)

Guidelines:
- Update title when you have enough context to capture the main topic
- Keep titles concise (3-8 words, max 60 chars)
- Only log SIGNIFICANT activities - skip routine back-and-forth
- Format log entries as markdown bullets

What to log:
- Git commits (always)
- Decisions made
- Tasks completed
- Key milestones or breakthroughs

What NOT to log:
- Regular Q&A
- Debugging sessions (unless they resolve something)
- Small clarifications
"""


@dataclass
class CuratorSession:
    """Represents a curator session linked to a chat session."""
    id: str
    parent_session_id: str
    sdk_session_id: Optional[str]
    last_run_at: Optional[datetime]
    last_message_index: int
    created_at: datetime


@dataclass
class CuratorTask:
    """A queued curator task."""
    id: int
    session_id: str
    curator_session_id: Optional[str]
    trigger_type: str
    message_count: int
    queued_at: datetime
    started_at: Optional[datetime]
    completed_at: Optional[datetime]
    status: str
    result: Optional[dict]
    error: Optional[str]
    tool_calls: Optional[list[dict]] = None


class CuratorService:
    """
    Background service for curating chat sessions.

    Each chat session gets a companion curator session that:
    - Maintains persistent SDK session across runs (via resume)
    - Generates/updates session titles
    - Logs significant activities to chat-log
    """

    def __init__(self, db: Database, vault_path: Path):
        self.db = db
        self.vault_path = vault_path
        self._worker_task: Optional[asyncio.Task] = None
        self._shutdown = False
        self._queue_event = asyncio.Event()

    async def start_worker(self) -> None:
        """Start the background worker."""
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
        self._queue_event.set()

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
        tool_calls: Optional[list[dict]] = None,
    ) -> int:
        """Queue a curator task. Returns the task ID."""
        # Get or create curator session
        curator_session = await self.get_or_create_curator_session(parent_session_id)

        now = datetime.now(timezone.utc).isoformat()
        tool_calls_json = json.dumps(tool_calls) if tool_calls else None

        async with self.db.connection.execute(
            """
            INSERT INTO curator_queue
            (parent_session_id, curator_session_id, trigger_type, message_count, queued_at, status, tool_calls)
            VALUES (?, ?, ?, ?, ?, 'pending', ?)
            """,
            (parent_session_id, curator_session.id, trigger_type, message_count, now, tool_calls_json),
        ) as cursor:
            task_id = cursor.lastrowid

        await self.db.connection.commit()
        logger.info(f"Queued curator task {task_id} for session {parent_session_id[:8]}")

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
        self, session_id: str, limit: int = 20
    ) -> list[CuratorTask]:
        """Get recent tasks for a session."""
        async with self.db.connection.execute(
            """
            SELECT * FROM curator_queue
            WHERE parent_session_id = ?
            ORDER BY queued_at DESC
            LIMIT ?
            """,
            (session_id, limit),
        ) as cursor:
            rows = await cursor.fetchall()
            return [self._row_to_task(row) for row in rows]

    async def _update_task_status(
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

        await self.db.connection.commit()

    # =========================================================================
    # Curator Session Management
    # =========================================================================

    async def get_or_create_curator_session(
        self,
        parent_session_id: str,
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

        await self.db.connection.execute(
            """
            INSERT INTO curator_sessions
            (id, parent_session_id, created_at, last_message_index)
            VALUES (?, ?, ?, 0)
            """,
            (curator_id, parent_session_id, now),
        )
        await self.db.connection.commit()

        logger.info(f"Created curator session {curator_id[:16]} for {parent_session_id[:8]}")

        return CuratorSession(
            id=curator_id,
            parent_session_id=parent_session_id,
            sdk_session_id=None,
            last_run_at=None,
            last_message_index=0,
            created_at=datetime.now(timezone.utc),
        )

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

    # =========================================================================
    # Worker Loop
    # =========================================================================

    async def _worker_loop(self) -> None:
        """Background worker that processes curator tasks one at a time."""
        while not self._shutdown:
            try:
                task = await self.get_pending_task()

                if task is None:
                    self._queue_event.clear()
                    try:
                        await asyncio.wait_for(self._queue_event.wait(), timeout=30.0)
                    except asyncio.TimeoutError:
                        pass
                    continue

                await self._process_task(task)

            except Exception as e:
                logger.error(f"Curator worker error: {e}", exc_info=True)
                await asyncio.sleep(5.0)

    async def _process_task(self, task: CuratorTask) -> None:
        """Process a single curator task."""
        logger.info(f"Processing curator task {task.id} for session {task.session_id[:8]}")
        await self._update_task_status(task.id, "running")

        try:
            result = await self._run_curator(task)
            await self._update_task_status(task.id, "completed", result=result)
            logger.info(f"Curator task {task.id} completed: {result}")

        except Exception as e:
            logger.error(f"Curator task {task.id} failed: {e}", exc_info=True)
            await self._update_task_status(task.id, "failed", error=str(e))

    async def _run_curator(self, task: CuratorTask) -> dict[str, Any]:
        """Run the curator agent for a task."""
        from parachute.core.session_manager import SessionManager

        result: dict[str, Any] = {
            "title_updated": False,
            "logged": False,
            "actions": [],
        }

        # Get parent session
        parent_session = await self.db.get_session(task.session_id)
        if not parent_session:
            return {"error": "Parent session not found"}

        # Get curator session
        curator_session = await self.get_curator_session(task.session_id)
        if not curator_session:
            return {"error": "Curator session not found"}

        # Get messages since last curator run
        session_manager = SessionManager(self.vault_path, self.db)
        all_messages = await session_manager.get_session_messages(task.session_id)

        # Get only new messages since last run
        new_messages = all_messages[curator_session.last_message_index:]

        if not new_messages:
            logger.info(f"No new messages to curate for {task.session_id[:8]}")
            return {"skipped": True, "reason": "No new messages"}

        # Build message digest for curator
        context = self._build_curator_context(
            parent_session=parent_session,
            messages=new_messages,
            task=task,
        )

        # Run curator agent with tools
        agent_result = await self._invoke_curator_agent(
            curator_session=curator_session,
            context=context,
            parent_session=parent_session,
        )
        result.update(agent_result)

        # Update curator session tracking
        new_message_index = len(all_messages)
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
        task: CuratorTask,
    ) -> str:
        """
        Build a message digest for the curator agent.

        Format:
        - User's prompt (full text, truncated if long)
        - Tool calls (just names, no full I/O)
        - Final assistant response (truncated)
        """
        parts = []

        # Session info
        parts.append(f"## Session: {parent_session.id[:8]}...")
        parts.append(f"Current Title: {parent_session.title or '(untitled)'}")
        parts.append("")

        # Tool calls from the trigger (if any)
        if task.tool_calls:
            parts.append("### Tools Used")
            tool_names = [tc.get("name", "unknown") for tc in task.tool_calls[:10]]
            parts.append(", ".join(tool_names))
            parts.append("")

        # Process messages
        for msg in messages[-5:]:  # Last 5 messages
            role = msg.get("role", "unknown")
            content = msg.get("content", "")

            if role == "user":
                user_text = self._extract_text_content(content)
                if user_text:
                    parts.append("### User")
                    truncated = user_text[:2000] + "..." if len(user_text) > 2000 else user_text
                    parts.append(truncated)
                    parts.append("")

            elif role == "assistant":
                # Extract tool names and final text
                tool_names = self._extract_tool_names(content)
                final_text = self._extract_text_content(content)

                if tool_names:
                    parts.append("### Assistant Tools")
                    parts.append(", ".join(tool_names))

                if final_text:
                    parts.append("### Assistant Response")
                    truncated = final_text[:1500] + "..." if len(final_text) > 1500 else final_text
                    parts.append(truncated)
                    parts.append("")

        return "\n".join(parts)

    def _extract_text_content(self, content: Any) -> str:
        """Extract text from message content."""
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            text_parts = []
            for c in content:
                if isinstance(c, dict) and c.get("type") == "text":
                    text_parts.append(c.get("text", ""))
            return "\n".join(text_parts)
        return ""

    def _extract_tool_names(self, content: Any) -> list[str]:
        """Extract tool names from assistant message content."""
        tool_names = []
        if isinstance(content, list):
            for c in content:
                if isinstance(c, dict):
                    if c.get("type") in ("tool_use", "tool_call"):
                        tool_names.append(c.get("name", "unknown"))
        return tool_names

    async def _invoke_curator_agent(
        self,
        curator_session: CuratorSession,
        context: str,
        parent_session: Any,
    ) -> dict[str, Any]:
        """
        Run curator as a persistent SDK agent with MCP tools.

        The curator maintains session continuity via the resume option,
        allowing it to remember previous decisions and context.
        """
        from claude_agent_sdk import query as sdk_query, ClaudeAgentOptions
        from claude_agent_sdk.types import McpStdioServerConfig
        from parachute.config import get_settings
        import sys

        settings = get_settings()
        result: dict[str, Any] = {
            "title_updated": False,
            "logged": False,
            "actions": [],
        }

        # Build prompt
        prompt = f"""New messages to curate:

{context}

Based on this update:
1. If the current title is "(untitled)" or doesn't capture the topic well, update it
2. If there's anything significant to log (commits, decisions, milestones), log it

Session ID for tools: {parent_session.id}
Current title: {parent_session.title or '(untitled)'}"""

        # Configure MCP server with curator tools
        python_path = sys.executable
        mcp_config = {
            "curator": McpStdioServerConfig(
                command=python_path,
                args=["-m", "parachute.core.curator_mcp_server", str(self.vault_path)],
            )
        }

        # Build options
        cwd = parent_session.working_directory or str(self.vault_path)
        options_kwargs: dict[str, Any] = {
            "system_prompt": CURATOR_SYSTEM_PROMPT,
            "max_turns": 5,
            "mcp_servers": mcp_config,
            "permission_mode": "bypassPermissions",
            "cwd": cwd,
        }

        # Resume existing session for continuity
        if curator_session.sdk_session_id:
            options_kwargs["resume"] = curator_session.sdk_session_id
            logger.info(f"Resuming curator SDK session: {curator_session.sdk_session_id[:16]}...")

        # Use curator model if configured
        if settings.curator_model:
            options_kwargs["model"] = settings.curator_model

        options = ClaudeAgentOptions(**options_kwargs)

        new_session_id = None
        tool_calls_made = []

        try:
            async for event in sdk_query(prompt=prompt, options=options):
                # Track session ID for future resumption
                if hasattr(event, "session_id") and event.session_id:
                    new_session_id = event.session_id

                # Process content blocks for tool usage
                if hasattr(event, "content"):
                    for block in event.content:
                        block_type = type(block).__name__

                        if "ToolUse" in block_type:
                            tool_name = getattr(block, "name", "")
                            tool_calls_made.append(tool_name)
                            logger.info(f"Curator tool call: {tool_name}")

                            # Track specific tool results
                            if "update_title" in tool_name:
                                if hasattr(block, "input"):
                                    new_title = block.input.get("new_title", "")
                                    if new_title:
                                        # Apply the title update to the database
                                        try:
                                            await self.db.update_session(
                                                parent_session.id,
                                                SessionUpdate(title=new_title)
                                            )
                                            result["title_updated"] = True
                                            result["new_title"] = new_title
                                            result["actions"].append(f"Updated title: {new_title}")
                                            logger.info(f"Applied title update: {new_title}")
                                        except Exception as e:
                                            logger.error(f"Failed to apply title update: {e}")
                                            result["actions"].append(f"Title update failed: {e}")

                            elif "log_activity" in tool_name:
                                result["logged"] = True
                                result["actions"].append("Logged activity to chat-log")

            # Store session ID for continuity
            if new_session_id:
                result["sdk_session_id"] = new_session_id

            result["tool_calls"] = tool_calls_made

        except Exception as e:
            logger.error(f"Curator agent error: {e}", exc_info=True)
            result["error"] = str(e)
            # Try fallback for title generation
            if not parent_session.title or parent_session.title == "(untitled)":
                fallback = await self._generate_title_fallback(context)
                if fallback:
                    result["title_updated"] = True
                    result["new_title"] = fallback
                    result["fallback"] = True

        return result

    async def _generate_title_fallback(self, context: str) -> Optional[str]:
        """Simple fallback title generation."""
        from claude_agent_sdk import query as sdk_query, ClaudeAgentOptions
        from parachute.config import get_settings

        settings = get_settings()
        prompt = f"""Generate a concise title (3-8 words, max 60 chars) for this conversation.
Just output the title, nothing else.

{context[:2000]}"""

        options_kwargs: dict[str, Any] = {
            "system_prompt": "Generate concise titles. Output only the title.",
            "max_turns": 1,
            "allowed_tools": [],
        }

        if settings.curator_model:
            options_kwargs["model"] = settings.curator_model

        options = ClaudeAgentOptions(**options_kwargs)

        title = ""
        try:
            async for event in sdk_query(prompt=prompt, options=options):
                if hasattr(event, "content"):
                    for block in event.content:
                        if hasattr(block, "text"):
                            title += block.text

            title = title.strip().strip('"').strip("'").strip()
            if title and len(title) < 100:
                return title
        except Exception as e:
            logger.warning(f"Title fallback failed: {e}")

        return None

    # =========================================================================
    # Helpers
    # =========================================================================

    def _row_to_curator_session(self, row: aiosqlite.Row) -> CuratorSession:
        """Convert database row to CuratorSession."""
        last_run_at = None
        if row["last_run_at"]:
            last_run_at = datetime.fromisoformat(row["last_run_at"])

        return CuratorSession(
            id=row["id"],
            parent_session_id=row["parent_session_id"],
            sdk_session_id=row["sdk_session_id"],
            last_run_at=last_run_at,
            last_message_index=row["last_message_index"] or 0,
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

        tool_calls = None
        try:
            if row["tool_calls"]:
                tool_calls = json.loads(row["tool_calls"])
        except (json.JSONDecodeError, KeyError):
            pass

        started_at = None
        if row["started_at"]:
            started_at = datetime.fromisoformat(row["started_at"])

        completed_at = None
        if row["completed_at"]:
            completed_at = datetime.fromisoformat(row["completed_at"])

        return CuratorTask(
            id=row["id"],
            session_id=row["parent_session_id"],
            curator_session_id=row["curator_session_id"],
            trigger_type=row["trigger_type"],
            message_count=row["message_count"] or 0,
            queued_at=datetime.fromisoformat(row["queued_at"]),
            started_at=started_at,
            completed_at=completed_at,
            status=row["status"],
            result=result,
            error=row["error"],
            tool_calls=tool_calls,
        )


# Global service instance
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
