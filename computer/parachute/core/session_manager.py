"""
Session manager with SQLite backend.

Manages chat sessions with the SDK session ID as the primary key.
The actual message content lives in SDK JSONL files; we only store metadata.
"""

import json
import logging
import os
import uuid as uuid_mod
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from parachute.db.brain_chat_store import BrainChatStore
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
    Manages chat sessions using Kuzu graph database for metadata.

    Key design decisions:
    - SDK session ID is the ONLY identifier (no separate Parachute session ID)
    - Messages are stored in SDK JSONL files, not our database
    - We store metadata for indexing and quick listing
    - working_directory is stored as real absolute path
    - SDK CWD uses the real host path (resolve_working_directory)
    - Empty/null working_directory means user's home directory
    """

    def __init__(self, parachute_dir: Path, session_store: BrainChatStore):
        """Initialize session manager."""
        self.parachute_dir = parachute_dir
        self.session_store = session_store
        # Alias: used by orchestrator, claude_code API, and internal methods.
        # Kept because `.db` is shorter and widely referenced.
        self.db = session_store

    def resolve_working_directory(self, working_directory: Optional[str]) -> Path:
        """
        Resolve a working_directory to an absolute path.

        Args:
            working_directory: Real absolute path, /vault/... legacy path,
                              or relative path. None or empty means user home dir.

        Returns:
            Absolute Path for use with SDK (which requires absolute paths).
            Falls back to home dir if the path doesn't exist.
        """
        home = Path.home()
        if not working_directory:
            return home

        wd_path = Path(working_directory)
        if wd_path.is_absolute():
            if str(wd_path).startswith("/vault/"):
                # COMPAT: /vault/... paths from pre-v0.2.0 sessions stored in DB.
                # Safe to remove once no sessions have /vault/ working directories
                # (likely 6+ months after the vault→home migration, ~Sep 2026).
                relative = str(wd_path)[len("/vault/"):]
                resolved = home / relative
            else:
                # Real absolute path — use as-is
                resolved = wd_path
        else:
            # Relative path — prepend home dir
            resolved = home / wd_path

        return resolved

    def normalize_working_directory(self, working_directory: Optional[str]) -> Optional[str]:
        """
        Normalize a working_directory for storage.

        After the vault→home migration, working directories are stored as real
        absolute paths. Legacy /vault/... paths are converted to home-relative paths.

        Returns:
            Real absolute path string, or None if it's the home root.
        """
        if not working_directory:
            return None

        home = Path.home()
        wd_path = Path(working_directory)

        if not wd_path.is_absolute():
            # Relative path — make absolute relative to home
            abs_path = home / wd_path
            return str(abs_path) if str(abs_path) != str(home) else None

        # COMPAT: /vault/... → absolute path (see resolve_working_directory above)
        if working_directory.startswith("/vault/"):
            relative = working_directory[len("/vault/"):]
            abs_path = home / relative
            return str(abs_path)
        if working_directory == "/vault":
            return None

        # Already a real absolute path
        return working_directory if working_directory != str(home) else None

    async def get_or_create_session(
        self,
        session_id: Optional[str],
        module: str = "chat",
        working_directory: Optional[str] = None,
        continued_from: Optional[str] = None,
        trust_level: Optional[str] = None,
        mode: Optional[str] = None,
        project_id: str | None = None,
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
                        mode=mode,
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
                mode=mode,
                project_id=project_id,
                created_at=datetime.now(timezone.utc),
                last_accessed=datetime.now(timezone.utc),
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
            mode=mode,
            project_id=project_id,
            created_at=datetime.now(timezone.utc),
            last_accessed=datetime.now(timezone.utc),
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
        mode: Optional[str] = None,
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

        # Carry forward fields from placeholder
        linked_bot_platform = getattr(placeholder, 'linked_bot_platform', None)
        linked_bot_chat_id = getattr(placeholder, 'linked_bot_chat_id', None)
        linked_bot_chat_type = getattr(placeholder, 'linked_bot_chat_type', None)
        trust_level = getattr(placeholder, 'trust_level', None)
        final_mode = mode or getattr(placeholder, 'mode', None)
        metadata = getattr(placeholder, 'metadata', None)
        final_project_id = getattr(placeholder, 'project_id', None)

        if sdk_session_id == placeholder.id:
            # Session ID unchanged (e.g., sandbox reused a connector-created session ID).
            # The row already exists in DB — update it with finalization fields.
            update = SessionUpdate(
                title=title or placeholder.title,
                model=model,
                agent_type=final_agent_type,
                working_directory=relative_wd,
                mode=final_mode,
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
                    mode=final_mode,
                    linked_bot_platform=linked_bot_platform,
                    linked_bot_chat_id=linked_bot_chat_id,
                    linked_bot_chat_type=linked_bot_chat_type,
                    project_id=final_project_id,
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
        limit: int = 100,
        offset: int = 0,
    ) -> list[Session]:
        """List sessions with optional filtering."""
        return await self.db.list_sessions(
            module=module,
            archived=archived,
            agent_type=agent_type,
            search=search,
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
        return None

    def get_sdk_transcript_path(
        self, session_id: str, working_directory: Optional[str] = None
    ) -> Optional[Path]:
        """Get the path to the SDK's JSONL transcript for a session."""
        # Determine effective cwd
        if working_directory:
            if os.path.isabs(working_directory):
                if working_directory.startswith("/vault/"):
                    effective_cwd = str(Path.home() / working_directory[len("/vault/"):])
                else:
                    effective_cwd = working_directory
            else:
                effective_cwd = str(Path.home() / working_directory)
        else:
            effective_cwd = str(Path.home())

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
        used when the session was created (e.g., daily agent sessions).

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

        # Import here to avoid circular dependency at module level
        from parachute.api.claude_code import resolve_project_path

        # Search in ~/.claude (primary location)
        home_projects = Path.home() / ".claude" / "projects"
        if home_projects.exists():
            for project_dir in home_projects.iterdir():
                if project_dir.is_dir():
                    candidate = project_dir / filename
                    if candidate.exists():
                        decoded_cwd = resolve_project_path(project_dir)
                        return (candidate, decoded_cwd, "home")

        return None

    async def load_sdk_messages_by_id(
        self,
        session_id: str,
        working_directory: Optional[str] = None,
    ) -> list[dict[str, Any]]:
        """
        Load messages from SDK JSONL file by session ID.

        This is a public method that can be used to load messages for any SDK
        session, including daily agent sessions that don't have a corresponding
        database entry.

        Returns structured content blocks for assistant messages, preserving
        thinking and text blocks.  tool_result blocks are merged into their
        matching tool_use blocks (with ``result`` and ``isError`` fields).

        Args:
            session_id: The SDK session UUID
            working_directory: Optional working directory for path resolution

        Returns:
            List of message dicts with role, content (str or list[dict]), timestamp
        """
        transcript_path = self.get_sdk_transcript_path(session_id, working_directory)

        # If not found at the expected path, search all SDK project directories
        if not transcript_path or not transcript_path.exists():
            transcript_path = self._find_sdk_transcript(session_id)

        if not transcript_path or not transcript_path.exists():
            return []

        messages: list[dict[str, Any]] = []
        last_was_assistant = False
        try:
            with open(transcript_path, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        event = json.loads(line)
                        event_type = event.get("type")

                        if event_type == "user":
                            last_was_assistant = False
                            content = self._extract_message_content(event.get("message", {}))
                            if content:
                                messages.append({
                                    "role": "user",
                                    "content": content,
                                    "timestamp": event.get("timestamp"),
                                })
                        elif event_type == "assistant":
                            last_was_assistant = True
                            blocks = self._extract_message_blocks(event.get("message", {}))
                            if blocks:
                                messages.append({
                                    "role": "assistant",
                                    "content": blocks,
                                    "timestamp": event.get("timestamp"),
                                })
                        elif event_type == "result":
                            # Skip result if we already captured the structured
                            # assistant event (avoids duplicate messages)
                            if last_was_assistant:
                                last_was_assistant = False
                                continue
                            # Fallback: result without preceding assistant event
                            if event.get("result"):
                                messages.append({
                                    "role": "assistant",
                                    "content": [{"type": "text", "text": event["result"]}],
                                    "timestamp": event.get("timestamp"),
                                })

                    except json.JSONDecodeError:
                        continue

        except Exception as e:
            logger.error(f"Error loading SDK transcript: {e}")

        return messages

    def write_sandbox_transcript(
        self,
        session_id: str,
        user_message: str,
        content_blocks: list[dict[str, Any]],
        working_directory: Optional[str] = None,
    ) -> None:
        """Write a synthetic JSONL transcript for a sandbox session.

        Docker container transcripts are lost when the container exits.
        This writes a structured transcript to the host filesystem so messages
        persist across app restarts and session reloads — including thinking
        blocks, tool calls, and tool results.

        Args:
            session_id: The SDK session ID
            user_message: The user's message text
            content_blocks: Structured content blocks (thinking, tool_use, tool_result, text)
            working_directory: Optional working directory for path resolution
        """
        transcript_path = self.get_sdk_transcript_path(session_id, working_directory)
        if not transcript_path:
            logger.warning(f"Could not compute transcript path for sandbox session {session_id[:8]}")
            return

        try:
            transcript_path.parent.mkdir(parents=True, exist_ok=True)

            now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

            # Extract text-only content for the result event (SDK resume compat)
            text_only = " ".join(
                b.get("text", "") for b in content_blocks if b.get("type") == "text"
            ).strip()

            events = [
                {"type": "user", "message": {"role": "user", "content": user_message}, "timestamp": now},
                {"type": "assistant", "message": {"role": "assistant", "content": content_blocks}, "timestamp": now},
                {"type": "result", "result": text_only, "session_id": session_id, "timestamp": now},
            ]

            # Append to existing transcript (supports multi-turn sandbox sessions)
            with open(transcript_path, "a", encoding="utf-8") as f:
                for event in events:
                    f.write(json.dumps(event) + "\n")

            logger.info(f"Wrote sandbox transcript for session {session_id[:8]} at {transcript_path}")
        except Exception as e:
            logger.error(f"Failed to write sandbox transcript: {e}")

    def write_sdk_transcript(
        self,
        session_id: str,
        sdk_events: list[dict[str, Any]],
        cwd: str,
        working_directory: Optional[str] = None,
        model: Optional[str] = None,
    ) -> None:
        """Write SDK events to JSONL transcript for session resume.

        The Claude CLI (v2.1.49+) in SDK pipe mode no longer writes conversation
        data to the JSONL file. This method writes the events in the CLI's
        expected format so --resume can find the conversation.
        """
        transcript_path = self.get_sdk_transcript_path(session_id, working_directory)
        if not transcript_path:
            logger.warning(f"Could not compute transcript path for {session_id[:8]}")
            return

        try:
            transcript_path.parent.mkdir(parents=True, exist_ok=True)

            cli_version = "2.1.49"
            prev_uuid: Optional[str] = None
            entries: list[dict[str, Any]] = []

            for event in sdk_events:
                event_type = event.get("type")
                now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
                    f"{datetime.now(timezone.utc).microsecond // 1000:03d}Z"

                if event_type == "user":
                    msg_content = event.get("message", {}).get("content", "")
                    entry_uuid = str(uuid_mod.uuid4())
                    entry = {
                        "parentUuid": prev_uuid,
                        "isSidechain": False,
                        "userType": "external",
                        "cwd": cwd,
                        "sessionId": session_id,
                        "version": cli_version,
                        "gitBranch": "HEAD",
                        "type": "user",
                        "message": {"role": "user", "content": msg_content},
                        "uuid": entry_uuid,
                        "timestamp": now,
                        "permissionMode": "default",
                    }
                    entries.append(entry)
                    prev_uuid = entry_uuid

                elif event_type == "assistant":
                    msg = event.get("message", {})
                    entry_uuid = str(uuid_mod.uuid4())
                    entry = {
                        "parentUuid": prev_uuid,
                        "isSidechain": False,
                        "userType": "external",
                        "cwd": cwd,
                        "sessionId": session_id,
                        "version": cli_version,
                        "gitBranch": "HEAD",
                        "message": {
                            "model": msg.get("model") or model,
                            "id": f"msg_{uuid_mod.uuid4().hex[:24]}",
                            "type": "message",
                            "role": "assistant",
                            "content": msg.get("content", []),
                            "stop_reason": "end_turn",
                            "stop_sequence": None,
                            "usage": {"input_tokens": 0, "output_tokens": 0},
                        },
                        "requestId": f"req_{uuid_mod.uuid4().hex[:24]}",
                        "type": "assistant",
                        "uuid": entry_uuid,
                        "timestamp": now,
                    }
                    entries.append(entry)
                    prev_uuid = entry_uuid

                elif event_type == "result":
                    entry = {
                        "type": "result",
                        "subtype": "success",
                        "is_error": False,
                        "session_id": session_id,
                        "duration_ms": 0,
                        "result": event.get("result", ""),
                        "uuid": str(uuid_mod.uuid4()),
                        "timestamp": now,
                    }
                    entries.append(entry)

            if not entries:
                return

            with open(transcript_path, "a", encoding="utf-8") as f:
                for entry in entries:
                    f.write(json.dumps(entry) + "\n")

            logger.info(
                f"Wrote {len(entries)} transcript entries for session {session_id[:8]}"
            )
        except Exception as e:
            logger.error(f"Failed to write SDK transcript: {e}")

    async def _load_sdk_messages(self, session: Session) -> list[dict[str, Any]]:
        """Load messages from SDK JSONL file for a Session object.

        Delegates to :meth:`load_sdk_messages_by_id` — see that method for
        full documentation on the returned format.
        """
        return await self.load_sdk_messages_by_id(
            session.id, session.working_directory
        )

    def _extract_message_blocks(self, message: dict[str, Any]) -> list[dict[str, Any]]:
        """Extract all content blocks from an SDK message.

        Preserves thinking, tool_use, and text blocks.  tool_result blocks are
        merged into their matching tool_use block (adding ``result`` and
        ``isError`` fields) so that consumers get a single, self-contained
        representation of each tool call.

        The ``result`` value is normalized to a string — the SDK may return it
        as a list of content blocks, which we join here.

        For backward compatibility, plain string content is wrapped in a text
        block.

        Returns:
            List of content block dicts, never None.
        """
        content = message.get("content", [])
        if isinstance(content, str):
            return [{"type": "text", "text": content}] if content else []

        if isinstance(content, list):
            blocks: list[dict[str, Any]] = []
            tool_results: dict[str, dict[str, Any]] = {}

            # First pass: collect tool_result blocks and non-result blocks
            for block in content:
                if isinstance(block, dict):
                    block_type = block.get("type", "")
                    if block_type == "tool_result":
                        use_id = block.get("toolUseId", "")
                        if use_id:
                            tool_results[use_id] = block
                    elif block_type in ("text", "thinking", "tool_use"):
                        blocks.append(block)
                elif isinstance(block, str):
                    # Legacy: bare strings in content array
                    blocks.append({"type": "text", "text": block})

            # Second pass: merge tool_result into matching tool_use
            if tool_results:
                for i, block in enumerate(blocks):
                    if block.get("type") == "tool_use":
                        result = tool_results.get(block.get("id", ""))
                        if result:
                            raw = result.get("content", "")
                            if isinstance(raw, list):
                                raw = "\n".join(
                                    item.get("text", str(item))
                                    if isinstance(item, dict)
                                    else str(item)
                                    for item in raw
                                )
                            elif not isinstance(raw, str):
                                raw = str(raw)
                            blocks[i] = {
                                **block,
                                "result": raw,
                                "isError": result.get("isError", False),
                            }

            return blocks

        return []

    def _extract_message_content(self, message: dict[str, Any]) -> Optional[str]:
        """Extract text-only content from an SDK message.

        Used by prior-conversation loading and other text-only consumers.
        For structured content, use _extract_message_blocks() instead.
        """
        blocks = self._extract_message_blocks(message)
        text_parts = [b.get("text", "") for b in blocks if b.get("type") == "text"]
        return "\n".join(text_parts) if text_parts else None

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
        imported_dir = Path.home() / "Chat" / "sessions" / "imported"
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

        Get messages from a session, optionally filtering by index.

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
