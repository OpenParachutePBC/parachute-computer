"""
Telegram bot connector.

Bridges Telegram DMs and group chats to Parachute Chat sessions.
Uses python-telegram-bot library (optional dependency).

Install: pip install 'python-telegram-bot>=21.0'
"""

import asyncio
import logging
import re
from typing import Any, Optional

from parachute.connectors.base import BotConnector
from parachute.connectors.message_formatter import claude_to_telegram

logger = logging.getLogger(__name__)

try:
    from telegram import Update
    from telegram.ext import (
        Application,
        CommandHandler,
        ContextTypes,
        MessageHandler,
        filters,
    )

    TELEGRAM_AVAILABLE = True
except ImportError:
    TELEGRAM_AVAILABLE = False

# Telegram message limits
TELEGRAM_MAX_MESSAGE_LENGTH = 4096


class TelegramConnector(BotConnector):
    """Bridges Telegram messages to Parachute Chat sessions."""

    platform = "telegram"

    def __init__(
        self,
        bot_token: str,
        server: Any,
        allowed_users: list[int],
        default_trust_level: str = "vault",
        dm_trust_level: str = "vault",
        group_trust_level: str = "sandboxed",
        group_mention_mode: str = "mention_only",
    ):
        super().__init__(
            bot_token=bot_token,
            server=server,
            allowed_users=allowed_users,
            default_trust_level=default_trust_level,
            dm_trust_level=dm_trust_level,
            group_trust_level=group_trust_level,
            group_mention_mode=group_mention_mode,
        )
        self._app: Optional[Application] = None
        self._polling_task: Optional[asyncio.Task] = None

    async def start(self) -> None:
        """Start Telegram long-polling."""
        if not TELEGRAM_AVAILABLE:
            raise RuntimeError(
                "python-telegram-bot not installed. "
                "Install with: pip install 'python-telegram-bot>=21.0'"
            )

        self._app = Application.builder().token(self.bot_token).build()

        # Register handlers
        self._app.add_handler(CommandHandler("start", self._cmd_start))
        self._app.add_handler(CommandHandler("help", self._cmd_help))
        self._app.add_handler(CommandHandler("new", self._cmd_new))
        self._app.add_handler(CommandHandler("ask", self._cmd_ask))
        self._app.add_handler(CommandHandler("journal", self._cmd_journal))
        self._app.add_handler(CommandHandler("j", self._cmd_journal))
        self._app.add_handler(CommandHandler("init", self._cmd_init))
        self._app.add_handler(
            MessageHandler(filters.TEXT & ~filters.COMMAND, self.on_text_message)
        )
        self._app.add_handler(
            MessageHandler(filters.VOICE | filters.AUDIO, self.on_voice_message)
        )

        await self._app.initialize()
        await self._app.start()
        self._running = True

        logger.info("Telegram connector started (long-polling)")
        # Start polling in background
        self._polling_task = asyncio.create_task(self._poll())

    async def _poll(self) -> None:
        """Run the polling loop."""
        try:
            await self._app.updater.start_polling(drop_pending_updates=True)
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Telegram polling error: {e}")
            self._running = False

    async def stop(self) -> None:
        """Stop Telegram connector."""
        self._running = False
        if self._app:
            if self._app.updater and self._app.updater.running:
                await self._app.updater.stop()
            await self._app.stop()
            await self._app.shutdown()
        if self._polling_task:
            self._polling_task.cancel()
        logger.info("Telegram connector stopped")

    async def _cmd_start(self, update: Any, context: Any) -> None:
        """Handle /start command."""
        user_id = update.effective_user.id
        if not self.is_user_allowed(user_id):
            chat_type = "dm" if update.effective_chat.type == "private" else "group"
            response = await self.handle_unknown_user(
                platform="telegram",
                user_id=str(user_id),
                user_display=update.effective_user.full_name,
                chat_id=str(update.effective_chat.id),
                chat_type=chat_type,
            )
            await update.message.reply_text(response)
            return

        await update.message.reply_text(
            "Connected to Parachute. Send me a message to start chatting, "
            "or use /journal to create a journal entry."
        )

    async def _cmd_new(self, update: Any, context: Any) -> None:
        """Handle /new command - archive current session and start fresh."""
        user_id = update.effective_user.id
        if not self.is_user_allowed(user_id):
            return

        chat_id = str(update.effective_chat.id)
        db = getattr(self.server, "database", None)
        if db:
            session = await db.get_session_by_bot_link("telegram", chat_id)
            if session:
                await db.archive_session(session.id)
                logger.info(f"Archived Telegram session {session.id[:8]} for chat {chat_id}")

        await update.message.reply_text(
            "Starting fresh! Previous conversation archived."
        )

    async def _cmd_ask(self, update: Any, context: Any) -> None:
        """Handle /ask command - ask a question (especially useful in groups)."""
        user_id = update.effective_user.id
        if not self.is_user_allowed(user_id):
            chat_type = "dm" if update.effective_chat.type == "private" else "group"
            response = await self.handle_unknown_user(
                platform="telegram",
                user_id=str(user_id),
                user_display=update.effective_user.full_name,
                chat_id=str(update.effective_chat.id),
                chat_type=chat_type,
            )
            await update.message.reply_text(response)
            return

        text = " ".join(context.args) if context.args else ""
        if not text:
            await update.message.reply_text("Usage: /ask <your question>")
            return

        # Process directly, bypassing group mention gating
        await self._process_text_message(update, text)

    async def _cmd_help(self, update: Any, context: Any) -> None:
        """Handle /help command."""
        await update.message.reply_text(
            "Parachute Bot Commands:\n\n"
            "/start - Connect to Parachute\n"
            "/new - Start a new conversation\n"
            "/init - Re-initialize session (requires app configuration)\n"
            "/ask <text> - Ask a question (works in groups)\n"
            "/journal <text> - Create a journal entry\n"
            "/j <text> - Shorthand for /journal\n"
            "/help - Show this help\n\n"
            "In DMs, just send a message to chat.\n"
            "In groups, use /ask or reply to bot messages. "
            "To enable @mentions, disable Privacy Mode via BotFather."
        )

    async def _cmd_journal(self, update: Any, context: Any) -> None:
        """Handle /journal command - route to Daily module."""
        user_id = update.effective_user.id
        if not self.is_user_allowed(user_id):
            chat_type = "dm" if update.effective_chat.type == "private" else "group"
            response = await self.handle_unknown_user(
                platform="telegram",
                user_id=str(user_id),
                user_display=update.effective_user.full_name,
                chat_id=str(update.effective_chat.id),
                chat_type=chat_type,
            )
            await update.message.reply_text(response)
            return

        text = " ".join(context.args) if context.args else ""
        if not text:
            await update.message.reply_text("Usage: /journal <your journal entry>")
            return

        # Route to Daily module via server
        try:
            result = await self._route_to_daily(text, update)
            await update.message.reply_text(f"Journal entry saved. {result}")
        except Exception as e:
            logger.error(f"Journal entry failed: {e}")
            await update.message.reply_text("Failed to save journal entry.")

    async def _cmd_init(self, update: Any, context: Any) -> None:
        """Handle /init command - archive current session and create fresh pending one."""
        user_id = update.effective_user.id
        if not self.is_user_allowed(user_id):
            return

        chat_id = str(update.effective_chat.id)
        chat_type = "dm" if update.effective_chat.type == "private" else "group"
        db = getattr(self.server, "database", None)

        if db:
            session = await db.get_session_by_bot_link("telegram", chat_id)
            if session:
                await db.archive_session(session.id)
                logger.info(f"Archived Telegram session {session.id[:8]} via /init for chat {chat_id}")

        # Create fresh session with pending_initialization
        import uuid
        from datetime import datetime

        from parachute.models.session import SessionCreate

        session_id = str(uuid.uuid4())
        trust_level = await self.get_trust_level(chat_type, user_id=str(user_id))
        create_data = SessionCreate(
            id=session_id,
            title=f"Telegram - {update.effective_user.full_name}",
            module="chat",
            source="telegram",
            trust_level=trust_level,
            linked_bot_platform="telegram",
            linked_bot_chat_id=chat_id,
            linked_bot_chat_type=chat_type,
            metadata={
                "linked_bot": {
                    "platform": "telegram",
                    "chat_id": chat_id,
                    "chat_type": chat_type,
                    "user_display": update.effective_user.full_name,
                    "linked_at": datetime.utcnow().isoformat() + "Z",
                },
                "pending_initialization": True,
            },
        )
        if db:
            await db.create_session(create_data)

        # Clear any nudge state
        self.clear_init_nudge(chat_id)

        await update.message.reply_text(
            "Session re-initialized! Configure it in the Parachute app, then activate it."
        )

    async def _handle_uninitialized(self, update: Any, chat_id: str) -> None:
        """Handle message to uninitialized session with nudge behavior."""
        count = self._init_nudge_sent.get(chat_id, 0)
        if count == 0:
            await update.message.reply_text(
                "Session created! Configure it in the Parachute app "
                "(set workspace and trust level), then activate it."
            )
        elif count == 1:
            await update.message.reply_text(
                "Still being configured. Please activate in the Parachute app."
            )
        # else: silent ignore
        self._init_nudge_sent[chat_id] = count + 1

    async def on_text_message(self, update: Any, context: Any) -> None:
        """Handle incoming text message."""
        user_id = update.effective_user.id
        if not self.is_user_allowed(user_id):
            chat_type = "dm" if update.effective_chat.type == "private" else "group"
            response = await self.handle_unknown_user(
                platform="telegram",
                user_id=str(user_id),
                user_display=update.effective_user.full_name,
                chat_id=str(update.effective_chat.id),
                chat_type=chat_type,
                message_text=update.message.text,
            )
            await update.message.reply_text(response)
            return

        chat_type = "dm" if update.effective_chat.type == "private" else "group"
        message_text = update.message.text

        # Session-aware response mode gating
        chat_id = str(update.effective_chat.id)
        db = getattr(self.server, "database", None)
        session = await db.get_session_by_bot_link("telegram", chat_id) if db else None

        # Determine response mode: per-session overrides connector default
        default_mode = "all_messages" if chat_type == "dm" else self.group_mention_mode
        if session and session.metadata:
            bs = session.metadata.get("bot_settings", {})
            response_mode = bs.get("response_mode", default_mode)
        else:
            response_mode = default_mode
        logger.debug(f"Response mode for chat {chat_id}: {response_mode} (default={default_mode}, session={session.id if session else None})")

        if response_mode == "mention_only":
            # Check custom mention pattern, fall back to @botusername
            custom_pattern = ""
            if session and session.metadata:
                bs = session.metadata.get("bot_settings", {})
                custom_pattern = bs.get("mention_pattern", "")

            if custom_pattern:
                trigger = custom_pattern
            else:
                bot_me = await self._app.bot.get_me()
                trigger = f"@{bot_me.username}" if bot_me.username else ""

            if trigger and trigger.lower() not in message_text.lower():
                logger.debug(f"Mention gating: trigger={trigger!r} not found in message={message_text!r}")
                return  # Silently ignore non-mentions
            if trigger:
                # Case-insensitive replacement
                message_text = re.sub(re.escape(trigger), "", message_text, flags=re.IGNORECASE).strip()
            if not message_text:
                return

        await self._process_text_message(update, message_text)

    async def _process_text_message(self, update: Any, message_text: str) -> None:
        """Process a text message (shared by on_text_message and /ask command)."""
        chat_id = str(update.effective_chat.id)
        chat_type = "dm" if update.effective_chat.type == "private" else "group"

        # Find or create linked session
        session = await self.get_or_create_session(
            platform="telegram",
            chat_id=chat_id,
            chat_type=chat_type,
            user_display=update.effective_user.full_name,
            user_id=str(update.effective_user.id),
        )

        if not session:
            await update.message.reply_text("Internal error: could not create session.")
            return

        # Check initialization status
        if not await self.is_session_initialized(session):
            await self._handle_uninitialized(update, chat_id)
            return

        # Send "typing" indicator
        await update.effective_chat.send_action("typing")

        # Route through Chat orchestrator (with per-chat lock)
        lock = self._get_chat_lock(chat_id)
        async with lock:
            response_text = await self._route_to_chat(
                session_id=session.id,
                message=message_text,
            )

        if not response_text:
            response_text = "No response from agent."

        # Format and send (handle 4096 char limit)
        formatted = claude_to_telegram(response_text)
        for chunk in self.split_response(formatted, TELEGRAM_MAX_MESSAGE_LENGTH):
            try:
                await update.message.reply_text(chunk, parse_mode="MarkdownV2")
            except Exception:
                # Fallback to plain text if MarkdownV2 parsing fails
                await update.message.reply_text(chunk)

    async def on_voice_message(self, update: Any, context: Any) -> None:
        """Handle incoming voice message."""
        user_id = update.effective_user.id
        if not self.is_user_allowed(user_id):
            chat_type = "dm" if update.effective_chat.type == "private" else "group"
            response = await self.handle_unknown_user(
                platform="telegram",
                user_id=str(user_id),
                user_display=update.effective_user.full_name,
                chat_id=str(update.effective_chat.id),
                chat_type=chat_type,
            )
            await update.message.reply_text(response)
            return

        # Download voice file
        voice = update.message.voice or update.message.audio
        if not voice:
            return

        await update.effective_chat.send_action("typing")

        try:
            voice_file = await voice.get_file()
            # Server-side transcription (if available)
            transcriber = getattr(self.server, "transcribe", None)
            if transcriber:
                ogg_path = await voice_file.download_to_drive()
                text = await transcriber(str(ogg_path))
                # Process transcribed text directly
                await self._process_text_message(update, text)
            else:
                await update.message.reply_text(
                    "Voice transcription not available on server."
                )
        except Exception as e:
            logger.error(f"Voice message handling failed: {e}")
            await update.message.reply_text("Failed to process voice message.")

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
                source="telegram",
            ):
                event_count += 1
                event_type = event.get("type", "") if isinstance(event, dict) else getattr(event, "type", "")
                if event_type == "text":
                    delta = event.get("delta", "") if isinstance(event, dict) else getattr(event, "delta", "")
                    response_text += delta
                elif event_type == "error":
                    error_msg = event.get("error", "") if isinstance(event, dict) else getattr(event, "error", "")
                    logger.error(f"Orchestrator error event: {error_msg}")
            logger.info(f"Telegram orchestration: {event_count} events, {len(response_text)} chars response")
        except Exception as e:
            logger.error(f"Chat orchestration failed: {e}", exc_info=True)
            return "Something went wrong. Please try again later."

        return response_text

    async def _route_to_daily(self, text: str, update: Any) -> str:
        """Route to Daily module for journal entry creation."""
        daily_create = getattr(self.server, "create_journal_entry", None)
        if not daily_create:
            return "Daily module not available."

        try:
            entry = await daily_create(
                content=text,
                source="telegram",
                metadata={"telegram_user": update.effective_user.full_name},
            )
            return f"Entry: {getattr(entry, 'title', 'Untitled')}"
        except Exception as e:
            logger.error(f"Daily entry creation failed: {e}")
            raise

    async def send_message(self, chat_id: str, text: str) -> None:
        """Send a message to a Telegram chat."""
        if self._app and self._app.bot:
            await self._app.bot.send_message(chat_id=int(chat_id), text=text)

    async def send_approval_message(self, chat_id: str) -> None:
        """Send approval confirmation to user via Telegram."""
        if self._app and self._app.bot:
            await self._app.bot.send_message(
                chat_id=int(chat_id),
                text="You've been approved! Send me a message to start chatting.",
            )
