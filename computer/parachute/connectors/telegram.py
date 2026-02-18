"""
Telegram bot connector.

Bridges Telegram DMs and group chats to Parachute Chat sessions.
Uses python-telegram-bot library (optional dependency).

Install: pip install 'python-telegram-bot>=21.0'
"""

import asyncio
import logging
import re
import time
from datetime import datetime, timezone
from typing import Any, Optional

from parachute.connectors.base import BotConnector, ConnectorState, GroupMessage
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
        default_trust_level: str = "untrusted",
        dm_trust_level: str = "untrusted",
        group_trust_level: str = "untrusted",
        group_mention_mode: str = "mention_only",
        ack_emoji: str | None = "👀",
    ):
        super().__init__(
            bot_token=bot_token,
            server=server,
            allowed_users=allowed_users,
            default_trust_level=default_trust_level,
            dm_trust_level=dm_trust_level,
            group_trust_level=group_trust_level,
            group_mention_mode=group_mention_mode,
            ack_emoji=ack_emoji,
        )
        self._app: Optional[Application] = None

    async def start(self) -> None:
        """Start Telegram long-polling."""
        if not TELEGRAM_AVAILABLE:
            raise RuntimeError(
                "python-telegram-bot not installed. "
                "Install with: pip install 'python-telegram-bot>=21.0'"
            )

        self._stop_event.clear()
        logger.info("Telegram connector started (long-polling)")
        # Start polling with reconnection in background
        self._task = asyncio.create_task(self._run_with_reconnect())

    def _build_app(self) -> "Application":
        """Build a fresh Application with all handlers registered."""
        app = Application.builder().token(self.bot_token).build()

        app.add_handler(CommandHandler("start", self._cmd_start))
        app.add_handler(CommandHandler("help", self._cmd_help))
        app.add_handler(CommandHandler("new", self._cmd_new))
        app.add_handler(CommandHandler("ask", self._cmd_ask))
        app.add_handler(CommandHandler("journal", self._cmd_journal))
        app.add_handler(CommandHandler("j", self._cmd_journal))
        app.add_handler(CommandHandler("init", self._cmd_init))
        app.add_handler(
            MessageHandler(filters.TEXT & ~filters.COMMAND, self.on_text_message)
        )
        app.add_handler(
            MessageHandler(filters.VOICE | filters.AUDIO, self.on_voice_message)
        )

        return app

    async def _run_loop(self) -> None:
        """Run Telegram long-polling. Blocks until updater stops or stop is requested.

        Builds a fresh Application each attempt so initialize()/start() are
        re-executed on reconnection — matching Discord's _setup_client() pattern.
        """
        self._app = self._build_app()
        await self._app.initialize()
        await self._app.start()
        try:
            await self._app.updater.start_polling(drop_pending_updates=True)
            # start_polling() returns immediately — block until stop is requested
            # or the updater dies unexpectedly.
            while not self._stop_event.is_set():
                if not self._app.updater.running:
                    raise RuntimeError("Telegram updater stopped unexpectedly")
                await asyncio.sleep(1)
        finally:
            # Clean up this Application instance regardless of outcome
            try:
                if self._app.updater and self._app.updater.running:
                    await self._app.updater.stop()
                if self._app.running:
                    await self._app.stop()
                await self._app.shutdown()
            except Exception as e:
                logger.debug(f"Cleanup during _run_loop teardown: {e}")

    async def stop(self) -> None:
        """Stop Telegram connector."""
        if self._status == ConnectorState.STOPPED:
            return  # Idempotent
        # Set stop_event BEFORE cancelling task — interrupts backoff sleep
        # and breaks _run_loop's while-loop immediately
        self._stop_event.set()
        # Await the background task with timeout (_run_loop handles its own cleanup)
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await asyncio.wait_for(self._task, timeout=5.0)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                pass
        self._task = None
        self._started_at = None
        self._set_status(ConnectorState.STOPPED)
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
                    "linked_at": datetime.now(timezone.utc).isoformat(),
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
        chat_id = str(update.effective_chat.id)

        # Record group messages for history injection (before mention gating,
        # so the buffer captures the full conversation even for ignored messages)
        if chat_type == "group" and update.message:
            self.group_history.record(
                chat_id=chat_id,
                msg=GroupMessage(
                    user_display=update.effective_user.full_name,
                    text=message_text,
                    timestamp=datetime.now(timezone.utc),
                    message_id=update.message.message_id,
                ),
            )

        # Session-aware response mode gating
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

        self._last_message_time = time.time()

        # Ack reaction — instant feedback before acquiring lock
        ack_sent = False
        if self.ack_emoji and update.message:
            try:
                from telegram import ReactionTypeEmoji
                await update.message.set_reaction(
                    reaction=[ReactionTypeEmoji(emoji=self.ack_emoji)]
                )
                ack_sent = True
            except Exception as e:
                logger.debug(f"Ack reaction failed (non-critical): {e}")

        # Inject group history for context (wrapped in XML tags to resist prompt injection)
        effective_message = message_text
        if chat_type == "group":
            recent = self.group_history.get_recent(
                chat_id,
                exclude_message_id=update.message.message_id if update.message else None,
                limit=20,
            )
            if recent:
                history_block = self.group_history.format_for_prompt(recent)
                effective_message = (
                    f"{history_block}\n\n"
                    f"{message_text}"
                )

        # Route through Chat orchestrator with streaming (per-chat lock)
        lock = self._get_chat_lock(chat_id)
        async with lock:
            # Send placeholder message
            placeholder = None
            try:
                placeholder = await update.message.reply_text("Thinking...")
            except Exception as e:
                logger.debug(f"Placeholder send failed: {e}")

            # Stream response — edits placeholder progressively
            await self._stream_to_chat(
                session_id=session.id,
                message=effective_message,
                update=update,
                placeholder=placeholder,
            )

        # Remove ack reaction after response
        if ack_sent and update.message:
            try:
                await update.message.set_reaction(reaction=[])
            except Exception:
                pass

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

        # Ack reaction for voice — _process_text_message handles its own ack for
        # the text phase, but transcription may take a few seconds first
        ack_sent = False
        if self.ack_emoji and update.message:
            try:
                from telegram import ReactionTypeEmoji
                await update.message.set_reaction(
                    reaction=[ReactionTypeEmoji(emoji=self.ack_emoji)]
                )
                ack_sent = True
            except Exception:
                pass

        try:
            voice_file = await voice.get_file()
            transcriber = getattr(self.server, "transcribe", None)
            if transcriber:
                ogg_path = await voice_file.download_to_drive()
                text = await transcriber(str(ogg_path))
                # _process_text_message will set its own ack (replacing ours) and
                # remove it after response, so we don't need cleanup here
                await self._process_text_message(update, text)
            else:
                await update.message.reply_text(
                    "Voice transcription not available on server."
                )
                if ack_sent:
                    try:
                        await update.message.set_reaction(reaction=[])
                    except Exception:
                        pass
        except Exception as e:
            logger.error(f"Voice message handling failed: {e}")
            await update.message.reply_text("Failed to process voice message.")
            if ack_sent:
                try:
                    await update.message.set_reaction(reaction=[])
                except Exception:
                    pass

    async def _stream_to_chat(
        self,
        session_id: str,
        message: str,
        update: Any,
        placeholder: Any | None = None,
    ) -> None:
        """Stream orchestrator response to Telegram, editing draft message progressively."""
        orchestrate = getattr(self.server, "orchestrate", None)
        if not orchestrate:
            logger.error("Server has no orchestrate method")
            error_text = "Chat orchestrator not available."
            if placeholder:
                try:
                    await placeholder.edit_text(error_text)
                except Exception:
                    await update.message.reply_text(error_text)
            else:
                await update.message.reply_text(error_text)
            return

        draft_msg = placeholder
        buffer = ""
        last_edit_len = 0
        edit_count = 0
        max_edits = 25  # Stay under Telegram's ~30-40 edit limit
        min_edit_delta = 150  # Min chars between edits
        error_occurred = False

        try:
            event_count = 0
            async for event in orchestrate(
                session_id=session_id,
                message=message,
                source="telegram",
            ):
                event_count += 1
                event_type = (
                    event.get("type", "") if isinstance(event, dict)
                    else getattr(event, "type", "")
                )

                if event_type == "text":
                    content = (
                        event.get("content", "") if isinstance(event, dict)
                        else getattr(event, "content", "")
                    )
                    if content:
                        buffer = content

                        # Edit draft when enough new content has accumulated
                        delta_since_edit = len(buffer) - last_edit_len
                        if delta_since_edit >= min_edit_delta and edit_count < max_edits:
                            draft_msg = await self._edit_draft(
                                update, draft_msg, buffer
                            )
                            last_edit_len = len(buffer)
                            edit_count += 1

                elif event_type == "error":
                    error_msg = (
                        event.get("error", "") if isinstance(event, dict)
                        else getattr(event, "error", "")
                    )
                    logger.error(f"Orchestrator error event: {error_msg}")
                    error_occurred = True

            # Final edit with complete formatted response
            if buffer:
                formatted = claude_to_telegram(buffer)
                chunks = self.split_response(formatted, TELEGRAM_MAX_MESSAGE_LENGTH)

                # Edit first chunk into draft, or send as reply
                if draft_msg:
                    await self._send_formatted(
                        chunks[0], edit_msg=draft_msg, fallback_reply=update.message
                    )
                else:
                    await self._send_formatted(
                        chunks[0], reply_to=update.message
                    )

                # Send remaining chunks as replies
                for chunk in chunks[1:]:
                    await self._send_formatted(
                        chunk, reply_to=update.message
                    )
            elif not error_occurred:
                no_response = "No response from agent."
                if draft_msg:
                    try:
                        await draft_msg.edit_text(no_response)
                    except Exception:
                        await update.message.reply_text(no_response)
                else:
                    await update.message.reply_text(no_response)

            logger.info(
                f"Telegram streaming: {event_count} events, "
                f"{edit_count} edits, {len(buffer)} chars response"
            )

        except Exception as e:
            logger.error(f"Chat streaming failed: {e}", exc_info=True)
            error_text = "Something went wrong. Please try again later."
            if draft_msg:
                try:
                    await draft_msg.edit_text(error_text)
                except Exception:
                    await update.message.reply_text(error_text)
            else:
                await update.message.reply_text(error_text)

    async def _edit_draft(
        self,
        update: Any,
        draft_msg: Any | None,
        text: str,
    ) -> Any:
        """Edit draft message with intermediate streaming content.

        Uses plain text for intermediate edits (faster, no parse errors).
        Returns the draft message object (creates one if needed).
        """
        # Truncate for intermediate display if over Telegram limit
        display_text = text
        if len(display_text) > TELEGRAM_MAX_MESSAGE_LENGTH:
            display_text = display_text[: TELEGRAM_MAX_MESSAGE_LENGTH - 20] + "\n\n...streaming..."

        if draft_msg is None:
            try:
                return await update.message.reply_text(display_text)
            except Exception as e:
                logger.debug(f"Draft creation failed: {e}")
                return None
        else:
            try:
                await draft_msg.edit_text(display_text)
            except Exception as e:
                if "not modified" not in str(e).lower():
                    logger.debug(f"Draft edit failed: {e}")
            return draft_msg

    async def _send_formatted(
        self,
        text: str,
        *,
        edit_msg: Any | None = None,
        reply_to: Any | None = None,
        fallback_reply: Any | None = None,
    ) -> None:
        """Send or edit a message with MarkdownV2, falling back to plain text.

        Either edit_msg (edit existing) or reply_to (send new) must be provided.
        fallback_reply is used when edit fails entirely (e.g. message was deleted).
        """
        if edit_msg:
            try:
                await edit_msg.edit_text(text, parse_mode="MarkdownV2")
                return
            except Exception:
                pass
            try:
                await edit_msg.edit_text(text)
                return
            except Exception as e:
                logger.warning(f"Final edit failed (message may be deleted): {e}")
                # Fall through to reply as last resort
                if fallback_reply:
                    reply_to = fallback_reply
                else:
                    return

        if reply_to:
            try:
                await reply_to.reply_text(text, parse_mode="MarkdownV2")
            except Exception:
                await reply_to.reply_text(text)

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

    async def send_denial_message(self, chat_id: str) -> None:
        """Send denial notification to user via Telegram."""
        try:
            if self._app and self._app.bot:
                await self._app.bot.send_message(
                    chat_id=int(chat_id),
                    text="Your request was not approved.",
                )
        except Exception as e:
            logger.warning(f"Failed to send denial message to {chat_id}: {e}")
