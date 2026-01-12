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
import os
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
CURATOR_SYSTEM_PROMPT = """You are a session curator. You maintain a live, evolving summary of what's being accomplished in this chat session.

## Available Tools

- mcp__curator__update_title(session_id, new_title) - Update the session title
- mcp__curator__get_session_log(session_id) - Read your current summary for today
- mcp__curator__update_session_log(session_id, title, summary) - Update the summary

## Your Job: Maintain a Living Summary

You write a **rolling summary** of this chat session - not a changelog of individual updates, but a cohesive description of what's being worked on and what's been accomplished.

Each time you run:
1. Read your previous summary with get_session_log
2. Consider the new messages in context
3. **Rewrite the entire summary** to reflect the current state of work

The summary should EVOLVE and REFINE over time:
- Early: "Investigating why curator agents aren't updating titles"
- Mid-session: "Fixing curator MCP tool access - discovered tools weren't connecting properly"
- Later: "Fixed curator MCP tools by changing config format. Curator now successfully maintains session titles and daily logs."

## Summary Style

Write 2-4 concise paragraphs (not bullet lists) that answer:
- **Context**: What project, codebase, or area is this work in? (e.g., "Working in the Parachute base server...", "In the Daily Flutter app...", "On the Suno MCP server...")
- **Focus**: What specific problem or feature is being addressed?
- **Progress**: What's been accomplished so far?
- **State**: What's the current status or outcome?

Always anchor the summary with context. Don't just say "fixed the curator agent" - say "Fixed the curator agent in Parachute's base server". The reader should immediately understand what project/system this work relates to.

Think of it like a brief status update someone could read to understand what this chat session is about and what it achieved.

## Title Guidelines
- Keep titles concise (3-8 words, max 60 chars)
- Include project context when relevant (e.g., "Parachute: Fix curator MCP tools")
- Update when you have enough context or when the focus shifts
- Only update if current title is "(untitled)" or no longer fits

## When to Skip
If the new messages are just small talk, clarifying questions, or trivial exchanges with no real progress, you can skip updating. Only update when there's meaningful progress to report.
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

    async def get_transcript_after_compact(
        self,
        session_id: str,
    ) -> Optional[list[dict[str, Any]]]:
        """
        Get transcript events from the last compact boundary for a session.

        Reads the SDK JSONL file and returns only events after the last
        compact_boundary marker. This keeps context size manageable while
        still providing full conversation context.

        Returns None if transcript not found, empty list if no events.
        """
        # Look for SDK session file
        projects_dir = Path.home() / ".claude" / "projects"
        if not projects_dir.exists():
            return None

        session_file = None

        # Search all project directories
        for project_dir in projects_dir.iterdir():
            if project_dir.is_dir():
                candidate = project_dir / f"{session_id}.jsonl"
                if candidate.exists():
                    session_file = candidate
                    break

        if not session_file:
            return None

        # Parse the JSONL file
        all_events: list[dict[str, Any]] = []
        last_compact_index = -1

        try:
            with open(session_file, "r", encoding="utf-8") as f:
                for i, line in enumerate(f):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                        all_events.append(event)

                        # Track compact boundaries
                        if (
                            event.get("type") == "system"
                            and event.get("subtype") == "compact_boundary"
                        ):
                            last_compact_index = i
                    except json.JSONDecodeError:
                        continue

        except Exception as e:
            logger.error(f"Error reading transcript {session_id}: {e}")
            return None

        # Return events after last compact (or all if no compact)
        start_index = last_compact_index + 1 if last_compact_index >= 0 else 0
        return all_events[start_index:]

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

        # Determine if this is a fresh curator (no SDK session yet)
        is_fresh_curator = curator_session.sdk_session_id is None

        if is_fresh_curator:
            # Fresh curator: get full transcript from last compact boundary
            # This provides complete context for the curator's first run
            logger.info(f"Fresh curator for {task.session_id[:8]}, loading full transcript")
            transcript_events = await self.get_transcript_after_compact(task.session_id)

            if not transcript_events:
                # Fallback to session manager if no transcript found
                session_manager = SessionManager(self.vault_path, self.db)
                all_messages = await session_manager.get_session_messages(task.session_id)
                messages_to_curate = all_messages
                is_catchup = len(all_messages) > 2  # More than one exchange
            else:
                # Convert transcript events to simplified message format
                messages_to_curate = self._events_to_messages(transcript_events)
                is_catchup = len(messages_to_curate) > 2
        else:
            # Existing curator: get only new messages since last run
            session_manager = SessionManager(self.vault_path, self.db)
            all_messages = await session_manager.get_session_messages(task.session_id)
            messages_to_curate = all_messages[curator_session.last_message_index:]
            is_catchup = False

        if not messages_to_curate:
            logger.info(f"No new messages to curate for {task.session_id[:8]}")
            return {"skipped": True, "reason": "No new messages"}

        # Build message digest for curator
        context = self._build_curator_context(
            parent_session=parent_session,
            messages=messages_to_curate,
            task=task,
            is_catchup=is_catchup,
        )

        # Run curator agent with tools
        agent_result = await self._invoke_curator_agent(
            curator_session=curator_session,
            context=context,
            parent_session=parent_session,
        )
        result.update(agent_result)

        # Update curator session tracking
        # For fresh curators, we don't track message index since we used transcript
        # For existing curators, update the message index
        if not is_fresh_curator:
            session_manager = SessionManager(self.vault_path, self.db)
            all_messages = await session_manager.get_session_messages(task.session_id)
            new_message_index = len(all_messages)
        else:
            # Fresh curator processed everything available
            new_message_index = task.message_count

        await self.update_curator_session(
            curator_session.id,
            sdk_session_id=result.get("sdk_session_id"),
            last_message_index=new_message_index,
        )

        return result

    def _events_to_messages(self, events: list[dict[str, Any]]) -> list[dict]:
        """
        Convert SDK transcript events to simplified message format.

        Extracts user and assistant messages from the event stream,
        preserving text content and tool names (but not full tool I/O).
        """
        messages = []

        for event in events:
            event_type = event.get("type")

            if event_type == "user":
                # User message - extract text content only (skip tool results)
                message_content = event.get("message", {}).get("content")
                if message_content:
                    text = self._extract_text_content(message_content)
                    if text:
                        messages.append({"role": "user", "content": text})

            elif event_type == "assistant":
                # Assistant message - extract text and tool names
                message_content = event.get("message", {}).get("content", [])
                text = self._extract_text_content(message_content)
                tool_names = self._extract_tool_names(message_content)

                if text or tool_names:
                    content = []
                    if tool_names:
                        content.append({"type": "tools", "names": tool_names})
                    if text:
                        content.append({"type": "text", "text": text})
                    messages.append({"role": "assistant", "content": content})

        return messages

    def _build_curator_context(
        self,
        parent_session: Any,
        messages: list[dict],
        task: CuratorTask,
        is_catchup: bool = False,
    ) -> str:
        """
        Build a message digest for the curator agent.

        Args:
            parent_session: The parent chat session
            messages: Messages to include in the context
            task: The curator task
            is_catchup: If True, this is a catch-up run with full conversation context

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

        # Indicate catch-up mode
        if is_catchup:
            parts.append("## ⚠️ CATCH-UP CONTEXT")
            parts.append(f"This is your first run for this session. Below are {len(messages)} messages from the conversation so far.")
            parts.append("Please review and create a consolidated summary of all accomplishments.")
            parts.append("")

        # Tool calls from the trigger (if any) - only for non-catchup
        if task.tool_calls and not is_catchup:
            parts.append("### Tools Used (Latest)")
            tool_names = [tc.get("name", "unknown") for tc in task.tool_calls[:10]]
            parts.append(", ".join(tool_names))
            parts.append("")

        # Process messages
        # For catch-up: process all messages but with shorter truncation
        # For incremental: process last 5 messages with longer truncation
        if is_catchup:
            max_messages = 50  # Cap at 50 messages for catch-up
            user_truncate = 500
            assistant_truncate = 300
            messages_to_process = messages[:max_messages]
            if len(messages) > max_messages:
                parts.append(f"(Showing first {max_messages} of {len(messages)} messages)")
                parts.append("")
        else:
            messages_to_process = messages[-5:]
            user_truncate = 2000
            assistant_truncate = 1500

        for i, msg in enumerate(messages_to_process):
            role = msg.get("role", "unknown")
            content = msg.get("content", "")

            if role == "user":
                user_text = self._extract_text_content(content)
                if user_text:
                    if is_catchup:
                        parts.append(f"**User ({i+1}):**")
                    else:
                        parts.append("### User")
                    truncated = user_text[:user_truncate] + "..." if len(user_text) > user_truncate else user_text
                    parts.append(truncated)
                    parts.append("")

            elif role == "assistant":
                # Extract tool names and final text
                tool_names = self._extract_tool_names(content)
                final_text = self._extract_text_content(content)

                if is_catchup:
                    parts.append(f"**Assistant ({i+1}):**")
                    if tool_names:
                        parts.append(f"Tools: {', '.join(tool_names[:5])}")
                    if final_text:
                        truncated = final_text[:assistant_truncate] + "..." if len(final_text) > assistant_truncate else final_text
                        parts.append(truncated)
                    parts.append("")
                else:
                    if tool_names:
                        parts.append("### Assistant Tools")
                        parts.append(", ".join(tool_names))

                    if final_text:
                        parts.append("### Assistant Response")
                        truncated = final_text[:assistant_truncate] + "..." if len(final_text) > assistant_truncate else final_text
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
        from parachute.config import get_settings

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
        # Use stdio subprocess MCP server with explicit type
        import sys
        python_path = sys.executable
        base_dir = Path(__file__).parent.parent.parent  # base/ directory
        mcp_config = {
            "curator": {
                "type": "stdio",
                "command": python_path,
                "args": ["-m", "parachute.core.curator_mcp_server", str(self.vault_path)],
                "env": {
                    "PYTHONPATH": str(base_dir),
                    "PATH": os.environ.get("PATH", ""),
                },
            }
        }

        # Build options - resolve relative working directories against vault path
        if parent_session.working_directory:
            wd_path = Path(parent_session.working_directory)
            if not wd_path.is_absolute():
                wd_path = self.vault_path / wd_path
            cwd = str(wd_path.resolve())
        else:
            cwd = str(self.vault_path)
        options_kwargs: dict[str, Any] = {
            "system_prompt": CURATOR_SYSTEM_PROMPT,
            "max_turns": 5,
            "mcp_servers": mcp_config,
            "permission_mode": "bypassPermissions",
            "cwd": cwd,
            # IMPORTANT: Restrict curator to only its MCP tools
            # Using allowed_tools ONLY should restrict to just these tools
            "allowed_tools": [
                "mcp__curator__update_title",
                "mcp__curator__get_session_log",
                "mcp__curator__update_session_log",
            ],
        }

        # Resume existing session for continuity - curator maintains memory across runs
        if curator_session.sdk_session_id:
            options_kwargs["resume"] = curator_session.sdk_session_id
            logger.info(f"Resuming curator SDK session: {curator_session.sdk_session_id[:16]}...")

        # Use curator model if configured
        if settings.curator_model:
            options_kwargs["model"] = settings.curator_model

        options = ClaudeAgentOptions(**options_kwargs)

        new_session_id = None
        tool_calls_made = []

        # Debug: log the options being passed
        logger.info(f"Curator options: allowed_tools={options.allowed_tools}")

        try:
            async for event in sdk_query(prompt=prompt, options=options):
                # Debug: log all events
                event_type = type(event).__name__
                logger.debug(f"Curator event: {event_type}")

                # Track session ID for future resumption
                if hasattr(event, "session_id") and event.session_id:
                    new_session_id = event.session_id

                # Process content blocks for tool usage
                if hasattr(event, "content"):
                    for block in event.content:
                        block_type = type(block).__name__

                        # Log tool results
                        if "ToolResult" in block_type:
                            tool_use_id = getattr(block, "tool_use_id", "")
                            content = getattr(block, "content", "")
                            is_error = getattr(block, "is_error", False)
                            logger.info(f"Curator tool result: id={tool_use_id}, error={is_error}, content={str(content)[:200]}")

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

                            elif "update_session_log" in tool_name:
                                result["logged"] = True
                                result["actions"].append("Updated session log")

                            elif "get_session_log" in tool_name:
                                # Just tracking - the curator reads its previous log
                                result["actions"].append("Read previous log entry")

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
