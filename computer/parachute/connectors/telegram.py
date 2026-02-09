"""
Telegram bot connector.

Bridges Telegram DMs and group chats to Parachute Chat sessions.
Uses python-telegram-bot library (optional dependency).

Install: pip install 'python-telegram-bot>=21.0'
"""

import asyncio
import logging
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
        self._app.add_handler(CommandHandler("journal", self._cmd_journal))
        self._app.add_handler(CommandHandler("j", self._cmd_journal))
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

    async def _cmd_help(self, update: Any, context: Any) -> None:
        """Handle /help command."""
        await update.message.reply_text(
            "Parachute Bot Commands:\n\n"
            "/start - Connect to Parachute\n"
            "/new - Start a new conversation\n"
            "/journal <text> - Create a journal entry\n"
            "/j <text> - Shorthand for /journal\n"
            "/help - Show this help\n\n"
            "Or just send a message to chat."
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

        chat_id = str(update.effective_chat.id)
        chat_type = "dm" if update.effective_chat.type == "private" else "group"
        message_text = update.message.text

        # Group mention gating: only respond to @mentions in group chats
        if chat_type == "group" and self.group_mention_mode == "mention_only":
            bot_me = await self._app.bot.get_me()
            bot_username = bot_me.username
            if bot_username and f"@{bot_username}" not in message_text:
                return  # Silently ignore non-mentions in groups
            # Strip the mention from the message
            if bot_username:
                message_text = message_text.replace(f"@{bot_username}", "").strip()
            if not message_text:
                return  # Nothing left after stripping mention

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
                # Treat as text message
                update.message.text = text
                await self.on_text_message(update, context)
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

    async def send_approval_message(self, chat_id: str) -> None:
        """Send approval confirmation to user via Telegram."""
        if self._app and self._app.bot:
            await self._app.bot.send_message(
                chat_id=int(chat_id),
                text="You've been approved! Send me a message to start chatting.",
            )
