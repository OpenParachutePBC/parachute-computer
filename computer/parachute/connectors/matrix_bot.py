"""
Matrix bot connector.

Bridges Matrix rooms to Parachute Chat sessions.
Uses matrix-nio library (optional dependency).

Install: pip install 'matrix-nio>=0.25.0'
"""

import asyncio
import logging
import re
import time
from datetime import datetime, timezone
from typing import Any, Optional, TypedDict

from parachute.connectors.base import BotConnector, ConnectorState, GroupMessage
from parachute.connectors.message_formatter import claude_to_matrix

logger = logging.getLogger(__name__)

try:
    from nio import (
        AsyncClient,
        InviteMemberEvent,
        LoginError,
        LocalProtocolError,
        MatrixRoom,
        RoomMessageAudio,
        RoomMessageText,
        SyncError,
    )

    MATRIX_AVAILABLE = True
except ImportError:
    MATRIX_AVAILABLE = False

# Matrix event limit is 65KB; 25K text leaves room for HTML + metadata
MATRIX_MAX_MESSAGE_LENGTH = 25000

# Ghost user prefixes for bridge detection (mautrix bridges)
BRIDGE_GHOST_PREFIXES = ["meta", "telegram", "discord", "signal", "whatsapp"]

# Module-level patterns match any homeserver (used by tests and as fallback)
BRIDGE_GHOST_PATTERNS = [
    re.compile(rf"^@{prefix}_\d+:.+$") for prefix in BRIDGE_GHOST_PREFIXES
]

# Bridge bot user patterns
BRIDGE_BOT_PATTERNS = [
    re.compile(r"^@(meta|telegram|discord|signal|whatsapp)bot:.+$"),
]


class BridgeInfo(TypedDict):
    """Structured bridge detection result."""
    bridge_type: str
    ghost_users: list[str]
    bridge_bots: list[str]
    remote_chat_type: str  # "dm" | "group"


def _compile_ghost_patterns(homeserver_url: str) -> list[re.Pattern]:
    """Compile ghost patterns scoped to the local homeserver domain.

    This prevents federated users with bridge-like prefixes from being
    misclassified as bridge ghosts.
    """
    # Extract domain from homeserver URL (e.g., "localhost" from "http://localhost:6167")
    from urllib.parse import urlparse
    parsed = urlparse(homeserver_url)
    domain = parsed.hostname or "localhost"
    escaped = re.escape(domain)
    return [
        re.compile(rf"^@{prefix}_\d+:{escaped}(:\d+)?$")
        for prefix in BRIDGE_GHOST_PREFIXES
    ]


