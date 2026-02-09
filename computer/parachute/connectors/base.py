"""
Abstract bot connector interface.

All platform connectors (Telegram, Discord) inherit from BotConnector
and implement platform-specific message handling.
"""

import asyncio
import logging
from abc import ABC, abstractmethod
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Optional

logger = logging.getLogger(__name__)


@dataclass
class GroupMessage:
    """A cached group message for history injection."""

    user_display: str
    text: str
    timestamp: datetime
    message_id: str | int


class GroupHistoryBuffer:
    """Per-chat ring buffer of recent group messages.

    Telegram has no API to fetch chat history — we must cache messages
    as they arrive. Discord has channel.history() but using a buffer
    keeps the approach consistent.
    """

    def __init__(self, max_messages: int = 50, max_chats: int = 500):
        self.max_messages = max_messages
        self.max_chats = max_chats
        self._buffers: dict[str, deque[GroupMessage]] = {}

    def record(self, chat_id: str, msg: GroupMessage) -> None:
        """Record a message in the buffer."""
        if chat_id not in self._buffers:
            # Evict oldest chat if at capacity
            if len(self._buffers) >= self.max_chats:
                oldest = next(iter(self._buffers))
                del self._buffers[oldest]
            self._buffers[chat_id] = deque(maxlen=self.max_messages)
        self._buffers[chat_id].append(msg)

    def get_recent(
        self,
        chat_id: str,
        exclude_message_id: str | int | None = None,
        limit: int = 20,
    ) -> list[GroupMessage]:
        """Get recent messages, optionally excluding the triggering message."""
        buf = self._buffers.get(chat_id, deque())
        messages = list(buf)
        if exclude_message_id is not None:
            messages = [m for m in messages if m.message_id != exclude_message_id]
        return messages[-limit:]

    @staticmethod
    def _sanitize_display_name(name: str) -> str:
        """Strip characters that could break prompt framing."""
        # Remove brackets, angle brackets, newlines
        return name.replace("[", "").replace("]", "").replace("<", "").replace(">", "").replace("\n", " ").strip()[:50]

    def format_for_prompt(self, messages: list[GroupMessage], max_msg_len: int = 500) -> str:
        """Format buffered messages as context block for the prompt.

        Uses XML-like tags to structurally separate group context from the
        current message. Display names are sanitized to prevent prompt
        injection via crafted usernames.
        """
        if not messages:
            return ""
        lines = []
        for msg in messages:
            name = self._sanitize_display_name(msg.user_display)
            text = msg.text[:max_msg_len] if msg.text else ""
            lines.append(f"  {name}: {text}")
        return "<group_context>\n" + "\n".join(lines) + "\n</group_context>"


