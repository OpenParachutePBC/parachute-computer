"""
Abstract bot connector interface.

All platform connectors (Telegram, Discord) inherit from BotConnector
and implement platform-specific message handling.
"""

import asyncio
import logging
import random
import re
import time
from abc import ABC, abstractmethod
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import StrEnum
from typing import Any, ClassVar, Optional

logger = logging.getLogger(__name__)

# Patterns that may leak sensitive info in exception messages
_SENSITIVE_PATTERNS = [
    (re.compile(r"(bot|token)[\"']?\s*[:=]\s*[\"']?([a-zA-Z0-9:_-]{20,})", re.IGNORECASE), r"\1=<REDACTED>"),
    (re.compile(r"/[a-z0-9_.-]+/\.parachute/[^\s]+", re.IGNORECASE), "~/.parachute/<REDACTED>"),
]


class ConnectorState(StrEnum):
    """Connector lifecycle states."""

    STOPPED = "stopped"
    RUNNING = "running"
    RECONNECTING = "reconnecting"
    FAILED = "failed"


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
    """Base class for bot connectors.

    SECURITY WARNING: Bot connectors expose your Parachute instance to external users.
    Use sandboxed trust level for all bots unless you fully understand the security
    implications. See computer/parachute/connectors/SECURITY.md for detailed guidance.

    Args:
        bot_token: Platform-specific bot token/secret
        server: Parachute server instance
        allowed_users: List of user IDs permitted to use the bot
        default_trust_level: Trust level for new sessions ("sandboxed" or "direct")
        dm_trust_level: Override trust level for direct messages
        group_trust_level: Override trust level for group chats
        group_mention_mode: Group chat trigger mode ("mention_only" or "all_messages")
        ack_emoji: Emoji to react with while processing (None to disable)
    """

    platform: str = "unknown"

    def __init__(
        self,
        bot_token: str,
        server: Any,
        allowed_users: list[int | str],
        default_trust_level: str = "sandboxed",
        dm_trust_level: str = "sandboxed",
        group_trust_level: str = "sandboxed",
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

        # Security: Warn about risky trust level configurations
        if default_trust_level == "direct":
            logger.warning(
                f"{self.platform} connector configured with DIRECT trust level. "
                "This allows arbitrary code execution by bot users. "
                "Only use for private, single-user bots. "
                "See computer/parachute/connectors/SECURITY.md for guidance."
            )
        if dm_trust_level == "direct" or group_trust_level == "direct":
            logger.warning(
                f"{self.platform} connector has DIRECT trust for DMs or groups. "
                "This allows arbitrary code execution. "
                "See computer/parachute/connectors/SECURITY.md for security implications."
            )

        # Health tracking
        self._status: ConnectorState = ConnectorState.STOPPED
        self._failure_count: int = 0
        self._last_error: str | None = None
        self._last_error_time: float | None = None
        self._started_at: float | None = None  # monotonic clock
        self._last_message_time: float | None = None  # wall clock for display
        self._reconnect_attempts: int = 0
        self._stop_event: asyncio.Event = asyncio.Event()
        self._task: asyncio.Task | None = None

    @abstractmethod
    async def start(self) -> None:
        """Start the connector (polling or webhook)."""

    @abstractmethod
    async def stop(self) -> None:
        """Stop the connector gracefully."""

    @abstractmethod
    async def on_text_message(self, update: Any, context: Any) -> None:
        """Handle incoming text message."""

    @abstractmethod
    async def _run_loop(self) -> None:
        """Platform-specific connection loop. Raise on failure, return on clean exit."""
        ...

    # Valid state transitions
    _VALID_TRANSITIONS: ClassVar[dict[ConnectorState, set[ConnectorState]]] = {
        ConnectorState.STOPPED: {ConnectorState.RUNNING},
        ConnectorState.RUNNING: {ConnectorState.STOPPED, ConnectorState.RECONNECTING, ConnectorState.FAILED},
        ConnectorState.RECONNECTING: {ConnectorState.RUNNING, ConnectorState.FAILED, ConnectorState.STOPPED},
        ConnectorState.FAILED: {ConnectorState.STOPPED, ConnectorState.RUNNING},
    }

    def _set_status(self, new: ConnectorState) -> None:
        """Transition to a new state with validation."""
        old = self._status
        if new not in self._VALID_TRANSITIONS.get(old, set()):
            logger.warning(f"Invalid connector state transition: {old} -> {new}")
            return
        self._status = new
        # Keep _running in sync for backwards compatibility
        self._running = new == ConnectorState.RUNNING

    def _sanitize_error(self, exc: Exception) -> str:
        """Sanitize exception message for safe API exposure."""
        exc_type = type(exc).__name__
        msg = str(exc)
        for pattern, repl in _SENSITIVE_PATTERNS:
            msg = pattern.sub(repl, msg)
        return f"{exc_type}: {msg[:200]}"

    async def _fire_hook(self, event: Any, context: dict[str, Any]) -> None:
        """Fire a hook event if the hook runner is available."""
        hook_runner = getattr(self.server, "hook_runner", None)
        if hook_runner:
            try:
                await hook_runner.fire(event, context)
            except Exception as e:
                logger.debug(f"Hook fire failed (non-critical): {e}")

    def mark_failed(self, exc: Exception) -> None:
        """Mark connector as failed due to an external error (e.g., start() failure)."""
        self._set_status(ConnectorState.FAILED)
        self._last_error = self._sanitize_error(exc)
        self._last_error_time = time.time()

    async def _run_with_reconnect(self) -> None:
        """Reconnection wrapper with exponential backoff + jitter."""
        from parachute.core.hooks.events import HookEvent

        consecutive_failures = 0
        max_failures = 10

        while not self._stop_event.is_set() and consecutive_failures < max_failures:
            try:
                self._set_status(ConnectorState.RUNNING)
                self._started_at = time.monotonic()
                await self._run_loop()
                # Clean exit — fire reconnection success if recovering from failures
                if consecutive_failures > 0:
                    logger.info(f"{self.platform} connector recovered after {consecutive_failures} attempt(s)")
                    await self._fire_hook(
                        HookEvent.BOT_CONNECTOR_RECONNECTED,
                        {"platform": self.platform, "attempts": consecutive_failures},
                    )
                    self._reconnect_attempts = 0
                break
            except asyncio.CancelledError:
                raise  # Never swallow CancelledError
            except Exception as e:
                consecutive_failures += 1
                self._failure_count += 1
                self._reconnect_attempts = consecutive_failures
                self._last_error = self._sanitize_error(e)
                self._last_error_time = time.time()

                # Fast-fail on auth errors — no point retrying with a bad token
                exc_name = type(e).__name__
                if exc_name in ("InvalidToken", "LoginFailure", "Unauthorized", "Forbidden"):
                    self._set_status(ConnectorState.FAILED)
                    logger.error(f"{self.platform} fatal auth error, not retrying: {e}")
                    await self._fire_hook(
                        HookEvent.BOT_CONNECTOR_DOWN,
                        {"platform": self.platform, "error": self._last_error, "failure_count": 1},
                    )
                    return

                self._set_status(ConnectorState.RECONNECTING)
                logger.error(
                    f"{self.platform} connector error ({consecutive_failures}/{max_failures}): {e}"
                )
                if consecutive_failures < max_failures:
                    # Full Jitter: random(0, min(cap, base * 2^attempt))
                    exp = min(60, 1.0 * (2 ** (consecutive_failures - 1)))
                    delay = random.uniform(0, exp)
                    # Interruptible sleep — stop() can wake us immediately
                    try:
                        await asyncio.wait_for(
                            self._stop_event.wait(), timeout=delay
                        )
                        break  # stop_event was set during backoff
                    except asyncio.TimeoutError:
                        pass  # Timeout expired, retry

        if consecutive_failures >= max_failures:
            self._set_status(ConnectorState.FAILED)
            logger.error(
                f"{self.platform} connector failed after {max_failures} attempts. "
                f"Last error: {self._last_error}"
            )
            await self._fire_hook(
                HookEvent.BOT_CONNECTOR_DOWN,
                {
                    "platform": self.platform,
                    "error": self._last_error,
                    "failure_count": self._failure_count,
                },
            )

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

    async def send_denial_message(self, chat_id: str) -> None:
        """Send denial notification to user. Override in subclasses."""
        logger.info(f"{self.platform}: denial message not implemented for chat {chat_id}")

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
        """Return connector status with health data."""
        return {
            "platform": self.platform,
            "status": self._status.value,
            "running": self._status == ConnectorState.RUNNING,
            "failure_count": self._failure_count,
            "last_error": self._last_error,
            "last_error_time": self._last_error_time,
            "uptime": (time.monotonic() - self._started_at) if self._started_at and self._status == ConnectorState.RUNNING else None,
            "last_message_time": self._last_message_time,
            "reconnect_attempts": self._reconnect_attempts,
            "allowed_users_count": len(self.allowed_users),
        }
