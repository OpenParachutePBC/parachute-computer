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
    ):
        super().__init__(
            bot_token=bot_token,
            server=server,
            allowed_users=allowed_users,
            default_trust_level=default_trust_level,
            dm_trust_level=dm_trust_level,
            group_trust_level=group_trust_level,
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
            await update.message.reply_text(
                "Not authorized. Contact the vault owner to add your Telegram user ID."
            )
            return

        await update.message.reply_text(
            "Connected to Parachute. Send me a message to start chatting, "
            "or use /journal to create a journal entry."
        )

    async def _cmd_help(self, update: Any, context: Any) -> None:
        """Handle /help command."""
        await update.message.reply_text(
            "Parachute Bot Commands:\n\n"
            "/start - Connect to Parachute\n"
            "/journal <text> - Create a journal entry\n"
            "/j <text> - Shorthand for /journal\n"
            "/help - Show this help\n\n"
            "Or just send a message to chat."
        )

    async def _cmd_journal(self, update: Any, context: Any) -> None:
        """Handle /journal command - route to Daily module."""
        user_id = update.effective_user.id
        if not self.is_user_allowed(user_id):
            await update.message.reply_text("Not authorized.")
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
            await update.message.reply_text("Not authorized.")
            return

        chat_id = str(update.effective_chat.id)
        chat_type = "dm" if update.effective_chat.type == "private" else "group"

        # Find or create linked session
        session = await self.get_or_create_session(
            platform="telegram",
            chat_id=chat_id,
            chat_type=chat_type,
            user_display=update.effective_user.full_name,
        )

        if not session:
            await update.message.reply_text("Internal error: could not create session.")
            return

        # Send "typing" indicator
        await update.effective_chat.send_action("typing")

        # Route through Chat orchestrator
        response_text = await self._route_to_chat(
            session_id=session.id,
            message=update.message.text,
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
            await update.message.reply_text("Not authorized.")
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
            async for event in orchestrate(
                session_id=session_id,
                message=message,
                source="telegram",
            ):
                event_type = getattr(event, "type", None) or event.get("type", "")
                if event_type == "text":
                    delta = getattr(event, "delta", None) or event.get("delta", "")
                    response_text += delta
        except Exception as e:
            logger.error(f"Chat orchestration failed: {e}")
            return f"Error: {e}"

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