class BotConnector(ABC):
    """Base class for bot connectors."""

    platform: str = "unknown"

    def __init__(
        self,
        bot_token: str,
        server: Any,
        allowed_users: list[int | str],
        default_trust_level: str = "untrusted",
        dm_trust_level: str = "untrusted",
        group_trust_level: str = "untrusted",
        group_mention_mode: str = "mention_only",
        ack_emoji: str | None = "👀",
    ):
        self.bot_token = bot_token
        self.server = server
        self.allowed_users = allowed_users
        self.default_trust_level = default_trust_level
        self.dm_trust_level = dm_trust_level
        self.group_trust_level = group_trust_level
        self.group_mention_mode = group_mention_mode
        self.ack_emoji = ack_emoji
        self._running = False
        self._chat_locks: dict[str, asyncio.Lock] = {}
        self._trust_overrides: dict[str, str] = {}  # user_id -> trust_level cache
        self._init_nudge_sent: dict[str, int] = {}
        self.group_history = GroupHistoryBuffer(max_messages=50)

    @abstractmethod
    async def start(self) -> None:
        """Start the connector (polling or webhook)."""

    @abstractmethod
    async def stop(self) -> None:
        """Stop the connector gracefully."""

    @abstractmethod
    async def on_text_message(self, update: Any, context: Any) -> None:
        """Handle incoming text message."""

    async def on_voice_message(self, update: Any, context: Any) -> None:
        """Handle incoming voice message. Override in subclasses that support voice."""
        logger.info(f"{self.platform}: voice messages not supported")

    async def on_command(self, update: Any, context: Any) -> None:
        """Handle bot commands. Override in subclasses."""
        logger.info(f"{self.platform}: command received but not handled")

    def is_user_allowed(self, user_id: int | str) -> bool:
        """Check if user is in the allowlist."""
        return user_id in self.allowed_users or str(user_id) in [str(u) for u in self.allowed_users]

    async def handle_unknown_user(
        self,
        platform: str,
        user_id: str,
        user_display: str,
        chat_id: str,
        chat_type: str = "dm",
        message_text: str | None = None,
    ) -> str:
        """Handle message from unknown user — create pairing request + pending session."""
        db = getattr(self.server, "database", None)
        if not db:
            return "Service unavailable."

        # Check for existing pending request
        existing = await db.get_pairing_request_for_user(platform, str(user_id))
        if existing and existing.status == "pending":
            return "Your request is still pending. The owner will approve it shortly."

        # Create new pairing request
        import uuid

        from parachute.models.session import SessionCreate

        request_id = str(uuid.uuid4())
        await db.create_pairing_request(
            id=request_id,
            platform=platform,
            platform_user_id=str(user_id),
            platform_user_display=user_display,
            platform_chat_id=chat_id,
        )
        logger.info(f"Created pairing request {request_id} for {platform} user {user_id}")

        # Also create a pending session so it appears in the Chat list
        session_id = str(uuid.uuid4())
        trust_level = await self.get_trust_level(chat_type)
        create_data = SessionCreate(
            id=session_id,
            title=f"{user_display} ({platform.title()})",
            module="chat",
            source=platform,
            trust_level=trust_level,
            linked_bot_platform=platform,
            linked_bot_chat_id=chat_id,
            linked_bot_chat_type=chat_type,
            metadata={
                "linked_bot": {
                    "platform": platform,
                    "chat_id": chat_id,
                    "chat_type": chat_type,
                    "user_display": user_display,
                    "linked_at": datetime.now(timezone.utc).isoformat(),
                },
                "pending_approval": True,
                "pairing_request_id": request_id,
                "first_message": message_text,
            },
        )
        await db.create_session(create_data)
        logger.info(f"Created pending session {session_id[:8]} for pairing request {request_id[:8]}")

        return "Hi! I need approval before we can chat. Your request has been sent to the owner."

    async def send_approval_message(self, chat_id: str) -> None:
        """Send approval confirmation to user. Override in subclasses."""
        logger.info(f"{self.platform}: approval message not implemented for chat {chat_id}")

    async def get_trust_level(self, chat_type: str, user_id: str | None = None) -> str:
        """Get trust level with per-user override, falling back to platform defaults."""
        if user_id:
            # Check in-memory cache first
            cache_key = str(user_id)
            if cache_key in self._trust_overrides:
                return self._trust_overrides[cache_key]

            # Look up approved pairing request
            db = getattr(self.server, "database", None)
            if db:
                request = await db.get_pairing_request_for_user(self.platform, str(user_id))
                if request and request.status == "approved" and request.approved_trust_level:
                    self._trust_overrides[cache_key] = request.approved_trust_level
                    return request.approved_trust_level

        if chat_type == "dm":
            return self.dm_trust_level
        return self.group_trust_level

    def update_trust_override(self, user_id: str, trust_level: str) -> None:
        """Update the in-memory trust override cache (called on approval)."""
        self._trust_overrides[str(user_id)] = trust_level

    def _get_chat_lock(self, chat_id: str) -> asyncio.Lock:
        """Get or create a per-chat lock (stable across session finalization)."""
        if chat_id not in self._chat_locks:
            self._chat_locks[chat_id] = asyncio.Lock()
        return self._chat_locks[chat_id]

    async def get_or_create_session(
        self,
        platform: str,
        chat_id: str,
        chat_type: str,
        user_display: str,
        user_id: str | None = None,
    ) -> Any:
        """Find existing session linked to this bot chat, or create a new one."""
        from parachute.db.database import Database

        db: Optional[Database] = getattr(self.server, "database", None)
        if not db:
            logger.error("No database available for session lookup")
            return None

        # Look up existing session
        session = await db.get_session_by_bot_link(platform, chat_id)
        if session:
            return session

        # Create new session
        import uuid

        trust_level = await self.get_trust_level(chat_type, user_id=user_id)
        session_id = str(uuid.uuid4())

        from parachute.models.session import SessionCreate

        create_data = SessionCreate(
            id=session_id,
            title=f"{platform.title()} - {user_display}",
            module="chat",
            source=platform,
            trust_level=trust_level,
            linked_bot_platform=platform,
            linked_bot_chat_id=chat_id,
            linked_bot_chat_type=chat_type,
            metadata={
                "linked_bot": {
                    "platform": platform,
                    "chat_id": chat_id,
                    "chat_type": chat_type,
                    "user_display": user_display,
                    "linked_at": datetime.now(timezone.utc).isoformat(),
                },
                "pending_initialization": True,
            },
        )

        session = await db.create_session(create_data)
        logger.info(f"Created {platform} session: {session_id} for chat {chat_id}")
        return session

    async def is_session_initialized(self, session) -> bool:
        """Check if a bot session has been initialized (configured in app)."""
        if not session or not session.metadata:
            return True
        return not session.metadata.get("pending_initialization", False)

    async def send_message(self, chat_id: str, text: str) -> None:
        """Send a message to a chat. Override in subclasses."""
        logger.info(f"{self.platform}: send_message not implemented for chat {chat_id}")

    def clear_init_nudge(self, chat_id: str) -> None:
        """Clear initialization nudge counter for a chat."""
        self._init_nudge_sent.pop(chat_id, None)

    @staticmethod
    def split_response(text: str, max_len: int) -> list[str]:
        """Split response at paragraph boundaries, preserving code blocks."""
        if not text:
            return []
        if len(text) <= max_len:
            return [text]

        chunks = []
        current = ""

        for paragraph in text.split("\n\n"):
            if not current:
                current = paragraph
            elif len(current) + len(paragraph) + 2 <= max_len:
                current += "\n\n" + paragraph
            else:
                chunks.append(current.strip())
                current = paragraph

        if current:
            # If a single paragraph exceeds max_len, force-split
            while len(current) > max_len:
                # Try to split at last newline within limit
                split_pos = current.rfind("\n", 0, max_len)
                if split_pos == -1:
                    split_pos = max_len
                chunks.append(current[:split_pos].strip())
                current = current[split_pos:].strip()
            if current:
                chunks.append(current.strip())

        return chunks

    @property
    def status(self) -> dict:
        """Return connector status."""
        return {
            "platform": self.platform,
            "running": self._running,
            "allowed_users_count": len(self.allowed_users),
        }
