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


# Curator system prompt - instructs the agent on its role
CURATOR_SYSTEM_PROMPT = """You are a Session Curator - a background agent that helps maintain and improve a user's knowledge base.

Your responsibilities:
1. **Title Generation**: Create concise, descriptive titles for chat sessions based on their content
2. **Context Updates**: Update personal context files with new information learned from conversations

## Working Style
- Be concise and efficient - you're running in the background
- Make small, incremental updates rather than large rewrites
- Preserve existing information in context files, only add or refine
- Generate titles that are specific and useful for finding conversations later

## Title Guidelines
- 2-6 words, capturing the main topic or question
- Be specific (not "Coding Help" but "Fix React useState Loop")
- Use the user's terminology when appropriate
- If continuing an existing conversation, keep related titles

## Context Update Guidelines
- Only update when there's genuinely new, persistent information
- Examples of what to add:
  - User preferences discovered ("prefers TypeScript over JavaScript")
  - Project details ("working on Parachute app")
  - Technical context ("uses Flutter for mobile, Python for backend")
  - Personal context the user shared
- Do NOT add:
  - Temporary or one-off information
  - Things the user explicitly said to forget
  - Conversation-specific details that won't matter later

## Tools Available
You have access to file editing tools. Context files are in the Chat/contexts/ folder.
The main one is usually `general-context.md`.

When you receive conversation context, analyze it and:
1. Decide if the title needs updating (respond with the new title)
2. Decide if any context files need updates (make the edits)
3. Be brief in your responses - just state what you did
"""


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
        Invoke the curator agent using Claude SDK.

        Uses Haiku for speed and cost. Continues existing curator session
        if available, otherwise starts fresh.
        """
        # For now, implement a simplified version without full SDK integration
        # This will be enhanced to use the actual Claude SDK

        # TODO: Full Claude SDK integration
        # For now, use a simple heuristic for title generation

        result = {
            "title_updated": False,
            "context_updated": False,
            "actions": [],
        }

        # Simple title generation heuristic
        if not parent_session.title or parent_session.title == "(untitled)":
            # Generate title from first user message
            new_title = await self._generate_simple_title(context)
            if new_title:
                # Update the session title
                await self.db.update_session(
                    parent_session.id,
                    SessionUpdate(title=new_title),
                )
                result["title_updated"] = True
                result["new_title"] = new_title
                result["actions"].append(f"Updated title to: {new_title}")

        return result

    async def _generate_simple_title(self, context: str) -> Optional[str]:
        """
        Generate a simple title from context.

        This is a placeholder - will be replaced with actual Claude call.
        For now, extract from first user message.
        """
        # Look for user message content
        import re
        match = re.search(r'\*\*User\*\*:\s*(.+?)(?:\n|$)', context)
        if match:
            first_message = match.group(1).strip()
            # Truncate to reasonable title length
            if len(first_message) > 60:
                # Try to find a good break point
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
