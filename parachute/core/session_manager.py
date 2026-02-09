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
    - working_directory is stored as /vault/... in the DB (normalized for portability)
    - SDK CWD uses the real vault host path (resolve_working_directory)
    - Empty/null working_directory means vault root
    """

    def __init__(self, vault_path: Path, database: Database):
        """Initialize session manager."""
        self.vault_path = vault_path
        self.db = database

    def resolve_working_directory(self, working_directory: Optional[str]) -> Path:
        """
        Resolve a working_directory to an absolute path.

        Args:
            working_directory: Path in /vault/... format, legacy relative path,
                              or legacy absolute path. None or empty means vault root.

        Returns:
            Absolute Path for use with SDK (which requires absolute paths).
            Falls back to vault root if the resolved path escapes the vault.
        """
        if not working_directory:
            return self.vault_path

        wd_path = Path(working_directory)
        if wd_path.is_absolute():
            # /vault/... paths or legacy absolute paths — use as-is
            resolved = wd_path
        else:
            # Legacy relative path (e.g., "Projects/foo") — prepend /vault/
            resolved = Path("/vault") / wd_path

        # Validate resolved path doesn't escape vault (e.g., via ../../../)
        try:
            resolved_real = resolved.resolve()
            vault_real = self.vault_path.resolve()
            if not str(resolved_real).startswith(str(vault_real)):
                logger.warning(f"Working directory escapes vault: {working_directory}")
                return self.vault_path
        except Exception:
            pass  # If resolution fails, use the original path

        return resolved

    def normalize_working_directory(self, working_directory: Optional[str]) -> Optional[str]:
        """
        Convert a working_directory to /vault/... format for storage.

        Args:
            working_directory: Absolute host path, relative path, or /vault/... path.

        Returns:
            /vault/... path string, or None if it's the vault root.
        """
        if not working_directory:
            return None

        wd_path = Path(working_directory)

        if not wd_path.is_absolute():
            # Relative path (e.g., "Projects/foo") → /vault/Projects/foo
            result = str(Path("/vault") / wd_path)
            return result if result != "/vault" else None

        # Already /vault/... — keep as-is
        if working_directory.startswith("/vault"):
            return working_directory if working_directory != "/vault" else None

        # Absolute host path (e.g., /Users/user/Parachute/Projects/foo) → /vault/...
        try:
            rel_path = wd_path.relative_to(self.vault_path)
            if str(rel_path) == ".":
                return None
            return str(Path("/vault") / rel_path)
        except ValueError:
            # Path is not under vault_path — keep as-is (external project)
            logger.warning(f"working_directory {working_directory} is not under vault_path {self.vault_path}")
            return working_directory

    async def get_or_create_session(
        self,
        session_id: Optional[str],
        module: str = "chat",
        working_directory: Optional[str] = None,
        continued_from: Optional[str] = None,
        trust_level: Optional[str] = None,
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
            sdk_location = self._find_sdk_session_location(session_id, working_directory)
            logger.info(f"SDK session location for {session_id[:8]}: {sdk_location}, working_dir={working_directory}")

            if sdk_location:
                # SDK has the session, we just don't have metadata
                # Create a placeholder session with relative working_directory
                relative_wd = self.normalize_working_directory(working_directory)
                session = await self.db.create_session(
                    SessionCreate(
                        id=session_id,
                        module=module,
                        source=SessionSource.PARACHUTE,
                        working_directory=relative_wd,
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

            # Neither we nor SDK have this session - shouldn't happen with new client
            # (client sends 'new' for new sessions, normalized to None)
            # Treat as a new session with placeholder ID
            logger.warning(f"Unknown session ID requested: {session_id}, treating as new session")
            placeholder = Session(
                id="pending",  # Will be replaced with SDK session ID
                module=module,
                source=SessionSource.PARACHUTE,
                working_directory=working_directory,
                continued_from=continued_from,
                trust_level=trust_level,
                created_at=datetime.utcnow(),
                last_accessed=datetime.utcnow(),
            )
            resume_info = ResumeInfo(
                method="new",
                is_new_session=True,
                previous_message_count=0,
                sdk_session_available=False,
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
            trust_level=trust_level,
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
        agent_type: Optional[str] = None,
        workspace_id: Optional[str] = None,
    ) -> Session:
        """
        Finalize a new session with the SDK-provided session ID.

        Called after the first SDK response when we get the actual session ID.
        For bot-created sessions, carries forward linked_bot fields and trust_level
        from the placeholder, then removes the placeholder to avoid duplicate lookups.
        """
        # Convert working_directory to relative for storage
        relative_wd = self.normalize_working_directory(placeholder.working_directory)
        # Use provided agent_type, or fall back to placeholder's agent_type
        final_agent_type = agent_type or placeholder.get_agent_type()

        # Carry forward bot-linked fields from placeholder
        linked_bot_platform = getattr(placeholder, 'linked_bot_platform', None)
        linked_bot_chat_id = getattr(placeholder, 'linked_bot_chat_id', None)
        linked_bot_chat_type = getattr(placeholder, 'linked_bot_chat_type', None)
        trust_level = getattr(placeholder, 'trust_level', None)
        metadata = getattr(placeholder, 'metadata', None)
        final_workspace_id = workspace_id or getattr(placeholder, 'workspace_id', None)

        if sdk_session_id == placeholder.id:
            # Session ID unchanged (e.g., sandbox reused a connector-created session ID).
            # The row already exists in DB — update it with finalization fields.
            update = SessionUpdate(
                title=title or placeholder.title,
                model=model,
                agent_type=final_agent_type,
                working_directory=relative_wd,
                workspace_id=final_workspace_id,
            )
            session = await self.db.update_session(sdk_session_id, update)
            logger.debug(f"Updated existing session {sdk_session_id[:8]} with finalization fields")
        else:
            session = await self.db.create_session(
                SessionCreate(
                    id=sdk_session_id,
                    title=title or placeholder.title,
                    module=placeholder.module,
                    source=placeholder.source,
                    working_directory=relative_wd,
                    model=model,
                    continued_from=placeholder.continued_from,
                    agent_type=final_agent_type,
                    trust_level=trust_level,
                    linked_bot_platform=linked_bot_platform,
                    linked_bot_chat_id=linked_bot_chat_id,
                    linked_bot_chat_type=linked_bot_chat_type,
                    workspace_id=final_workspace_id,
                    metadata=metadata,
                )
            )

            # Remove the placeholder session so get_session_by_bot_link finds the
            # finalized session (with the SDK session ID) on the next message
            placeholder_id = placeholder.id
            if placeholder_id and placeholder_id != sdk_session_id:
                try:
                    await self.db.delete_session(placeholder_id)
                    logger.debug(f"Removed placeholder session {placeholder_id[:8]} after finalization")
                except Exception as e:
                    logger.warning(f"Could not remove placeholder session {placeholder_id[:8]}: {e}")

        logger.info(f"Finalized session: {sdk_session_id[:8]}... title='{title or 'none'}' agent_type='{final_agent_type or 'none'}'")
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
        agent_type: Optional[str] = None,
        search: Optional[str] = None,
        workspace_id: Optional[str] = None,
        limit: int = 100,
        offset: int = 0,
    ) -> list[Session]:
        """List sessions with optional filtering."""
        return await self.db.list_sessions(
            module=module,
            archived=archived,
            agent_type=agent_type,
            search=search,
            workspace_id=workspace_id,
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

    def get_session_resume_cwd(self, session_id: str) -> Optional[str]:
        """
        Get the working directory that should be used when resuming a session.

        This finds the actual transcript file and returns the cwd that was used
        when the session was created. This is necessary because the SDK uses the
        cwd to locate the transcript file via path encoding.

        Returns:
            The cwd path to use for resuming, or None if transcript not found.
        """
        result = self._find_sdk_transcript_with_cwd(session_id)
        if result:
            _, cwd, _ = result
            return cwd
        return None

    def _check_sdk_session_exists(
        self, session_id: str, working_directory: Optional[str] = None
    ) -> bool:
        """Check if an SDK JSONL file exists for this session.

        Checks both the expected vault path and the fallback ~/.claude location
        to handle sessions created before vault-based storage was implemented.
        """
        location = self._find_sdk_session_location(session_id, working_directory)
        return location is not None

    def _find_sdk_session_location(
        self, session_id: str, working_directory: Optional[str] = None
    ) -> Optional[str]:
        """Find where an SDK session is stored.

        Returns:
            - "vault" if found in vault's .claude directory
            - "home" if found in user's ~/.claude directory (pre-migration)
            - None if not found
        """
        # First check expected path in vault
        transcript_path = self.get_sdk_transcript_path(session_id, working_directory)
        if transcript_path and transcript_path.exists():
            return "vault"

        # Fallback: search all known locations
        # Check ~/.claude first (primary location)
        filename = f"{session_id}.jsonl"
        home_projects = Path.home() / ".claude" / "projects"
        if home_projects.exists():
            for project_dir in home_projects.iterdir():
                if project_dir.is_dir():
                    candidate = project_dir / filename
                    if candidate.exists():
                        return "home"

        # Check vault/.claude (legacy location from HOME override era)
        vault_projects = self.vault_path / ".claude" / "projects"
        if vault_projects.exists():
            for project_dir in vault_projects.iterdir():
                if project_dir.is_dir():
                    candidate = project_dir / filename
                    if candidate.exists():
                        logger.debug(f"Found transcript in legacy vault location: {candidate}")
                        return "vault"

        return None

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

        # Resolve symlinks (e.g., /tmp -> /private/tmp on macOS)
        # The SDK uses the resolved path for storage
        try:
            effective_cwd = str(Path(effective_cwd).resolve())
        except Exception:
            pass  # If resolution fails, use the original path

        # SDK encodes path by replacing / with -
        encoded_path = effective_cwd.replace("/", "-")
        # Sessions are stored in ~/.claude/ (real home)
        claude_dir = Path.home() / ".claude" / "projects" / encoded_path

        return claude_dir / f"{session_id}.jsonl"

    def _find_sdk_transcript(self, session_id: str) -> Optional[Path]:
        """
        Search all SDK project directories for a transcript file.

        This is a fallback when we don't know the working directory that was
        used when the session was created (e.g., curator sessions).

        Searches in two locations:
        1. {vault}/.claude/projects/ - new vault-based location (bare metal)
        2. ~/.claude/projects/ - original HOME-based location (pre-migration)

        Args:
            session_id: The SDK session UUID

        Returns:
            Path to the transcript file, or None if not found
        """
        result = self._find_sdk_transcript_with_cwd(session_id)
        return result[0] if result else None

    def _find_sdk_transcript_with_cwd(self, session_id: str) -> Optional[tuple[Path, str, str]]:
        """
        Search for a transcript file and return its path along with the cwd it was created with.

        Returns:
            Tuple of (transcript_path, decoded_cwd, location) where location is "vault" or "home",
            or None if not found.
        """
        filename = f"{session_id}.jsonl"

        def decode_project_path(encoded_name: str) -> str:
            """Decode a project directory name to a path."""
            # Claude encodes paths by replacing / with -
            # Handle leading - which represents root /
            if encoded_name.startswith("-"):
                return "/" + encoded_name[1:].replace("-", "/")
            return encoded_name.replace("-", "/")

        # Search in ~/.claude (primary location)
        home_projects = Path.home() / ".claude" / "projects"
        if home_projects.exists():
            for project_dir in home_projects.iterdir():
                if project_dir.is_dir():
                    candidate = project_dir / filename
                    if candidate.exists():
                        decoded_cwd = decode_project_path(project_dir.name)
                        return (candidate, decoded_cwd, "home")

        # Fallback: search in vault/.claude (legacy from HOME override era)
        vault_projects = self.vault_path / ".claude" / "projects"
        if vault_projects.exists():
            for project_dir in vault_projects.iterdir():
                if project_dir.is_dir():
                    candidate = project_dir / filename
                    if candidate.exists():
                        decoded_cwd = decode_project_path(project_dir.name)
                        logger.debug(f"Found transcript in legacy vault location: {candidate}, cwd={decoded_cwd}")
                        return (candidate, decoded_cwd, "vault")

        return None

    async def load_sdk_messages_by_id(
        self,
        session_id: str,
        working_directory: Optional[str] = None,
        include_tool_calls: bool = True,
    ) -> list[dict[str, Any]]:
        """
        Load messages from SDK JSONL file by session ID.

        This is a public method that can be used to load messages for any SDK
        session, including curator sessions that don't have a corresponding
        database entry.

        Args:
            session_id: The SDK session UUID
            working_directory: Optional working directory for path resolution
            include_tool_calls: Whether to include tool use details

        Returns:
            List of message dicts with role, content, timestamp, and optionally tools
        """
        transcript_path = self.get_sdk_transcript_path(session_id, working_directory)

        # If not found at the expected path, search all SDK project directories
        if not transcript_path or not transcript_path.exists():
            transcript_path = self._find_sdk_transcript(session_id)

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
                            msg = event.get("message", {})
                            content = self._extract_message_content(msg)
                            tool_calls = self._extract_tool_calls(msg) if include_tool_calls else []

                            if content or tool_calls:
                                message_entry = {
                                    "role": "assistant",
                                    "content": content or "",
                                    "timestamp": event.get("timestamp"),
                                }
                                if tool_calls:
                                    message_entry["tool_calls"] = tool_calls
                                messages.append(message_entry)
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

    def _extract_tool_calls(self, message: dict[str, Any]) -> list[dict[str, Any]]:
        """Extract tool call info from an SDK message."""
        content = message.get("content", [])
        if not isinstance(content, list):
            return []

        tool_calls = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                tool_calls.append({
                    "id": block.get("id"),
                    "name": block.get("name"),
                    "input": block.get("input", {}),
                })
        return tool_calls

    def write_sandbox_transcript(
        self,
        session_id: str,
        user_message: str,
        assistant_response: str,
        working_directory: Optional[str] = None,
    ) -> None:
        """Write a synthetic JSONL transcript for a sandbox session.

        Docker container transcripts are lost when the container exits.
        This writes a minimal transcript to the host filesystem so messages
        persist across app restarts and session reloads.
        """
        transcript_path = self.get_sdk_transcript_path(session_id, working_directory)
        if not transcript_path:
            logger.warning(f"Could not compute transcript path for sandbox session {session_id[:8]}")
            return

        try:
            transcript_path.parent.mkdir(parents=True, exist_ok=True)

            now = datetime.utcnow().isoformat() + "Z"
            events = [
                {"type": "user", "message": {"role": "user", "content": user_message}, "timestamp": now},
                {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": assistant_response}]}, "timestamp": now},
                {"type": "result", "result": assistant_response, "session_id": session_id, "timestamp": now},
            ]

            # Append to existing transcript (supports multi-turn sandbox sessions)
            with open(transcript_path, "a", encoding="utf-8") as f:
                for event in events:
                    f.write(json.dumps(event) + "\n")

            logger.info(f"Wrote sandbox transcript for session {session_id[:8]} at {transcript_path}")
        except Exception as e:
            logger.error(f"Failed to write sandbox transcript: {e}")

    async def _load_sdk_messages(self, session: Session) -> list[dict[str, Any]]:
        """Load messages from SDK JSONL file."""
        transcript_path = self.get_sdk_transcript_path(
            session.id, session.working_directory
        )

        # Fallback: search all project directories if not found at expected path
        # This handles old sessions with different path encodings (e.g., -vault- vs -Users-)
        if not transcript_path or not transcript_path.exists():
            transcript_path = self._find_sdk_transcript(session.id)

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
        # Sessions are stored in ~/.claude/ (real home)

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
