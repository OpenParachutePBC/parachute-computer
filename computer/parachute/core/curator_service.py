"""
Session Curator Service.

A background service that generates and updates session titles.
Runs as a single worker processing tasks from a queue.

Key design:
- Queue-based to avoid blocking main chat flow
- Single worker to process tasks one at a time
- Simple title generation using Claude SDK
- Falls back to heuristics if SDK unavailable
"""

import asyncio
import json
import logging
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

import aiosqlite

from parachute.db.database import Database
from parachute.models.session import SessionUpdate

logger = logging.getLogger(__name__)


# System prompt for title generation
TITLE_PROMPT = """You are a title generator. Generate a concise, descriptive title for the conversation below.

Rules:
- 3-8 words, no more than 60 characters
- Capture the main topic or intent
- Use sentence case (capitalize first word only)
- No quotes, no prefixes like "Title:"
- No emojis unless the conversation is specifically about them

Just output the title text, nothing else."""


@dataclass
class CuratorTask:
    """A queued curator task."""
    id: int
    session_id: str
    trigger_type: str
    message_count: int
    queued_at: datetime
    started_at: Optional[datetime]
    completed_at: Optional[datetime]
    status: str  # 'pending', 'running', 'completed', 'failed'
    result: Optional[dict]
    error: Optional[str]


class CuratorService:
    """
    Background service for generating session titles.

    Tasks are queued and processed one at a time by a background worker.
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
            await asyncio.wait_for(self._worker_task, timeout=5.0)
        except asyncio.TimeoutError:
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
    ) -> int:
        """Queue a curator task. Returns the task ID."""
        now = datetime.now(timezone.utc).isoformat()
        async with self.db.connection.execute(
            """
            INSERT INTO curator_queue
            (parent_session_id, trigger_type, message_count, queued_at, status)
            VALUES (?, ?, ?, ?, 'pending')
            """,
            (parent_session_id, trigger_type, message_count, now),
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
    # Worker Loop
    # =========================================================================

    async def _worker_loop(self) -> None:
        """Background worker that processes curator tasks."""
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
        """Run curator for a task - generates/updates session title."""
        from parachute.core.session_manager import SessionManager

        # Get session
        session = await self.db.get_session(task.session_id)
        if not session:
            return {"error": "Session not found"}

        # Check if title needs generating
        is_untitled = not session.title or session.title == "(untitled)"
        is_placeholder = (
            session.title and
            session.title.endswith("...") and
            len(session.title) <= 65
        )

        if not is_untitled and not is_placeholder:
            return {"skipped": True, "reason": "Session already has title"}

        # Get recent messages for context
        session_manager = SessionManager(self.vault_path, self.db)
        messages = await session_manager.get_session_messages(task.session_id, limit=5)

        if not messages:
            return {"skipped": True, "reason": "No messages"}

        # Build context
        context = self._build_context(session, messages)

        # Generate title
        try:
            title = await self._generate_title_with_sdk(context)
        except Exception as e:
            logger.warning(f"SDK title generation failed, using fallback: {e}")
            title = self._generate_title_heuristic(context)

        if title:
            await self.db.update_session(session.id, SessionUpdate(title=title))
            return {"title_updated": True, "new_title": title}

        return {"title_updated": False}

    def _build_context(self, session: Any, messages: list[dict]) -> str:
        """Build context string from messages for title generation."""
        parts = []

        for msg in messages[:3]:  # First 3 messages max
            role = msg.get("role", "unknown")
            content = msg.get("content", "")

            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                text_parts = []
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "text":
                        text_parts.append(c.get("text", ""))
                text = "\n".join(text_parts)
            else:
                continue

            if text:
                # Truncate long content
                if len(text) > 500:
                    text = text[:500] + "..."
                parts.append(f"{role.upper()}: {text}")

        return "\n\n".join(parts)

    async def _generate_title_with_sdk(self, context: str) -> Optional[str]:
        """Generate title using Claude SDK."""
        from claude_agent_sdk import query as sdk_query, ClaudeAgentOptions
        from parachute.config import get_settings

        settings = get_settings()

        options_kwargs = {
            "system_prompt": TITLE_PROMPT,
            "max_turns": 1,
            "allowed_tools": [],
        }

        if settings.curator_model:
            options_kwargs["model"] = settings.curator_model

        options = ClaudeAgentOptions(**options_kwargs)
        prompt = f"Generate a title for this conversation:\n\n{context}"

        title = ""
        async for event in sdk_query(prompt=prompt, options=options):
            if hasattr(event, "content"):
                for block in event.content:
                    if hasattr(block, "text"):
                        title += block.text

        # Clean up
        title = title.strip().strip('"').strip("'").strip()
        if title and len(title) < 100:
            return title
        return None

    def _generate_title_heuristic(self, context: str) -> Optional[str]:
        """Generate title using simple heuristics (fallback)."""
        # Extract first user message
        match = re.search(r'USER:\s*(.+?)(?:\n|$)', context, re.IGNORECASE)
        if match:
            text = match.group(1).strip()
            text = " ".join(text.split())  # Normalize whitespace
            if len(text) > 60:
                words = text[:60].split()
                if len(words) > 3:
                    text = " ".join(words[:-1]) + "..."
                else:
                    text = text[:57] + "..."
            return text
        return None

    # =========================================================================
    # Helpers
    # =========================================================================

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
            session_id=row["parent_session_id"],
            trigger_type=row["trigger_type"],
            message_count=row["message_count"] or 0,
            queued_at=datetime.fromisoformat(row["queued_at"]),
            started_at=started_at,
            completed_at=completed_at,
            status=row["status"],
            result=result,
            error=row["error"],
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
