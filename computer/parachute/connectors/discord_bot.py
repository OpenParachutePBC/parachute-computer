"""
Discord bot connector.

Bridges Discord channels to Parachute Chat sessions.
Uses discord.py library (optional dependency).

Install: pip install 'discord.py>=2.3'
"""

import asyncio
import logging
import time
from typing import Any, Optional

from parachute.connectors.base import BotConnector, ConnectorState
from parachute.connectors.message_formatter import claude_to_discord

logger = logging.getLogger(__name__)

try:
    import discord
    from discord import app_commands

    DISCORD_AVAILABLE = True
except ImportError:
    DISCORD_AVAILABLE = False

# Discord message limit
DISCORD_MAX_MESSAGE_LENGTH = 2000


class DiscordConnector(BotConnector):
    """Bridges Discord messages to Parachute Chat sessions."""

    platform = "discord"

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
        self._client: Optional[Any] = None
        self._tree: Optional[Any] = None

    async def start(self) -> None:
        """Start Discord bot."""
        if not DISCORD_AVAILABLE:
            raise RuntimeError(
                "discord.py not installed. "
                "Install with: pip install 'discord.py>=2.3'"
            )

        self._stop_event.clear()
        # Start bot with reconnection in background
        self._task = asyncio.create_task(self._run_with_reconnect())
        logger.info("Discord connector started")

    def _setup_client(self) -> None:
        """Create Discord client and register handlers."""
        intents = discord.Intents.default()
        intents.message_content = True

        self._client = discord.Client(intents=intents)
        self._tree = app_commands.CommandTree(self._client)

        # Register slash commands
        @self._tree.command(name="chat", description="Chat with Parachute")
        async def chat_cmd(interaction: discord.Interaction, message: str):
            await self._handle_chat(interaction, message)

        @self._tree.command(name="new", description="Start a new conversation")
        async def new_cmd(interaction: discord.Interaction):
            await self._handle_new(interaction)

        @self._tree.command(name="journal", description="Create a journal entry")
        async def journal_cmd(interaction: discord.Interaction, entry: str):
            await self._handle_journal(interaction, entry)

        @self._client.event
        async def on_ready():
            logger.info(f"Discord bot logged in as {self._client.user}")
            try:
                await self._tree.sync()
                logger.info("Synced slash commands globally")
            except Exception as e:
                logger.error(f"Failed to sync global commands: {e}")

        @self._client.event
        async def on_message(message: discord.Message):
            if message.author == self._client.user:
                return
            await self.on_text_message(message, None)

    async def _run_loop(self) -> None:
        """Run Discord gateway client. Returns on clean close, raises on error.

        Builds a fresh client each attempt so reconnection gets a clean state.
        """
        self._setup_client()
        # reconnect=False disables network-error auto-recovery (we handle it).
        # Discord RESUME protocol for server-initiated reconnects still works.
        await self._client.start(self.bot_token, reconnect=False)

    async def stop(self) -> None:
        """Stop Discord bot."""
        if self._status == ConnectorState.STOPPED:
            return  # Idempotent
        # Set stop_event BEFORE cancelling task — interrupts backoff sleep immediately
        self._stop_event.set()
        if self._client:
            try:
                await self._client.close()
            except Exception as e:
                logger.warning(f"Error during Discord client close: {e}")
        # Await the background task with timeout
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await asyncio.wait_for(self._task, timeout=5.0)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                pass
        self._task = None
        self._started_at = None
        self._set_status(ConnectorState.STOPPED)
        logger.info("Discord connector stopped")

    async def on_text_message(self, update: Any, context: Any) -> None:
        """Handle incoming text message (from on_message event)."""
        message = update  # In Discord, 'update' is a discord.Message

        user_id = str(message.author.id)
        chat_type = "dm" if isinstance(message.channel, discord.DMChannel) else "group"
        if not self.is_user_allowed(user_id):
            response = await self.handle_unknown_user(
                platform="discord",
                user_id=user_id,
                user_display=message.author.display_name,
                chat_id=str(message.channel.id),
                chat_type=chat_type,
                message_text=message.content,
            )
            await message.reply(response)
            return

        chat_id = str(message.channel.id)
        message_text = message.content

        # Session-aware response mode gating
        db = getattr(self.server, "database", None)
        session = await db.get_session_by_bot_link("discord", chat_id) if db else None

        default_mode = "all_messages" if chat_type == "dm" else self.group_mention_mode
        if session and session.metadata:
            bs = session.metadata.get("bot_settings", {})
            response_mode = bs.get("response_mode", default_mode)
        else:
            response_mode = default_mode

        if response_mode == "mention_only":
            # Discord provides parsed mentions - use that for reliable detection
            if message.guild and self._client.user not in message.mentions:
                return  # Silently ignore non-mentions
            # Strip the bot mention from the message
            message_text = message_text.replace(f"<@{self._client.user.id}>", "").strip()
            if not message_text:
                return

        # Find or create linked session
        session = await self.get_or_create_session(
            platform="discord",
            chat_id=chat_id,
            chat_type=chat_type,
            user_display=message.author.display_name,
            user_id=str(message.author.id),
        )

        if not session:
            await message.reply("Internal error: could not create session.")
            return

        # Check initialization status
        if not await self.is_session_initialized(session):
            count = self._init_nudge_sent.get(chat_id, 0)
            if count == 0:
                await message.reply(
                    "Session created! Configure it in the Parachute app "
                    "(set workspace and trust level), then activate it."
                )
            elif count == 1:
                await message.reply(
                    "Still being configured. Please activate in the Parachute app."
                )
            self._init_nudge_sent[chat_id] = count + 1
            return

        self._last_message_time = time.time()

        # Ack reaction — instant feedback before acquiring lock
        ack_sent = False
        if self.ack_emoji and message:
            try:
                await message.add_reaction(self.ack_emoji)
                ack_sent = True
            except Exception as e:
                logger.debug(f"Ack reaction failed (non-critical): {e}")

        # Inject group history for context (wrapped in XML tags to resist prompt injection)
        effective_message = message_text
        if chat_type == "group":
            history = await self._get_group_history(
                message.channel, exclude_id=message.id
            )
            if history:
                effective_message = (
                    f"{history}\n\n"
                    f"{message_text}"
                )

        # Show typing indicator with per-chat lock
        lock = self._get_chat_lock(chat_id)
        async with lock:
            async with message.channel.typing():
                response_text = await self._route_to_chat(
                    session_id=session.id,
                    message=effective_message,
                )

        if not response_text:
            response_text = "No response from agent."

        # Format and send (handle 2000 char limit)
        formatted = claude_to_discord(response_text)
        for chunk in self.split_response(formatted, DISCORD_MAX_MESSAGE_LENGTH):
            await message.reply(chunk)

        # Remove ack reaction after response
        if ack_sent:
            try:
                await message.remove_reaction(self.ack_emoji, self._client.user)
            except Exception:
                pass

    async def _handle_new(self, interaction: Any) -> None:
        """Handle /new slash command - archive current session and start fresh."""
        user_id = str(interaction.user.id)
        if not self.is_user_allowed(user_id):
            await interaction.response.send_message(
                "You don't have access.", ephemeral=True
            )
            return

        await interaction.response.defer()

        chat_id = str(interaction.channel_id)
        db = getattr(self.server, "database", None)
        if db:
            session = await db.get_session_by_bot_link("discord", chat_id)
            if session:
                await db.archive_session(session.id)
                logger.info(f"Archived Discord session {session.id[:8]} for channel {chat_id}")

        await interaction.followup.send(
            "Starting fresh! Previous conversation archived."
        )

    async def _handle_chat(self, interaction: Any, message: str) -> None:
        """Handle /chat slash command."""
        user_id = str(interaction.user.id)
        if not self.is_user_allowed(user_id):
            chat_type = "dm" if interaction.guild is None else "group"
            response = await self.handle_unknown_user(
                platform="discord",
                user_id=user_id,
                user_display=interaction.user.display_name,
                chat_id=str(interaction.channel_id),
                chat_type=chat_type,
                message_text=message,
            )
            await interaction.response.send_message(response, ephemeral=True)
            return

        await interaction.response.defer()

        chat_id = str(interaction.channel_id)
        chat_type = "dm" if interaction.guild is None else "group"

        session = await self.get_or_create_session(
            platform="discord",
            chat_id=chat_id,
            chat_type=chat_type,
            user_display=interaction.user.display_name,
            user_id=str(interaction.user.id),
        )

        if not session:
            await interaction.followup.send("Internal error: could not create session.")
            return

        # Check initialization status
        if not await self.is_session_initialized(session):
            count = self._init_nudge_sent.get(chat_id, 0)
            if count == 0:
                await interaction.followup.send(
                    "Session created! Configure it in the Parachute app "
                    "(set workspace and trust level), then activate it."
                )
            else:
                await interaction.followup.send(
                    "Still being configured. Please activate in the Parachute app."
                )
            self._init_nudge_sent[chat_id] = count + 1
            return

        response_text = await self._route_to_chat(
            session_id=session.id,
            message=message,
        )

        if not response_text:
            response_text = "No response from agent."

        formatted = claude_to_discord(response_text)
        for i, chunk in enumerate(self.split_response(formatted, DISCORD_MAX_MESSAGE_LENGTH)):
            if i == 0:
                await interaction.followup.send(chunk)
            else:
                await interaction.channel.send(chunk)

    async def _handle_journal(self, interaction: Any, entry: str) -> None:
        """Handle /journal slash command."""
        user_id = str(interaction.user.id)
        if not self.is_user_allowed(user_id):
            chat_type = "dm" if interaction.guild is None else "group"
            response = await self.handle_unknown_user(
                platform="discord",
                user_id=user_id,
                user_display=interaction.user.display_name,
                chat_id=str(interaction.channel_id),
                chat_type=chat_type,
            )
            await interaction.response.send_message(response, ephemeral=True)
            return

        await interaction.response.defer()

        try:
            daily_create = getattr(self.server, "create_journal_entry", None)
            if not daily_create:
                await interaction.followup.send("Daily module not available.")
                return

            result = await daily_create(
                content=entry,
                source="discord",
                metadata={"discord_user": interaction.user.display_name},
            )
            title = getattr(result, "title", "Untitled")
            await interaction.followup.send(f"Journal entry saved: {title}")
        except Exception as e:
            logger.error(f"Journal entry failed: {e}")
            await interaction.followup.send("Failed to save journal entry.")

    async def _get_group_history(
        self, channel: Any, exclude_id: int, limit: int = 20
    ) -> str:
        """Fetch recent channel messages for group context injection.

        Intentionally includes messages from ALL channel members (not just
        allowed users) to give the AI full conversation context. Messages
        can only trigger this code path when an allowed user mentions the bot.
        Display names are sanitized to resist prompt injection.
        """
        if isinstance(channel, discord.DMChannel):
            return ""
        try:
            messages = []
            async for msg in channel.history(limit=limit + 5):
                if msg.id == exclude_id or msg.author == self._client.user:
                    continue
                if not msg.content:
                    continue
                messages.append(msg)
                if len(messages) >= limit:
                    break
            if not messages:
                return ""
            messages.reverse()  # Chronological order
            from parachute.connectors.base import GroupHistoryBuffer
            sanitize = GroupHistoryBuffer._sanitize_display_name
            lines = []
            for msg in messages:
                name = sanitize(msg.author.display_name)
                text = msg.content[:500]
                lines.append(f"  {name}: {text}")
            return "<group_context>\n" + "\n".join(lines) + "\n</group_context>"
        except Exception as e:
            logger.warning(f"Failed to fetch channel history: {e}")
            return ""

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
                source="discord",
            ):
                event_count += 1
                event_type = event.get("type", "") if isinstance(event, dict) else getattr(event, "type", "")
                if event_type == "text":
                    # Use 'content' (full accumulated text) — more resilient than
                    # accumulating 'delta' fragments, and consistent with Telegram streaming
                    content = event.get("content", "") if isinstance(event, dict) else getattr(event, "content", "")
                    if content:
                        response_text = content
                elif event_type == "error":
                    error_msg = event.get("error", "") if isinstance(event, dict) else getattr(event, "error", "")
                    logger.error(f"Orchestrator error event: {error_msg}")
            logger.info(f"Discord orchestration: {event_count} events, {len(response_text)} chars response")
        except Exception as e:
            logger.error(f"Chat orchestration failed: {e}", exc_info=True)
            return "Something went wrong. Please try again later."

        return response_text

    async def send_message(self, chat_id: str, text: str) -> None:
        """Send a message to a Discord channel."""
        if self._client:
            channel = self._client.get_channel(int(chat_id))
            if channel:
                await channel.send(text)

    async def send_approval_message(self, chat_id: str) -> None:
        """Send approval confirmation to user via Discord."""
        if self._client:
            channel = self._client.get_channel(int(chat_id))
            if channel:
                await channel.send("You've been approved! Send me a message to start chatting.")

    async def send_denial_message(self, chat_id: str) -> None:
        """Send denial notification to user via Discord."""
        try:
            if self._client:
                channel = self._client.get_channel(int(chat_id))
                if channel:
                    await channel.send("Your request was not approved.")
        except Exception as e:
            logger.warning(f"Failed to send denial message to {chat_id}: {e}")
