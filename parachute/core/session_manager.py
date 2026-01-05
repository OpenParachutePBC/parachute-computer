"""
Session manager with SQLite backend.

Manages chat sessions with the SDK session ID as the primary key.
The actual message content lives in SDK JSONL files; we only store metadata.
"""

import json
import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from parachute.db.database import Database
from parachute.models.session import (
    ResumeInfo,
    Session,
    SessionCreate,
    SessionSource,
    SessionUpdate,
    SessionWithMessages,
)

logger = logging.getLogger(__name__)


class SessionManager:
    """
    Manages chat sessions using SQLite for metadata.

    Key design decisions:
    - SDK session ID is the ONLY identifier (no separate Parachute session ID)
    - Messages are stored in SDK JSONL files, not our database
    - We store metadata for indexing and quick listing
    """

    def __init__(self, vault_path: Path, database: Database):
        """Initialize session manager."""
        self.vault_path = vault_path
        self.db = database

    async def get_or_create_session(
        self,
        session_id: Optional[str],
        module: str = "chat",
        working_directory: Optional[str] = None,
        continued_from: Optional[str] = None,
    ) -> tuple[Session, ResumeInfo, bool]:
        """
        Get an existing session or prepare for a new one.

        For new sessions, we don't create a DB record yet - we wait for the SDK
        to provide the session ID after the first message.

        Args:
            session_id: Existing SDK session ID to resume, or None for new
            module: Module name (chat, daily, build)
            working_directory: Working directory for file operations
            continued_from: Parent session ID if continuing

        Returns:
            Tuple of (session, resume_info, is_new)
        """
        if session_id:
            # Try to load existing session
            existing = await self.db.get_session(session_id)
            if existing:
                # Touch to update last_accessed
                await self.db.touch_session(session_id)

                resume_info = ResumeInfo(
                    method="sdk_resume",
                    is_new_session=False,
                    previous_message_count=existing.message_count,
                    sdk_session_available=True,
                )
                return existing, resume_info, False

            # Session ID provided but not found - check if SDK file exists
            sdk_available = self._check_sdk_session_exists(session_id, working_directory)

            if sdk_available:
                # SDK has the session, we just don't have metadata
                # Create a placeholder session
                session = await self.db.create_session(
                    SessionCreate(
                        id=session_id,
                        module=module,
                        source=SessionSource.PARACHUTE,
                        working_directory=working_directory,
                        continued_from=continued_from,
                    )
                )
                resume_info = ResumeInfo(
                    method="sdk_resume",
                    is_new_session=False,
                    previous_message_count=0,  # Unknown
                    sdk_session_available=True,
                )
                return session, resume_info, False

            # Neither we nor SDK have this session
            logger.warning(f"Session not found: {session_id}")
            resume_info = ResumeInfo(
                method="new",
                is_new_session=True,
                previous_message_count=0,
                sdk_session_available=False,
            )
            # Create a placeholder that will be updated when SDK provides ID
            placeholder = Session(
                id=session_id,  # Temporary
                module=module,
                source=SessionSource.PARACHUTE,
                working_directory=working_directory,
                continued_from=continued_from,
                created_at=datetime.utcnow(),
                last_accessed=datetime.utcnow(),
            )
            return placeholder, resume_info, True

        # No session ID - this is definitely a new session
        # Create a placeholder that will be finalized with the SDK session ID
        placeholder = Session(
            id="pending",  # Will be replaced
            module=module,
            source=SessionSource.PARACHUTE,
            working_directory=working_directory,
            continued_from=continued_from,
            created_at=datetime.utcnow(),
            last_accessed=datetime.utcnow(),
        )
        resume_info = ResumeInfo(
            method="new",
            is_new_session=True,
            previous_message_count=0,
            sdk_session_available=True,
        )
        return placeholder, resume_info, True

    async def finalize_session(
        self,
        placeholder: Session,
        sdk_session_id: str,
        model: Optional[str] = None,
        title: Optional[str] = None,
    ) -> Session:
        """
        Finalize a new session with the SDK-provided session ID.

        Called after the first SDK response when we get the actual session ID.
        """
        session = await self.db.create_session(
            SessionCreate(
                id=sdk_session_id,
                title=title or placeholder.title,
                module=placeholder.module,
                source=placeholder.source,
                working_directory=placeholder.working_directory,
                model=model,
                continued_from=placeholder.continued_from,
            )
        )
        logger.info(f"Finalized session: {sdk_session_id[:8]}... title='{title or 'none'}'")
        return session

    async def update_session(
        self,
        session_id: str,
        title: Optional[str] = None,
        message_count: Optional[int] = None,
        model: Optional[str] = None,
    ) -> Optional[Session]:
        """Update session metadata."""
        update = SessionUpdate(
            title=title,
            message_count=message_count,
            model=model,
        )
        return await self.db.update_session(session_id, update)

    async def increment_message_count(self, session_id: str, count: int = 2) -> None:
        """Increment message count (typically +2 for user + assistant)."""
        await self.db.increment_message_count(session_id, count)

    async def archive_session(self, session_id: str) -> Optional[Session]:
        """Archive a session."""
        return await self.db.archive_session(session_id)

    async def unarchive_session(self, session_id: str) -> Optional[Session]:
        """Unarchive a session."""
        return await self.db.unarchive_session(session_id)

    async def delete_session(self, session_id: str) -> bool:
        """Delete a session."""
        return await self.db.delete_session(session_id)

    async def list_sessions(
        self,
        module: Optional[str] = None,
        archived: bool = False,
        limit: int = 100,
        offset: int = 0,
    ) -> list[Session]:
        """List sessions with optional filtering."""
        return await self.db.list_sessions(
            module=module,
            archived=archived,
            limit=limit,
            offset=offset,
        )

    async def get_session(self, session_id: str) -> Optional[Session]:
        """Get a session by ID."""
        return await self.db.get_session(session_id)

    async def get_session_with_messages(
        self, session_id: str
    ) -> Optional[SessionWithMessages]:
        """Get a session with its message history from SDK JSONL."""
        session = await self.db.get_session(session_id)
        if not session:
            return None

        messages = await self._load_sdk_messages(session)

        return SessionWithMessages(
            **session.model_dump(),
            messages=messages,
        )

    async def get_stats(self) -> dict[str, Any]:
        """Get session statistics."""
        total = await self.db.get_session_count()
        active = await self.db.get_session_count(archived=False)
        archived = await self.db.get_session_count(archived=True)

        by_module = {}
        for module in ["chat", "daily", "build"]:
            by_module[module] = await self.db.get_session_count(module=module)

        return {
            "total": total,
            "active": active,
            "archived": archived,
            "by_module": by_module,
        }

    async def cleanup_old_sessions(self, days: int = 30) -> int:
        """Clean up old archived sessions."""
        return await self.db.cleanup_old_sessions(days)

    # =========================================================================
    # SDK Integration
    # =========================================================================

    def _check_sdk_session_exists(
        self, session_id: str, working_directory: Optional[str] = None
    ) -> bool:
        """Check if an SDK JSONL file exists for this session."""
        transcript_path = self.get_sdk_transcript_path(session_id, working_directory)
        return transcript_path.exists() if transcript_path else False

    def get_sdk_transcript_path(
        self, session_id: str, working_directory: Optional[str] = None
    ) -> Optional[Path]:
        """Get the path to the SDK's JSONL transcript for a session."""
        # Determine effective cwd
        if working_directory:
            if os.path.isabs(working_directory):
                effective_cwd = working_directory
            else:
                effective_cwd = str(self.vault_path / working_directory)
        else:
            effective_cwd = str(self.vault_path)

        # SDK encodes path by replacing / with -
        encoded_path = effective_cwd.replace("/", "-")
        claude_dir = Path.home() / ".claude" / "projects" / encoded_path

        return claude_dir / f"{session_id}.jsonl"

    async def _load_sdk_messages(self, session: Session) -> list[dict[str, Any]]:
        """Load messages from SDK JSONL file."""
        transcript_path = self.get_sdk_transcript_path(
            session.id, session.working_directory
        )

        if not transcript_path or not transcript_path.exists():
            return []

        messages = []
        try:
            with open(transcript_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)

                        # Extract user and assistant messages
                        if event.get("type") == "user":
                            content = self._extract_message_content(event.get("message", {}))
                            if content:
                                messages.append({
                                    "role": "user",
                                    "content": content,
                                    "timestamp": event.get("timestamp"),
                                })
                        elif event.get("type") == "assistant":
                            content = self._extract_message_content(event.get("message", {}))
                            if content:
                                messages.append({
                                    "role": "assistant",
                                    "content": content,
                                    "timestamp": event.get("timestamp"),
                                })
                        elif event.get("type") == "result":
                            # Final result message
                            if event.get("result"):
                                messages.append({
                                    "role": "assistant",
                                    "content": event["result"],
                                    "timestamp": event.get("timestamp"),
                                })

                    except json.JSONDecodeError:
                        continue

        except Exception as e:
            logger.error(f"Error loading SDK transcript: {e}")

        return messages

    def _extract_message_content(self, message: dict[str, Any]) -> Optional[str]:
        """Extract text content from an SDK message."""
        content = message.get("content", [])
        if isinstance(content, str):
            return content

        if isinstance(content, list):
            text_parts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    text_parts.append(block.get("text", ""))
            if text_parts:
                return "\n".join(text_parts)

        return None

    async def get_prior_conversation(self, session: Session) -> Optional[str]:
        """
        Get prior conversation text for continuing an imported session.

        This formats all messages from the original session as text that can be
        injected into the system prompt for context continuity.

        Supports:
        - Claude Code sessions (from ~/.claude/projects JSONL files)
        - Claude Web imports (from markdown files in Chat/sessions/imported/)
        - ChatGPT imports (from markdown files in Chat/sessions/imported/)

        Returns None if session is not an import or has no messages.
        """
        messages = []

        if session.source == SessionSource.CLAUDE_CODE:
            messages = await self._load_claude_code_messages(session)
        elif session.source in (SessionSource.CLAUDE_WEB, SessionSource.CHATGPT):
            messages = await self._load_imported_markdown_messages(session)

        if not messages:
            return None

        return self._format_as_prior_conversation(messages)

    async def _load_claude_code_messages(self, session: Session) -> list[dict[str, Any]]:
        """Load messages from a Claude Code session's JSONL file."""
        # Claude Code sessions use the original session ID to find the file
        # The file is in ~/.claude/projects/{encoded-cwd}/{session_id}.jsonl

        projects_dir = Path.home() / ".claude" / "projects"
        if not projects_dir.exists():
            return []

        # Search all project directories for this session
        session_file = None
        for project_dir in projects_dir.iterdir():
            if project_dir.is_dir():
                candidate = project_dir / f"{session.id}.jsonl"
                if candidate.exists():
                    session_file = candidate
                    break

        if not session_file:
            # Also try using the working directory if set
            if session.working_directory:
                encoded = session.working_directory.replace("/", "-")
                if session.working_directory.startswith("/"):
                    encoded = "-" + session.working_directory[1:].replace("/", "-")
                session_file = projects_dir / encoded / f"{session.id}.jsonl"

        if not session_file or not session_file.exists():
            return []

        messages = []
        try:
            with open(session_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                        event_type = event.get("type")

                        if event_type == "user":
                            content = self._extract_message_content(event.get("message", {}))
                            if content:
                                messages.append({
                                    "role": "user",
                                    "content": content,
                                })
                        elif event_type == "assistant":
                            content = self._extract_message_content(event.get("message", {}))
                            if content:
                                messages.append({
                                    "role": "assistant",
                                    "content": content,
                                })
                        elif event_type == "result" and event.get("result"):
                            messages.append({
                                "role": "assistant",
                                "content": event["result"],
                            })
                    except json.JSONDecodeError:
                        continue
        except Exception as e:
            logger.error(f"Error loading Claude Code messages: {e}")

        return messages

    async def _load_imported_markdown_messages(self, session: Session) -> list[dict[str, Any]]:
        """Load messages from an imported markdown session file.

        The markdown format uses headers like:
        ### Human | 2025-12-20T10:30:00Z
        Message content here

        ### Assistant | 2025-12-20T10:31:00Z
        Response here
        """
        import re

        # Find the markdown file in Chat/sessions/imported/
        imported_dir = self.vault_path / "Chat" / "sessions" / "imported"
        if not imported_dir.exists():
            return []

        # Try to find the file by session ID (could be claude-{uuid}.md or chatgpt-{id}.md)
        session_file = None
        for pattern in [f"claude-{session.id}.md", f"chatgpt-{session.id}.md"]:
            candidate = imported_dir / pattern
            if candidate.exists():
                session_file = candidate
                break

        if not session_file:
            # Try to find by scanning the directory
            for f in imported_dir.iterdir():
                if f.is_file() and f.suffix == ".md":
                    content = f.read_text(encoding="utf-8")
                    if f"original_id: {session.id}" in content or f"sdk_session_id: {session.id}" in content:
                        session_file = f
                        break

        if not session_file:
            logger.warning(f"Could not find imported markdown for session {session.id}")
            return []

        messages = []
        try:
            content = session_file.read_text(encoding="utf-8")

            # Skip frontmatter
            if content.startswith("---"):
                parts = content.split("---", 2)
                if len(parts) >= 3:
                    content = parts[2]

            # Parse messages - format: ### Human | timestamp or ### Assistant | timestamp
            # The message content follows until the next ### header
            message_pattern = re.compile(
                r"###\s+(Human|Assistant)\s*\|\s*[\d\-T:Z]+\s*\n(.*?)(?=###\s+(?:Human|Assistant)\s*\||$)",
                re.DOTALL | re.IGNORECASE
            )

            for match in message_pattern.finditer(content):
                role = match.group(1).lower()
                text = match.group(2).strip()

                if text:
                    messages.append({
                        "role": "user" if role == "human" else "assistant",
                        "content": text,
                    })

        except Exception as e:
            logger.error(f"Error loading imported markdown messages: {e}")

        return messages

    def _format_as_prior_conversation(self, messages: list[dict[str, Any]]) -> str:
        """Format messages as prior conversation text."""
        lines = []
        for msg in messages:
            role = msg["role"].upper()
            content = msg["content"]
            lines.append(f"**{role}:**\n{content}")
        return "\n\n---\n\n".join(lines)

    async def get_session_messages(
        self, session_id: str, after_index: int = 0
    ) -> list[dict[str, Any]]:
        """
        Get messages from a session, optionally after a certain index.

        Used by the curator to get only new messages since last curation.

        Args:
            session_id: The session to get messages from
            after_index: Only return messages after this index (0-based)

        Returns:
            List of message dicts with role, content, timestamp
        """
        session = await self.db.get_session(session_id)
        if not session:
            return []

        all_messages = await self._load_sdk_messages(session)

        # Return messages after the given index
        if after_index > 0 and after_index < len(all_messages):
            return all_messages[after_index:]
        elif after_index >= len(all_messages):
            return []  # No new messages
        else:
            return all_messages
