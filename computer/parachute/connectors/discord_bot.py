"""
Discord bot connector.

Bridges Discord channels to Parachute Chat sessions.
Uses discord.py library (optional dependency).

Install: pip install 'discord.py>=2.3'
"""

import asyncio
import logging
from typing import Any, Optional

from parachute.connectors.base import BotConnector
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
        allowed_guilds: list[str] | None = None,
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
        self.allowed_guilds = allowed_guilds or []
        self._client: Optional[Any] = None
        self._tree: Optional[Any] = None

    async def start(self) -> None:
        """Start Discord bot."""
        if not DISCORD_AVAILABLE:
            raise RuntimeError(
                "discord.py not installed. "
                "Install with: pip install 'discord.py>=2.3'"
            )

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
            # Sync commands to guilds
            for guild_id in self.allowed_guilds:
                try:
                    guild = discord.Object(id=int(guild_id))
                    self._tree.copy_global_to(guild=guild)
                    await self._tree.sync(guild=guild)
                    logger.info(f"Synced commands to guild {guild_id}")
                except Exception as e:
                    logger.error(f"Failed to sync commands to guild {guild_id}: {e}")
            self._running = True

        @self._client.event
        async def on_message(message: discord.Message):
            if message.author == self._client.user:
                return
            # Only handle DMs or allowed guilds
            if message.guild and str(message.guild.id) not in self.allowed_guilds:
                return
            await self.on_text_message(message, None)

        # Start bot (this blocks, so run in background)
        asyncio.create_task(self._run_client())

    async def _run_client(self) -> None:
        """Run the Discord client."""
        try:
            await self._client.start(self.bot_token)
        except asyncio.CancelledError:
            pass
        except Exception as e:
            logger.error(f"Discord client error: {e}")
            self._running = False

    async def stop(self) -> None:
        """Stop Discord bot."""
        self._running = False
        if self._client:
            await self._client.close()
        logger.info("Discord connector stopped")

    async def on_text_message(self, update: Any, context: Any) -> None:
        """Handle incoming text message (from on_message event)."""
        message = update  # In Discord, 'update' is a discord.Message

        user_id = str(message.author.id)
        if not self.is_user_allowed(user_id):
            response = await self.handle_unknown_user(
                platform="discord",
                user_id=user_id,
                user_display=message.author.display_name,
                chat_id=str(message.channel.id),
            )
            await message.reply(response)
            return

        chat_id = str(message.channel.id)
        chat_type = "dm" if isinstance(message.channel, discord.DMChannel) else "group"
        message_text = message.content

        # Group mention gating: only respond to @mentions in guild channels
        if message.guild and self.group_mention_mode == "mention_only":
            if self._client.user not in message.mentions:
                return  # Silently ignore non-mentions in groups
            # Strip the bot mention from the message
            message_text = message_text.replace(f"<@{self._client.user.id}>", "").strip()
            if not message_text:
                return  # Nothing left after stripping mention

        # Find or create linked session
        session = await self.get_or_create_session(
            platform="discord",
            chat_id=chat_id,
            chat_type=chat_type,
            user_display=message.author.display_name,
        )

        if not session:
            await message.reply("Internal error: could not create session.")
            return

        # Show typing indicator with per-session lock
        lock = self._get_session_lock(session.id)
        async with lock:
            async with message.channel.typing():
                response_text = await self._route_to_chat(
                    session_id=session.id,
                    message=message_text,
                )

        if not response_text:
            response_text = "No response from agent."

        # Format and send (handle 2000 char limit)
        formatted = claude_to_discord(response_text)
        for chunk in self.split_response(formatted, DISCORD_MAX_MESSAGE_LENGTH):
            await message.reply(chunk)

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
            response = await self.handle_unknown_user(
                platform="discord",
                user_id=user_id,
                user_display=interaction.user.display_name,
                chat_id=str(interaction.channel_id),
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
        )

        if not session:
            await interaction.followup.send("Internal error: could not create session.")
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
            response = await self.handle_unknown_user(
                platform="discord",
                user_id=user_id,
                user_display=interaction.user.display_name,
                chat_id=str(interaction.channel_id),
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
                    delta = event.get("delta", "") if isinstance(event, dict) else getattr(event, "delta", "")
                    response_text += delta
                elif event_type == "error":
                    error_msg = event.get("error", "") if isinstance(event, dict) else getattr(event, "error", "")
                    logger.error(f"Orchestrator error event: {error_msg}")
            logger.info(f"Discord orchestration: {event_count} events, {len(response_text)} chars response")
        except Exception as e:
            logger.error(f"Chat orchestration failed: {e}", exc_info=True)
            return "Something went wrong. Please try again later."

        return response_text

    async def send_approval_message(self, chat_id: str) -> None:
        """Send approval confirmation to user via Discord."""
        if self._client:
            channel = self._client.get_channel(int(chat_id))
            if channel:
                await channel.send("You've been approved! Send me a message to start chatting.")
