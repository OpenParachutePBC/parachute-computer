"""
Abstract bot connector interface.

All platform connectors (Telegram, Discord) inherit from BotConnector
and implement platform-specific message handling.
"""

import asyncio
import logging
from abc import ABC, abstractmethod
from typing import Any, Optional

logger = logging.getLogger(__name__)


class BotConnector(ABC):
    """Base class for bot connectors."""

    platform: str = "unknown"

    def __init__(
        self,
        bot_token: str,
        server: Any,
        allowed_users: list[int | str],
        default_trust_level: str = "vault",
        dm_trust_level: str = "vault",
        group_trust_level: str = "sandboxed",
        group_mention_mode: str = "mention_only",
    ):
        self.bot_token = bot_token
        self.server = server
        self.allowed_users = allowed_users
        self.default_trust_level = default_trust_level
        self.dm_trust_level = dm_trust_level
        self.group_trust_level = group_trust_level
        self.group_mention_mode = group_mention_mode
        self._running = False
        self._session_locks: dict[str, asyncio.Lock] = {}
        self._trust_overrides: dict[str, str] = {}  # user_id -> trust_level cache

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
        self, platform: str, user_id: str, user_display: str, chat_id: str
    ) -> str:
        """Handle message from unknown user — create pairing request."""
        db = getattr(self.server, "database", None)
        if not db:
            return "Service unavailable."

        # Check for existing pending request
        existing = await db.get_pairing_request_for_user(platform, str(user_id))
        if existing and existing.status == "pending":
            return "Your request is still pending. The owner will approve it shortly."

        # Create new request
        import uuid
        request_id = str(uuid.uuid4())
        await db.create_pairing_request(
            id=request_id,
            platform=platform,
            platform_user_id=str(user_id),
            platform_user_display=user_display,
            platform_chat_id=chat_id,
        )
        logger.info(f"Created pairing request {request_id} for {platform} user {user_id}")
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

    def _get_session_lock(self, session_id: str) -> asyncio.Lock:
        """Get or create a per-session lock for concurrency control."""
        if session_id not in self._session_locks:
            self._session_locks[session_id] = asyncio.Lock()
        return self._session_locks[session_id]

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
        from datetime import datetime

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
                    "linked_at": datetime.utcnow().isoformat() + "Z",
                },
            },
        )

        session = await db.create_session(create_data)
        logger.info(f"Created {platform} session: {session_id} for chat {chat_id}")
        return session

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