class MatrixConnector(BotConnector):
    """Bridges Matrix messages to Parachute Chat sessions."""

    platform = "matrix"

    def __init__(
        self,
        homeserver_url: str,
        user_id: str,
        access_token: str,
        device_id: str,
        server: Any,
        allowed_users: list[str],
        allowed_rooms: list[str],
        default_trust_level: str = "sandboxed",
        dm_trust_level: str = "sandboxed",
        group_trust_level: str = "sandboxed",
        group_mention_mode: str = "mention_only",
        ack_emoji: str | None = "👀",
    ):
        super().__init__(
            bot_token=access_token,  # base class stores as bot_token
            server=server,
            allowed_users=allowed_users,
            default_trust_level=default_trust_level,
            dm_trust_level=dm_trust_level,
            group_trust_level=group_trust_level,
            group_mention_mode=group_mention_mode,
            ack_emoji=ack_emoji,
        )
        self.homeserver_url = homeserver_url
        self.user_id = user_id
        self.access_token = access_token
        self.device_id = device_id
        self.allowed_rooms = allowed_rooms
        self._client: Optional[Any] = None
        self._initial_sync_done = False
        # Scope ghost patterns to local homeserver to prevent federated spoofing
        self._ghost_patterns = _compile_ghost_patterns(homeserver_url)

    async def start(self) -> None:
        """Start Matrix bot."""
        if not MATRIX_AVAILABLE:
            raise RuntimeError(
                "matrix-nio not installed. "
                "Install with: pip install 'matrix-nio>=0.25.0'"
            )

        self._stop_event.clear()
        self._task = asyncio.create_task(self._run_with_reconnect())
        logger.info("Matrix connector started")

    def _setup_client(self) -> None:
        """Create Matrix client and register event callbacks."""
        self._client = AsyncClient(
            self.homeserver_url,
            self.user_id,
        )
        self._client.access_token = self.access_token
        self._client.device_id = self.device_id
        self._initial_sync_done = False

        # Register callbacks
        self._client.add_event_callback(self._on_message, RoomMessageText)
        self._client.add_event_callback(self._on_audio_message, RoomMessageAudio)
        self._client.add_event_callback(self._on_invite, InviteMemberEvent)

    async def _run_loop(self) -> None:
        """Run Matrix sync loop. Returns on clean close, raises on error.

        Builds a fresh client each attempt so reconnection gets a clean state.
        """
        self._setup_client()
        try:
            # sync_forever handles the long-poll loop internally
            await self._client.sync_forever(timeout=30000, full_state=True)
        finally:
            if self._client:
                await self._client.close()

    async def stop(self) -> None:
        """Stop Matrix bot."""
        if self._status == ConnectorState.STOPPED:
            return
        self._stop_event.set()
        if self._client:
            try:
                await self._client.close()
            except Exception as e:
                logger.warning(f"Error during Matrix client close: {e}")
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await asyncio.wait_for(self._task, timeout=5.0)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                pass
        self._task = None
        self._started_at = None
        self._set_status(ConnectorState.STOPPED)
        logger.info("Matrix connector stopped")

    # ── Event callbacks ──────────────────────────────────────────────

    async def _on_message(self, room: Any, event: Any) -> None:
        """Callback for RoomMessageText events."""
        # Ignore messages from ourselves
        if event.sender == self.user_id:
            return

        # Ignore messages from before our sync (backfill)
        if not self._initial_sync_done:
            self._initial_sync_done = True
            return

        await self.on_text_message(
            update={"room": room, "event": event},
            context=None,
        )

    async def _on_audio_message(self, room: Any, event: Any) -> None:
        """Callback for RoomMessageAudio events."""
        if event.sender == self.user_id:
            return
        if not self._initial_sync_done:
            return
        await self.on_voice_message(
            update={"room": room, "event": event},
            context=None,
        )

    async def _on_invite(self, room: Any, event: Any) -> None:
        """Handle room invites.

        For allowed rooms: join immediately.
        For non-allowed rooms: join, check for bridge patterns, and create
        a pairing request if bridged.
        """
        if event.state_key != self.user_id:
            return

        room_id = room.room_id

        if self._is_room_allowed(room_id):
            # Auto-join allowed rooms
            if self._client:
                try:
                    await self._client.join(room_id)
                    logger.info(f"Auto-joined allowed Matrix room: {room_id}")
                except Exception as e:
                    logger.error(f"Failed to join room {room_id}: {e}")
            return

        # Join the room first (needed to inspect members for bridge detection)
        if not self._client:
            return
        try:
            await self._client.join(room_id)
            logger.info(f"Joined Matrix room for bridge detection: {room_id}")
        except Exception as e:
            logger.warning(f"Failed to join room {room_id}: {e}")
            return

        # Detect if bridged
        bridge_info = await self._detect_bridge_room(room_id)

        if bridge_info:
            room_name = await self._get_room_display_name(room_id)
            await self._handle_bridged_room(room_id, room_name, bridge_info)
        else:
            # Not bridged and not allowed — leave to avoid accumulating memberships
            logger.info(f"Non-bridged, non-allowed room {room_id} — leaving")
            try:
                await self._client.room_leave(room_id)
            except Exception as e:
                logger.warning(f"Failed to leave room {room_id}: {e}")

    async def _handle_bridged_room(
        self, room_id: str, room_name: str, bridge_info: BridgeInfo
    ) -> None:
        """Create pairing request for a bridged room.

        Intentionally separate from base handle_unknown_user() because room-based
        pairing is semantically different (room_id as identifier, bridge metadata).
        """
        import uuid
        from parachute.models.session import SessionCreate

        db = getattr(self.server, "database", None)
        if not db:
            return

        # Check for existing pending request for this room
        existing = await db.get_pairing_request_for_user("matrix", room_id)
        if existing and existing.status == "pending":
            logger.info(f"Pairing request already pending for bridged room {room_id}")
            return

        # Create pairing request (room_id as platform_user_id for room-based pairing)
        request_id = str(uuid.uuid4())
        bridge_type = bridge_info.get("bridge_type", "unknown")
        display_name = f"{room_name} ({bridge_type.title()} Bridge)"

        await db.create_pairing_request(
            id=request_id,
            platform="matrix",
            platform_user_id=room_id,
            platform_user_display=display_name,
            platform_chat_id=room_id,
        )
        logger.info(f"Created pairing request {request_id[:8]} for bridged room {room_id}")

        # Create pending session so it appears in the Chat list
        session_id = str(uuid.uuid4())
        chat_type = bridge_info["remote_chat_type"]
        trust_level = await self.get_trust_level(chat_type)

        create_data = SessionCreate(
            id=session_id,
            title=display_name,
            module="chat",
            source="matrix",
            trust_level=trust_level,
            linked_bot_platform="matrix",
            linked_bot_chat_id=room_id,
            linked_bot_chat_type=chat_type,
            metadata={
                "linked_bot": {
                    "platform": "matrix",
                    "chat_id": room_id,
                    "chat_type": chat_type,
                    "user_display": display_name,
                    "linked_at": datetime.now(timezone.utc).isoformat(),
                },
                "pending_approval": True,
                "pairing_request_id": request_id,
                "bridge_metadata": bridge_info,
            },
        )
        await db.create_session(create_data)
        logger.info(f"Created pending session {session_id[:8]} for bridged room {room_id}")

        # Notify in the room
        await self._send_room_message(
            room_id,
            "I've joined this bridged room. Waiting for approval in the Parachute app.",
        )

    # ── Message handling ─────────────────────────────────────────────

    async def _resolve_bridge_auth(
        self, room_id: str, sender: str, room: Any
    ) -> tuple[str, bool, Any]:
        """Resolve chat type and authorization for bridge-aware rooms.

        Returns (chat_type, is_authorized, session).
        """
        db = getattr(self.server, "database", None)
        session = await db.get_session_by_bot_link("matrix", room_id) if db else None
        bridge_meta = (session.metadata or {}).get("bridge_metadata") if session else None

        if bridge_meta and bridge_meta.get("remote_chat_type"):
            chat_type = bridge_meta["remote_chat_type"]
        else:
            member_count = getattr(room, "member_count", 0) or getattr(room, "joined_count", 0) or 2
            chat_type = "dm" if member_count <= 2 else "group"

        if chat_type == "group" or bridge_meta:
            return chat_type, self._is_room_allowed(room_id), session
        else:
            return chat_type, self.is_user_allowed(sender), session

    async def on_text_message(self, update: Any, context: Any) -> None:
        """Handle incoming text message from Matrix."""
        room = update["room"]
        event = update["event"]

        room_id = room.room_id
        sender = event.sender
        message_text = event.body

        # Bridge-aware auth check (single DB query, reused below)
        chat_type, is_authorized, session = await self._resolve_bridge_auth(room_id, sender, room)

        if not is_authorized:
            # For DMs to unknown users, trigger the pairing flow
            if chat_type == "dm":
                user_display = self._get_display_name(room, sender)
                response = await self.handle_unknown_user(
                    platform="matrix",
                    user_id=sender,
                    user_display=user_display,
                    chat_id=room_id,
                    chat_type="dm",
                    message_text=message_text,
                )
                await self._send_room_message(room_id, response)
            return

        # Record message for group history
        if chat_type == "group":
            self.group_history.record(
                room_id,
                GroupMessage(
                    user_display=self._get_display_name(room, sender),
                    text=message_text,
                    timestamp=datetime.now(timezone.utc),
                    message_id=event.event_id,
                ),
            )

        default_mode = "all_messages" if chat_type == "dm" else self.group_mention_mode
        if session and session.metadata:
            bs = session.metadata.get("bot_settings", {})
            response_mode = bs.get("response_mode", default_mode)
        else:
            response_mode = default_mode

        if response_mode == "mention_only" and chat_type == "group":
            if not self._detect_mention(event):
                return
            # Strip mention from message
            message_text = self._strip_mention(message_text)
            if not message_text:
                return

        # Check for commands
        if message_text.startswith("!"):
            handled = await self._handle_command(room_id, sender, message_text, chat_type)
            if handled:
                return

        # Find or create linked session
        user_display = self._get_display_name(room, sender)
        session = await self.get_or_create_session(
            platform="matrix",
            chat_id=room_id,
            chat_type=chat_type,
            user_display=user_display,
            user_id=sender,
        )

        if not session:
            await self._send_room_message(room_id, "Internal error: could not create session.")
            return

        # Check initialization status
        if not await self.is_session_initialized(session):
            count = self._init_nudge_sent.get(room_id, 0)
            if count == 0:
                await self._send_room_message(
                    room_id,
                    "Session created! Configure it in the Parachute app "
                    "(set workspace and trust level), then activate it.",
                )
            elif count == 1:
                await self._send_room_message(
                    room_id,
                    "Still being configured. Please activate in the Parachute app.",
                )
            self._init_nudge_sent[room_id] = count + 1
            return

        self._last_message_time = time.time()

        # Ack reaction
        ack_sent = False
        if self.ack_emoji and self._client:
            try:
                await self._client.room_send(
                    room_id,
                    message_type="m.reaction",
                    content={
                        "m.relates_to": {
                            "rel_type": "m.annotation",
                            "event_id": event.event_id,
                            "key": self.ack_emoji,
                        }
                    },
                )
                ack_sent = True
            except Exception as e:
                logger.debug(f"Ack reaction failed (non-critical): {e}")

        # Inject group history for context
        effective_message = message_text
        if chat_type == "group":
            recent = self.group_history.get_recent(room_id, exclude_message_id=event.event_id)
            if recent:
                history_text = self.group_history.format_for_prompt(recent)
                effective_message = f"{history_text}\n\n{message_text}"

        # Show typing indicator with per-chat lock
        lock = self._get_chat_lock(room_id)
        async with lock:
            # Start typing indicator
            if self._client:
                try:
                    await self._client.room_typing(room_id, typing_state=True, timeout=30000)
                except Exception:
                    pass

            response_text = await self._route_to_chat(
                session_id=session.id,
                message=effective_message,
            )

            # Stop typing indicator
            if self._client:
                try:
                    await self._client.room_typing(room_id, typing_state=False)
                except Exception:
                    pass

        if not response_text:
            response_text = "No response from agent."

        # Format and send (handle 25K char limit)
        plain, html = claude_to_matrix(response_text)
        for chunk_plain, chunk_html in self._split_matrix_response(plain, html):
            await self._send_room_message(room_id, chunk_plain, chunk_html)

        # Remove ack reaction after response (Matrix requires redaction)
        if ack_sent and self._client:
            # Matrix doesn't have a simple "remove reaction" — would need to
            # redact the reaction event. Skip for simplicity in v1.
            pass

    async def on_voice_message(self, update: Any, context: Any) -> None:
        """Handle incoming voice/audio message from Matrix."""
        room = update["room"]
        event = update["event"]
        room_id = room.room_id
        sender = event.sender

        # Bridge-aware auth check (shared with text handler)
        _chat_type, is_authorized, _session = await self._resolve_bridge_auth(room_id, sender, room)
        if not is_authorized:
            return

        # Download audio from homeserver
        if not self._client:
            return

        try:
            url = event.url  # mxc:// URL
            response = await self._client.download(url)
            if hasattr(response, "body"):
                audio_data = response.body
            else:
                logger.warning("Failed to download Matrix audio message")
                return
        except Exception as e:
            logger.warning(f"Failed to download Matrix audio: {e}")
            return

        # Transcribe using server's transcription
        transcribe = getattr(self.server, "transcribe_audio", None)
        if not transcribe:
            await self._send_room_message(room_id, "Voice messages are not supported (no transcription service).")
            return

        try:
            transcription = await transcribe(audio_data)
            if transcription:
                # Process the transcribed text as a regular message
                update["event"] = type(event)(
                    body=transcription,
                    event_id=event.event_id,
                    sender=sender,
                    server_timestamp=event.server_timestamp,
                    source=getattr(event, "source", {}),
                )
                await self.on_text_message(update, context)
        except Exception as e:
            logger.error(f"Voice transcription failed: {e}")

    # ── Commands ─────────────────────────────────────────────────────

    async def _handle_command(
        self, room_id: str, sender: str, message_text: str, chat_type: str
    ) -> bool:
        """Handle !command messages. Returns True if a command was handled."""
        parts = message_text.strip().split(maxsplit=1)
        command = parts[0].lower()

        if command == "!new":
            db = getattr(self.server, "database", None)
            if db:
                session = await db.get_session_by_bot_link("matrix", room_id)
                if session:
                    await db.archive_session(session.id)
                    logger.info(f"Archived Matrix session {session.id[:8]} for room {room_id}")
            await self._send_room_message(room_id, "Starting fresh! Previous conversation archived.")
            return True

        elif command == "!help":
            help_text = (
                "Available commands:\n"
                "!new — Start a new conversation (archives current)\n"
                "!help — Show this message\n"
                "!journal <entry> — Create a journal entry\n"
                "\nYou can also just send a message to chat."
            )
            await self._send_room_message(room_id, help_text)
            return True

        elif command == "!journal":
            entry = parts[1] if len(parts) > 1 else ""
            if not entry:
                await self._send_room_message(room_id, "Usage: !journal <your entry>")
                return True

            try:
                daily_create = getattr(self.server, "create_journal_entry", None)
                if not daily_create:
                    await self._send_room_message(room_id, "Daily module not available.")
                    return True

                user_display = self._get_display_name_by_id(sender)
                result = await daily_create(
                    content=entry,
                    source="matrix",
                    metadata={"matrix_user": user_display},
                )
                title = getattr(result, "title", "Untitled")
                await self._send_room_message(room_id, f"Journal entry saved: {title}")
            except Exception as e:
                logger.error(f"Journal entry failed: {e}")
                await self._send_room_message(room_id, "Failed to save journal entry.")
            return True

        return False

    # ── Bridge detection ─────────────────────────────────────────────

    async def _detect_bridge_room(self, room_id: str) -> Optional[BridgeInfo]:
        """Detect if a room is bridged by checking member patterns.

        Returns BridgeInfo with bridge_type, ghost_users, remote_chat_type or None.
        Uses homeserver-scoped patterns to prevent federated user spoofing.
        """
        if not self._client:
            return None

        try:
            resp = await self._client.joined_members(room_id)
            if not hasattr(resp, "members"):
                return None
            members = resp.members
        except Exception as e:
            logger.warning(f"Failed to get members for bridge detection in {room_id}: {e}")
            return None

        ghost_users: list[str] = []
        bridge_bots: list[str] = []
        bridge_type: Optional[str] = None

        for member_id in members:
            # Check if ghost user (scoped to local homeserver)
            for pattern in self._ghost_patterns:
                if pattern.match(member_id):
                    ghost_users.append(member_id)
                    # Extract bridge type from pattern (e.g., "meta" from "@meta_123:...")
                    bridge_type = member_id.split("_")[0].lstrip("@")
                    break
            # Check if bridge bot
            for pattern in BRIDGE_BOT_PATTERNS:
                if pattern.match(member_id):
                    bridge_bots.append(member_id)
                    break

        if not ghost_users:
            return None

        # 1 ghost user = bridged DM, 2+ = bridged group
        remote_chat_type = "dm" if len(ghost_users) == 1 else "group"

        return BridgeInfo(
            bridge_type=bridge_type or "unknown",
            ghost_users=ghost_users,
            bridge_bots=bridge_bots,
            remote_chat_type=remote_chat_type,
        )

    async def _get_room_display_name(self, room_id: str) -> str:
        """Get a display name for a room (room name or first ghost user's display name)."""
        if not self._client:
            return room_id

        # Try to get the room name from synced state
        room = self._client.rooms.get(room_id)
        if room:
            name = getattr(room, "name", None) or getattr(room, "display_name", None)
            if name:
                return name

        # Fallback: use room_id
        return room_id

    # ── Helpers ───────────────────────────────────────────────────────

    def _is_room_allowed(self, room_id: str) -> bool:
        """Check if a room is in the allowed_rooms list.

        Empty allowed_rooms means all rooms are allowed.
        Matches both room IDs (!abc:server) and aliases (#room:server).
        """
        if not self.allowed_rooms:
            return True
        return room_id in self.allowed_rooms

    def _detect_mention(self, event: Any) -> bool:
        """Detect if the bot was mentioned in a message.

        Checks m.mentions content field first (modern Matrix),
        then falls back to display name / MXID text matching.
        """
        # Check m.mentions in event content (modern Matrix spec)
        source = getattr(event, "source", {})
        content = source.get("content", {}) if isinstance(source, dict) else {}
        mentions = content.get("m.mentions", {})
        if mentions:
            user_ids = mentions.get("user_ids", [])
            if self.user_id in user_ids:
                return True

        # Fallback: check for MXID or display name in body text
        body = event.body or ""
        if self.user_id in body:
            return True

        # Check display name
        display_name = self.user_id.split(":")[0].lstrip("@")
        if display_name.lower() in body.lower():
            return True

        return False

    def _strip_mention(self, text: str) -> str:
        """Remove bot mention from message text."""
        # Remove MXID mention
        text = text.replace(self.user_id, "").strip()
        # Remove display name mention
        display_name = self.user_id.split(":")[0].lstrip("@")
        import re

        text = re.sub(re.escape(display_name), "", text, flags=re.IGNORECASE).strip()
        return text

    def _get_display_name(self, room: Any, user_id: str) -> str:
        """Get user display name from room state."""
        if hasattr(room, "user_name") and callable(room.user_name):
            name = room.user_name(user_id)
            if name:
                return name
        if hasattr(room, "users"):
            user = room.users.get(user_id)
            if user and hasattr(user, "display_name") and user.display_name:
                return user.display_name
        # Fallback: extract localpart from MXID
        return user_id.split(":")[0].lstrip("@")

    def _get_display_name_by_id(self, user_id: str) -> str:
        """Get display name from just a user ID (no room context)."""
        return user_id.split(":")[0].lstrip("@")

    async def _send_room_message(
        self, room_id: str, plain_text: str, html_text: str | None = None
    ) -> None:
        """Send a message to a Matrix room."""
        if not self._client:
            return

        content: dict[str, Any] = {
            "msgtype": "m.text",
            "body": plain_text,
        }
        if html_text:
            content["format"] = "org.matrix.custom.html"
            content["formatted_body"] = html_text

        try:
            await self._client.room_send(
                room_id,
                message_type="m.room.message",
                content=content,
            )
        except Exception as e:
            logger.error(f"Failed to send Matrix message to {room_id}: {e}")

    def _split_matrix_response(
        self, plain: str, html: str
    ) -> list[tuple[str, str]]:
        """Split a response into chunks that fit within Matrix limits.

        Returns list of (plain_chunk, html_chunk) tuples.
        For simplicity, split based on plain text length and pair with
        corresponding HTML chunks (split at same boundaries).
        """
        if len(plain) <= MATRIX_MAX_MESSAGE_LENGTH:
            return [(plain, html)]

        # Split plain text, send HTML only with first chunk
        plain_chunks = self.split_response(plain, MATRIX_MAX_MESSAGE_LENGTH)
        result = []
        for i, chunk in enumerate(plain_chunks):
            if i == 0:
                result.append((chunk, html))
            else:
                result.append((chunk, ""))
        return result

    async def _route_to_chat(self, session_id: str, message: str) -> str:
        """Route a message through the Chat orchestrator and collect response."""
        response_text = ""
        orchestrate = getattr(self.server, "orchestrate", None)
        if not orchestrate:
            logger.error("Server has no orchestrate method")
            return "Chat orchestrator not available."

        try:
            event_count = 0
            async for event in orchestrate(
                session_id=session_id,
                message=message,
                source="matrix",
            ):
                event_count += 1
                event_type = event.get("type", "") if isinstance(event, dict) else getattr(event, "type", "")
                if event_type == "text":
                    content = event.get("content", "") if isinstance(event, dict) else getattr(event, "content", "")
                    if content:
                        response_text = content
                elif event_type == "error":
                    error_msg = event.get("error", "") if isinstance(event, dict) else getattr(event, "error", "")
                    logger.error(f"Orchestrator error event: {error_msg}")

                elif event_type == "typed_error":
                    title = event.get("title", "Error") if isinstance(event, dict) else getattr(event, "title", "Error")
                    msg = event.get("message", "") if isinstance(event, dict) else getattr(event, "message", "")
                    error_text = f"{title}: {msg}" if msg else title
                    logger.error(f"Orchestrator typed error: {error_text}")
                    response_text += f"\n\n⚠️ {error_text}"

                elif event_type == "warning":
                    title = event.get("title", "Warning") if isinstance(event, dict) else getattr(event, "title", "Warning")
                    msg = event.get("message", "") if isinstance(event, dict) else getattr(event, "message", "")
                    warning_text = f"{title}: {msg}" if msg else title
                    logger.warning(f"Orchestrator warning: {warning_text}")
                    response_text += f"\n\n⚠️ {warning_text}"
            logger.info(f"Matrix orchestration: {event_count} events, {len(response_text)} chars response")
        except Exception as e:
            logger.error(f"Chat orchestration failed: {e}", exc_info=True)
            return "Something went wrong. Please try again later."

        return response_text

    async def send_message(self, chat_id: str, text: str) -> None:
        """Send a message to a Matrix room (public API)."""
        await self._send_room_message(chat_id, text)

    async def send_approval_message(self, chat_id: str) -> None:
        """Send approval confirmation to user via Matrix."""
        await self._send_room_message(
            chat_id, "You've been approved! Send me a message to start chatting."
        )

    async def send_denial_message(self, chat_id: str) -> None:
        """Send denial notification to user via Matrix."""
        try:
            await self._send_room_message(chat_id, "Your request was not approved.")
        except Exception as e:
            logger.warning(f"Failed to send denial message to {chat_id}: {e}")

    @property
    def status(self) -> dict:
        """Return connector status with health data."""
        base = super().status
        base["allowed_rooms_count"] = len(self.allowed_rooms)
        return base
