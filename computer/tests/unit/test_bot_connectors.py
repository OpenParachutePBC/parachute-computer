"""
Tests for bot connectors: base class, message formatter, config loading, resilience.
"""

import asyncio
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from parachute.connectors.base import BotConnector, ConnectorState
from parachute.connectors.config import (
    BotsConfig,
    DiscordConfig,
    MatrixConfig,
    TelegramConfig,
    load_bots_config,
)
from parachute.connectors.message_formatter import (
    claude_to_discord,
    claude_to_matrix,
    claude_to_plain,
    claude_to_telegram,
)


# ---------------------------------------------------------------------------
# Message splitting tests
# ---------------------------------------------------------------------------


class TestSplitResponse:
    def test_empty_string(self):
        assert BotConnector.split_response("", 100) == []

    def test_short_message(self):
        assert BotConnector.split_response("Hello", 100) == ["Hello"]

    def test_exact_limit(self):
        text = "A" * 100
        assert BotConnector.split_response(text, 100) == [text]

    def test_splits_at_paragraphs(self):
        text = "Para 1\n\nPara 2\n\nPara 3"
        chunks = BotConnector.split_response(text, 15)
        assert len(chunks) >= 2
        # All content should be preserved
        joined = "\n\n".join(chunks)
        assert "Para 1" in joined
        assert "Para 2" in joined
        assert "Para 3" in joined

    def test_long_single_paragraph_force_splits(self):
        text = "A" * 200
        chunks = BotConnector.split_response(text, 50)
        assert len(chunks) >= 4
        assert all(len(c) <= 50 for c in chunks)

    def test_preserves_content(self):
        text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        chunks = BotConnector.split_response(text, 30)
        combined = " ".join(chunks)
        assert "First" in combined
        assert "Second" in combined
        assert "Third" in combined

    def test_telegram_limit(self):
        # Simulate a response near Telegram's 4096 limit
        paragraphs = [f"Paragraph {i}: " + "x" * 100 for i in range(50)]
        text = "\n\n".join(paragraphs)
        chunks = BotConnector.split_response(text, 4096)
        assert all(len(c) <= 4096 for c in chunks)

    def test_discord_limit(self):
        paragraphs = [f"Paragraph {i}: " + "x" * 100 for i in range(30)]
        text = "\n\n".join(paragraphs)
        chunks = BotConnector.split_response(text, 2000)
        assert all(len(c) <= 2000 for c in chunks)


# ---------------------------------------------------------------------------
# Message formatter tests
# ---------------------------------------------------------------------------


class TestClaudeToPlain:
    def test_empty(self):
        assert claude_to_plain("") == ""

    def test_bold(self):
        assert claude_to_plain("**Bold text**") == "Bold text"

    def test_italic(self):
        assert claude_to_plain("*italic*") == "italic"

    def test_code(self):
        assert claude_to_plain("`code`") == "code"

    def test_code_block(self):
        result = claude_to_plain("```python\nprint('hi')\n```")
        assert "print('hi')" in result
        assert "```" not in result

    def test_links(self):
        assert claude_to_plain("[Google](https://google.com)") == "Google"

    def test_headers(self):
        assert claude_to_plain("## Header") == "Header"

    def test_strikethrough(self):
        assert claude_to_plain("~~removed~~") == "removed"

    def test_mixed(self):
        text = "**Bold** and *italic* with `code` and [link](url)"
        result = claude_to_plain(text)
        assert "Bold" in result
        assert "italic" in result
        assert "code" in result
        assert "link" in result
        assert "**" not in result


class TestClaudeToDiscord:
    def test_empty(self):
        assert claude_to_discord("") == ""

    def test_preserves_standard_markdown(self):
        text = "**bold** and *italic* and `code`"
        assert claude_to_discord(text) == text

    def test_strips_html_tags(self):
        text = "Hello<br>World<details><summary>More</summary></details>"
        result = claude_to_discord(text)
        assert "<br>" not in result
        assert "<details>" not in result


class TestClaudeToTelegram:
    def test_empty(self):
        assert claude_to_telegram("") == ""

    def test_preserves_code_blocks(self):
        text = "```python\nprint('hi')\n```"
        result = claude_to_telegram(text)
        assert "```python" in result

    def test_converts_strikethrough(self):
        text = "~~removed~~"
        result = claude_to_telegram(text)
        assert "~removed~" in result


# ---------------------------------------------------------------------------
# Bot config tests
# ---------------------------------------------------------------------------


class TestBotsConfig:
    @pytest.mark.parametrize("config_class,field,input_value,expected", [
        # Telegram normalization tests
        (TelegramConfig, "dm_trust_level", "full", "direct"),
        (TelegramConfig, "dm_trust_level", "vault", "direct"),
        (TelegramConfig, "dm_trust_level", "untrusted", "sandboxed"),
        (TelegramConfig, "dm_trust_level", "direct", "direct"),  # Canonical passthrough
        (TelegramConfig, "dm_trust_level", "sandboxed", "sandboxed"),  # Canonical
        (TelegramConfig, "group_trust_level", "full", "direct"),
        (TelegramConfig, "group_trust_level", "untrusted", "sandboxed"),
        # Discord normalization tests
        (DiscordConfig, "dm_trust_level", "full", "direct"),
        (DiscordConfig, "dm_trust_level", "vault", "direct"),
        (DiscordConfig, "dm_trust_level", "sandboxed", "sandboxed"),
        (DiscordConfig, "group_trust_level", "untrusted", "sandboxed"),
        # Matrix normalization tests
        (MatrixConfig, "dm_trust_level", "full", "direct"),
        (MatrixConfig, "dm_trust_level", "vault", "direct"),
        (MatrixConfig, "dm_trust_level", "trusted", "direct"),
        (MatrixConfig, "dm_trust_level", "direct", "direct"),  # Canonical
        (MatrixConfig, "group_trust_level", "untrusted", "sandboxed"),
        (MatrixConfig, "group_trust_level", "sandboxed", "sandboxed"),  # Canonical
    ])
    def test_trust_level_normalization_across_platforms(
        self, config_class, field, input_value, expected
    ):
        """All platform configs normalize trust levels consistently via Pydantic validators.

        This parametrized test consolidates trust level normalization testing across
        all bot platforms (Telegram, Discord, Matrix) to ensure consistent behavior.
        """
        # Create config with the input value
        config = config_class(**{field: input_value})
        actual = getattr(config, field)
        assert actual == expected, \
            f"{config_class.__name__}.{field}: Legacy {input_value!r} should normalize to {expected!r}, got {actual!r}"

    def test_default_config(self):
        config = BotsConfig()
        assert not config.telegram.enabled
        assert not config.discord.enabled
        # Default normalization is now tested in parametrized test above
        assert config.telegram.dm_trust_level == "sandboxed"
        assert config.telegram.group_trust_level == "sandboxed"

    def test_telegram_config(self):
        config = TelegramConfig(
            enabled=True,
            bot_token="test-token",
            allowed_users=[123, 456],
        )
        assert config.enabled
        assert config.bot_token == "test-token"
        assert len(config.allowed_users) == 2

    def test_discord_config(self):
        """Test Discord configuration with user allowlist."""
        config = DiscordConfig(
            enabled=True,
            bot_token="test-token",
            allowed_users=["discord_user_1", "discord_user_2"],
            group_mention_mode="all_messages",
        )
        assert config.enabled
        assert config.bot_token == "test-token"
        assert len(config.allowed_users) == 2
        assert config.group_mention_mode == "all_messages"
        # Normalization testing is handled by test_trust_level_normalization_across_platforms

    def test_full_config_parsing(self):
        config = BotsConfig(**{
            "telegram": {
                "enabled": True,
                "bot_token": "tg-token",
                "allowed_users": [111],
                "group_trust_level": "sandboxed",
            },
            "discord": {
                "enabled": True,
                "bot_token": "dc-token",
                "allowed_guilds": ["g1"],
            },
        })
        assert config.telegram.enabled
        assert config.discord.enabled
        # Normalization testing is handled by test_trust_level_normalization_across_platforms

    def test_load_from_missing_file(self, tmp_path):
        config = load_bots_config(tmp_path)
        assert not config.telegram.enabled
        assert not config.discord.enabled

    def test_load_from_yaml(self, tmp_path):
        parachute_dir = tmp_path / ".parachute"
        parachute_dir.mkdir()
        (parachute_dir / "bots.yaml").write_text(
            "telegram:\n"
            "  enabled: true\n"
            "  bot_token: 'test-token-123'\n"
            "  allowed_users:\n"
            "    - 12345\n"
            "  dm_trust_level: vault\n"
            "  group_trust_level: sandboxed\n"
        )
        config = load_bots_config(tmp_path)
        assert config.telegram.enabled
        assert config.telegram.bot_token == "test-token-123"
        assert 12345 in config.telegram.allowed_users

    def test_load_from_invalid_yaml(self, tmp_path):
        parachute_dir = tmp_path / ".parachute"
        parachute_dir.mkdir()
        (parachute_dir / "bots.yaml").write_text("{{invalid yaml")
        config = load_bots_config(tmp_path)
        # Should return defaults on error
        assert not config.telegram.enabled


# ---------------------------------------------------------------------------
# Base connector tests
# ---------------------------------------------------------------------------


class TestBotConnectorBase:
    def test_is_user_allowed_int(self, minimal_bot_connector):
        connector = minimal_bot_connector(
            bot_token="test",
            server=None,
            allowed_users=[123, 456],
        )
        assert connector.is_user_allowed(123)
        assert connector.is_user_allowed(456)
        assert not connector.is_user_allowed(789)

    def test_is_user_allowed_string(self, minimal_bot_connector):
        connector = minimal_bot_connector(
            bot_token="test",
            server=None,
            allowed_users=["123", "456"],
        )
        assert connector.is_user_allowed("123")
        assert connector.is_user_allowed(123)  # int matches string

    @pytest.mark.asyncio
    async def test_get_trust_level(self, minimal_bot_connector):
        """Test trust level retrieval for different chat types."""
        connector = minimal_bot_connector(
            bot_token="test",
            server=None,
            allowed_users=[],
            dm_trust_level="direct",  # Use normalized value
            group_trust_level="sandboxed",
        )

        # Verify no leaked state
        assert connector._trust_overrides == {}, "Should start with empty trust overrides"

        # Test both chat types with correct async signature
        dm_level = await connector.get_trust_level("dm")
        assert dm_level == "direct", f"Expected 'direct' for DM, got {dm_level!r}"

        group_level = await connector.get_trust_level("group")
        assert group_level == "sandboxed", f"Expected 'sandboxed' for group, got {group_level!r}"

    def test_status_enriched_fields(self, minimal_bot_connector):
        connector = minimal_bot_connector(
            bot_token="test",
            server=None,
            allowed_users=[1, 2, 3],
        )
        status = connector.status
        assert status["platform"] == "test"
        assert status["status"] == "stopped"
        assert status["running"] is False
        assert status["failure_count"] == 0
        assert status["last_error"] is None
        assert status["last_error_time"] is None
        assert status["uptime"] is None
        assert status["last_message_time"] is None
        assert status["reconnect_attempts"] == 0
        assert status["allowed_users_count"] == 3


# ---------------------------------------------------------------------------
# Connector import tests (verify graceful degradation)
# ---------------------------------------------------------------------------


class TestConnectorImports:
    def test_telegram_connector_importable(self):
        from parachute.connectors.telegram import TelegramConnector, TELEGRAM_AVAILABLE
        assert TelegramConnector.platform == "telegram"

    def test_discord_connector_importable(self):
        from parachute.connectors.discord_bot import DiscordConnector, DISCORD_AVAILABLE
        assert DiscordConnector.platform == "discord"

    def test_api_router_importable(self):
        """Verify bots router is importable with correct configuration."""
        from parachute.api.bots import router

        assert router is not None, "Router should be importable"
        # Router's own prefix (not the full stacked path /api/bots)
        assert router.prefix == "/bots", "Router local prefix should be '/bots'"
        assert "bots" in router.tags, "Router should have 'bots' tag"


# ---------------------------------------------------------------------------
# Resilience / reconnection tests
# ---------------------------------------------------------------------------


def _make_test_connector(**kwargs):
    """Create a concrete BotConnector subclass for testing."""

    class _TestConnector(BotConnector):
        platform = "test"
        _run_loop_side_effect = None

        async def start(self):
            self._stop_event.clear()
            self._task = asyncio.create_task(self._run_with_reconnect())

        async def stop(self):
            if self._status == ConnectorState.STOPPED:
                return
            self._stop_event.set()
            if self._task and not self._task.done():
                self._task.cancel()
                try:
                    await asyncio.wait_for(self._task, timeout=5.0)
                except (asyncio.TimeoutError, asyncio.CancelledError):
                    pass
            self._task = None
            self._set_status(ConnectorState.STOPPED)

        async def on_text_message(self, update, context):
            pass

        async def _run_loop(self):
            if self._run_loop_side_effect:
                effect = self._run_loop_side_effect
                if callable(effect):
                    await effect()
                elif isinstance(effect, Exception):
                    raise type(effect)(*effect.args)
                else:
                    raise effect

    defaults = dict(bot_token="test-token", server=SimpleNamespace(), allowed_users=[])
    defaults.update(kwargs)
    return _TestConnector(**defaults)


class TestConnectorResilience:
    """Tests for reconnection, health tracking, and lifecycle."""

    @pytest.mark.asyncio
    async def test_health_status_fields_at_init(self):
        c = _make_test_connector()
        assert c._status == ConnectorState.STOPPED
        assert c._failure_count == 0
        assert c._last_error is None
        assert c._started_at is None
        assert c._reconnect_attempts == 0

    @pytest.mark.asyncio
    async def test_reconnection_success(self):
        """_run_loop fails twice then succeeds. Verify recovery."""
        c = _make_test_connector()
        call_count = 0

        async def flaky_loop():
            nonlocal call_count
            call_count += 1
            if call_count <= 2:
                raise ConnectionError("network down")
            # Success — simulate clean run then exit
            c._stop_event.set()

        c._run_loop_side_effect = flaky_loop
        await c.start()
        await asyncio.wait_for(c._task, timeout=10)

        assert call_count == 3
        assert c._failure_count == 2
        assert c._reconnect_attempts == 0  # Reset on success

    @pytest.mark.asyncio
    async def test_reconnection_exhaustion(self):
        """_run_loop always fails. Verify connector reaches FAILED after max retries."""
        c = _make_test_connector()
        c._run_loop_side_effect = ConnectionError("always fails")

        # Zero out backoff delays for fast test execution
        with patch("parachute.connectors.base.random.uniform", return_value=0):
            await c.start()
            await asyncio.wait_for(c._task, timeout=10)

        assert c._status == ConnectorState.FAILED
        assert c._failure_count == 10
        assert "ConnectionError" in c._last_error

    @pytest.mark.asyncio
    async def test_stop_during_backoff(self):
        """Calling stop() during backoff sleep should return promptly."""
        c = _make_test_connector()
        c._run_loop_side_effect = ConnectionError("fail once")

        await c.start()
        # Give it time to enter backoff
        await asyncio.sleep(0.1)
        assert c._status in (ConnectorState.RECONNECTING, ConnectorState.RUNNING)

        start_time = time.monotonic()
        await c.stop()
        elapsed = time.monotonic() - start_time

        assert c._status == ConnectorState.STOPPED
        assert elapsed < 5.0  # Should be nearly instant, not waiting for full backoff

    @pytest.mark.asyncio
    async def test_stop_idempotent(self):
        """Calling stop() on a stopped connector is safe."""
        c = _make_test_connector()
        assert c._status == ConnectorState.STOPPED
        await c.stop()  # Should not raise
        assert c._status == ConnectorState.STOPPED

    @pytest.mark.asyncio
    async def test_fatal_auth_error_skips_retry(self):
        """Auth errors should skip retry loop and fail immediately."""
        c = _make_test_connector()

        class InvalidToken(Exception):
            pass

        c._run_loop_side_effect = InvalidToken("bad token")
        await c.start()
        await asyncio.wait_for(c._task, timeout=5)

        assert c._status == ConnectorState.FAILED
        assert c._failure_count == 1  # Only one attempt, no retries

    @pytest.mark.asyncio
    async def test_state_transition_validation(self):
        """Invalid transitions raise RuntimeError; valid transitions succeed."""
        c = _make_test_connector()

        # stopped -> reconnecting is invalid — must raise
        with pytest.raises(RuntimeError, match="Invalid connector state transition"):
            c._set_status(ConnectorState.RECONNECTING)
        assert c._status == ConnectorState.STOPPED  # Unchanged

        # stopped -> running is valid
        c._set_status(ConnectorState.RUNNING)
        assert c._status == ConnectorState.RUNNING

        # running -> reconnecting is valid
        c._set_status(ConnectorState.RECONNECTING)
        assert c._status == ConnectorState.RECONNECTING

    @pytest.mark.asyncio
    async def test_hook_fires_on_failure(self):
        """bot.connector.down hook should fire when retries exhausted."""
        mock_hook_runner = MagicMock()
        mock_hook_runner.fire = AsyncMock()
        server = SimpleNamespace(hook_runner=mock_hook_runner)
        c = _make_test_connector(server=server)
        c._run_loop_side_effect = ConnectionError("fail")

        with patch("parachute.connectors.base.random.uniform", return_value=0):
            await c.start()
            await asyncio.wait_for(c._task, timeout=10)

        # Find the BOT_CONNECTOR_DOWN call
        from parachute.core.hooks.events import HookEvent
        down_calls = [
            call for call in mock_hook_runner.fire.call_args_list
            if call[0][0] == HookEvent.BOT_CONNECTOR_DOWN
        ]
        assert len(down_calls) == 1
        payload = down_calls[0][0][1]
        assert payload["platform"] == "test"
        assert "error" in payload

    @pytest.mark.asyncio
    async def test_hook_fires_on_reconnection(self):
        """bot.connector.reconnected hook should fire on successful recovery."""
        mock_hook_runner = MagicMock()
        mock_hook_runner.fire = AsyncMock()
        server = SimpleNamespace(hook_runner=mock_hook_runner)
        c = _make_test_connector(server=server)
        call_count = 0

        async def flaky_loop():
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise ConnectionError("network blip")
            c._stop_event.set()

        c._run_loop_side_effect = flaky_loop
        await c.start()
        await asyncio.wait_for(c._task, timeout=10)

        from parachute.core.hooks.events import HookEvent
        reconnect_calls = [
            call for call in mock_hook_runner.fire.call_args_list
            if call[0][0] == HookEvent.BOT_CONNECTOR_RECONNECTED
        ]
        assert len(reconnect_calls) == 1
        payload = reconnect_calls[0][0][1]
        assert payload["platform"] == "test"
        assert payload["attempts"] == 1

    @pytest.mark.asyncio
    async def test_enriched_status_after_failures(self):
        """Status property should reflect health data after failures and recovery."""
        c = _make_test_connector()
        call_count = 0

        async def flaky_loop():
            nonlocal call_count
            call_count += 1
            if call_count <= 2:
                raise ConnectionError("fail")
            c._stop_event.set()

        c._run_loop_side_effect = flaky_loop
        await c.start()
        await asyncio.wait_for(c._task, timeout=10)

        status = c.status
        assert status["failure_count"] == 2
        assert status["last_error"] is not None
        assert "ConnectionError" in status["last_error"]
        assert status["last_error_time"] is not None

    def test_error_sanitization(self):
        """Sensitive data should be stripped from error messages."""
        c = _make_test_connector()
        exc = Exception("bot token=abc123456789012345678901 caused error")
        sanitized = c._sanitize_error(exc)
        assert "abc123456789012345678901" not in sanitized
        assert "REDACTED" in sanitized

    def test_mark_failed(self):
        """mark_failed() should set FAILED state from RUNNING."""
        c = _make_test_connector()
        c._set_status(ConnectorState.RUNNING)
        c.mark_failed(RuntimeError("boom"))
        assert c._status == ConnectorState.FAILED
        assert "RuntimeError" in c._last_error
        assert c._last_error_time is not None


# ---------------------------------------------------------------------------
# Matrix config tests
# ---------------------------------------------------------------------------


class TestMatrixConfig:
    def test_default_config(self):
        config = MatrixConfig()
        assert not config.enabled
        assert config.homeserver_url == ""
        assert config.user_id == ""
        assert config.access_token == ""
        assert config.device_id == "PARACHUTE01"
        assert config.allowed_rooms == []
        # Normalization testing is handled by TestBotsConfig.test_trust_level_normalization_across_platforms
        assert config.dm_trust_level == "sandboxed"
        assert config.group_trust_level == "sandboxed"
        assert config.group_mention_mode == "mention_only"
        assert config.ack_emoji == "👀"

    def test_matrix_config_parsing(self):
        config = MatrixConfig(
            enabled=True,
            homeserver_url="https://matrix.example.org",
            user_id="@bot:example.org",
            access_token="syt_test_token",
            device_id="TEST01",
            allowed_rooms=["!abc:example.org", "#room:example.org"],
        )
        assert config.enabled
        assert config.homeserver_url == "https://matrix.example.org"
        assert config.user_id == "@bot:example.org"
        assert len(config.allowed_rooms) == 2

    def test_bots_config_includes_matrix(self):
        config = BotsConfig()
        assert hasattr(config, "matrix")
        assert not config.matrix.enabled

    def test_full_config_with_matrix(self):
        config = BotsConfig(**{
            "matrix": {
                "enabled": True,
                "homeserver_url": "https://matrix.test.org",
                "user_id": "@parachute:test.org",
                "access_token": "syt_test",
                "allowed_rooms": ["!room1:test.org"],
                "dm_trust_level": "untrusted",
                "group_trust_level": "untrusted",
            }
        })
        assert config.matrix.enabled
        assert config.matrix.homeserver_url == "https://matrix.test.org"
        assert len(config.matrix.allowed_rooms) == 1

    def test_load_matrix_from_yaml(self, tmp_path):
        parachute_dir = tmp_path / ".parachute"
        parachute_dir.mkdir()
        (parachute_dir / "bots.yaml").write_text(
            "matrix:\n"
            "  enabled: true\n"
            "  homeserver_url: 'https://matrix.example.org'\n"
            "  user_id: '@bot:example.org'\n"
            "  access_token: 'syt_test'\n"
            "  device_id: 'BOT01'\n"
            "  allowed_rooms:\n"
            "    - '!abc:example.org'\n"
        )
        config = load_bots_config(tmp_path)
        assert config.matrix.enabled
        assert config.matrix.homeserver_url == "https://matrix.example.org"
        assert config.matrix.device_id == "BOT01"
        assert "!abc:example.org" in config.matrix.allowed_rooms


# ---------------------------------------------------------------------------
# Matrix message formatter tests
# ---------------------------------------------------------------------------


class TestClaudeToMatrix:
    def test_empty(self):
        plain, html = claude_to_matrix("")
        assert plain == ""
        assert html == ""

    def test_bold(self):
        plain, html = claude_to_matrix("**Bold text**")
        assert "Bold text" in plain
        assert "<b>Bold text</b>" in html

    def test_italic(self):
        plain, html = claude_to_matrix("*italic*")
        assert "italic" in plain
        assert "<i>italic</i>" in html

    def test_inline_code(self):
        plain, html = claude_to_matrix("Use `code` here")
        assert "code" in plain
        assert "<code>code</code>" in html

    def test_code_block(self):
        plain, html = claude_to_matrix("```python\nprint('hi')\n```")
        assert "print('hi')" in plain
        assert "<pre><code" in html
        assert "print(&#x27;hi&#x27;)" in html or "print('hi')" in html

    def test_link(self):
        plain, html = claude_to_matrix("[Google](https://google.com)")
        assert "Google" in plain
        assert '<a href="https://google.com">Google</a>' in html

    def test_heading(self):
        plain, html = claude_to_matrix("## My Heading")
        assert "My Heading" in plain
        assert "<h2>" in html

    def test_blockquote(self):
        plain, html = claude_to_matrix("> quoted text")
        assert "quoted text" in plain
        assert "<blockquote>" in html

    def test_unordered_list(self):
        plain, html = claude_to_matrix("- item one\n- item two")
        assert "item one" in plain
        assert "<ul>" in html
        assert "<li>" in html

    def test_ordered_list(self):
        plain, html = claude_to_matrix("1. first\n2. second")
        assert "first" in plain
        assert "<ol>" in html
        assert "<li>" in html

    def test_plain_text_is_stripped(self):
        plain, html = claude_to_matrix("**bold** and *italic*")
        assert "**" not in plain
        assert "*" not in plain

    def test_html_escaping(self):
        plain, html = claude_to_matrix("Use <script> and & symbols")
        assert "&lt;script&gt;" in html
        assert "&amp;" in html

    def test_returns_tuple(self):
        result = claude_to_matrix("hello")
        assert isinstance(result, tuple)
        assert len(result) == 2


# ---------------------------------------------------------------------------
# Matrix message splitting tests
# ---------------------------------------------------------------------------


class TestMatrixMessageSplit:
    def test_split_at_25k_boundary(self):
        text = "A" * 30000
        chunks = BotConnector.split_response(text, 25000)
        assert len(chunks) >= 2
        assert all(len(c) <= 25000 for c in chunks)

    def test_matrix_limit_with_paragraphs(self):
        paragraphs = [f"Paragraph {i}: " + "x" * 500 for i in range(60)]
        text = "\n\n".join(paragraphs)
        chunks = BotConnector.split_response(text, 25000)
        assert all(len(c) <= 25000 for c in chunks)
        # All content preserved
        combined = "\n\n".join(chunks)
        assert "Paragraph 0" in combined
        assert "Paragraph 59" in combined


# ---------------------------------------------------------------------------
# Matrix connector import test
# ---------------------------------------------------------------------------


class TestMatrixConnectorImport:
    def test_matrix_connector_importable(self):
        from parachute.connectors.matrix_bot import MatrixConnector, MATRIX_AVAILABLE
        assert MatrixConnector.platform == "matrix"

    def test_matrix_available_flag_exists(self):
        from parachute.connectors.matrix_bot import MATRIX_AVAILABLE
        # Should be a boolean regardless of whether matrix-nio is installed
        assert isinstance(MATRIX_AVAILABLE, bool)


# ---------------------------------------------------------------------------
# Bridge detection pattern tests
# ---------------------------------------------------------------------------


class TestBridgePatterns:
    def test_meta_ghost_pattern(self):
        from parachute.connectors.matrix_bot import BRIDGE_GHOST_PATTERNS
        assert any(p.match("@meta_100054638951038:localhost") for p in BRIDGE_GHOST_PATTERNS)

    def test_telegram_ghost_pattern(self):
        from parachute.connectors.matrix_bot import BRIDGE_GHOST_PATTERNS
        assert any(p.match("@telegram_123456:example.org") for p in BRIDGE_GHOST_PATTERNS)

    def test_discord_ghost_pattern(self):
        from parachute.connectors.matrix_bot import BRIDGE_GHOST_PATTERNS
        assert any(p.match("@discord_987654321:matrix.org") for p in BRIDGE_GHOST_PATTERNS)

    def test_signal_ghost_pattern(self):
        from parachute.connectors.matrix_bot import BRIDGE_GHOST_PATTERNS
        assert any(p.match("@signal_12345:localhost") for p in BRIDGE_GHOST_PATTERNS)

    def test_whatsapp_ghost_pattern(self):
        from parachute.connectors.matrix_bot import BRIDGE_GHOST_PATTERNS
        assert any(p.match("@whatsapp_15551234567:localhost") for p in BRIDGE_GHOST_PATTERNS)

    def test_non_ghost_user_not_matched(self):
        from parachute.connectors.matrix_bot import BRIDGE_GHOST_PATTERNS
        assert not any(p.match("@alice:example.org") for p in BRIDGE_GHOST_PATTERNS)
        assert not any(p.match("@parachute:localhost") for p in BRIDGE_GHOST_PATTERNS)

    def test_bridge_bot_pattern(self):
        from parachute.connectors.matrix_bot import BRIDGE_BOT_PATTERNS
        assert any(p.match("@metabot:localhost") for p in BRIDGE_BOT_PATTERNS)
        assert any(p.match("@telegrambot:example.org") for p in BRIDGE_BOT_PATTERNS)
        assert any(p.match("@discordbot:matrix.org") for p in BRIDGE_BOT_PATTERNS)

    def test_non_bot_not_matched(self):
        from parachute.connectors.matrix_bot import BRIDGE_BOT_PATTERNS
        assert not any(p.match("@alice:example.org") for p in BRIDGE_BOT_PATTERNS)
        assert not any(p.match("@parachute:localhost") for p in BRIDGE_BOT_PATTERNS)


# ---------------------------------------------------------------------------
# Bridge detection method tests
# ---------------------------------------------------------------------------


def _make_matrix_connector(**kwargs):
    """Create a MatrixConnector for testing with mocked client."""
    from parachute.connectors.matrix_bot import MatrixConnector

    defaults = dict(
        homeserver_url="http://localhost:6167",
        user_id="@parachute:localhost",
        access_token="test-token",
        device_id="TEST01",
        server=SimpleNamespace(database=None),
        allowed_users=[],
        allowed_rooms=[],
    )
    defaults.update(kwargs)
    return MatrixConnector(**defaults)


class TestDetectBridgeRoom:
    @pytest.mark.asyncio
    async def test_detects_meta_bridge_dm(self):
        """Single meta ghost user = bridged DM."""
        connector = _make_matrix_connector()

        mock_response = SimpleNamespace(
            members={
                "@parachute:localhost": {},
                "@metabot:localhost": {},
                "@meta_100054638951038:localhost": {},
            }
        )
        connector._client = AsyncMock()
        connector._client.joined_members = AsyncMock(return_value=mock_response)

        result = await connector._detect_bridge_room("!room:localhost")
        assert result is not None
        assert result["bridge_type"] == "meta"
        assert result["remote_chat_type"] == "dm"
        assert len(result["ghost_users"]) == 1

    @pytest.mark.asyncio
    async def test_detects_telegram_bridge_group(self):
        """Multiple telegram ghost users = bridged group."""
        connector = _make_matrix_connector()

        mock_response = SimpleNamespace(
            members={
                "@parachute:localhost": {},
                "@telegrambot:localhost": {},
                "@telegram_111:localhost": {},
                "@telegram_222:localhost": {},
                "@telegram_333:localhost": {},
            }
        )
        connector._client = AsyncMock()
        connector._client.joined_members = AsyncMock(return_value=mock_response)

        result = await connector._detect_bridge_room("!room:localhost")
        assert result is not None
        assert result["bridge_type"] == "telegram"
        assert result["remote_chat_type"] == "group"
        assert len(result["ghost_users"]) == 3

    @pytest.mark.asyncio
    async def test_non_bridged_room_returns_none(self):
        """Room with only real users returns None."""
        connector = _make_matrix_connector()

        mock_response = SimpleNamespace(
            members={
                "@parachute:localhost": {},
                "@alice:localhost": {},
                "@bob:localhost": {},
            }
        )
        connector._client = AsyncMock()
        connector._client.joined_members = AsyncMock(return_value=mock_response)

        result = await connector._detect_bridge_room("!room:localhost")
        assert result is None

    @pytest.mark.asyncio
    async def test_no_client_returns_none(self):
        """No client returns None."""
        connector = _make_matrix_connector()
        connector._client = None

        result = await connector._detect_bridge_room("!room:localhost")
        assert result is None

    @pytest.mark.asyncio
    async def test_api_error_returns_none(self):
        """API error returns None gracefully."""
        connector = _make_matrix_connector()
        connector._client = AsyncMock()
        connector._client.joined_members = AsyncMock(side_effect=Exception("network error"))

        result = await connector._detect_bridge_room("!room:localhost")
        assert result is None

    @pytest.mark.asyncio
    async def test_detects_bridge_bots(self):
        """Bridge bots are identified separately from ghost users."""
        connector = _make_matrix_connector()

        mock_response = SimpleNamespace(
            members={
                "@parachute:localhost": {},
                "@metabot:localhost": {},
                "@meta_123:localhost": {},
            }
        )
        connector._client = AsyncMock()
        connector._client.joined_members = AsyncMock(return_value=mock_response)

        result = await connector._detect_bridge_room("!room:localhost")
        assert result is not None
        assert "@metabot:localhost" in result["bridge_bots"]
        assert "@metabot:localhost" not in result["ghost_users"]

    @pytest.mark.asyncio
    async def test_rejects_federated_ghost_users(self):
        """Ghost users from a foreign homeserver are not detected as bridges."""
        connector = _make_matrix_connector(homeserver_url="http://localhost:6167")

        mock_response = SimpleNamespace(
            members={
                "@parachute:localhost": {},
                "@meta_999:evil.com": {},  # Federated user mimicking ghost pattern
            }
        )
        connector._client = AsyncMock()
        connector._client.joined_members = AsyncMock(return_value=mock_response)

        result = await connector._detect_bridge_room("!room:localhost")
        assert result is None


# ---------------------------------------------------------------------------
# Handle bridged room tests
# ---------------------------------------------------------------------------


class TestHandleBridgedRoom:
    @pytest.mark.asyncio
    async def test_creates_pairing_request_and_session(self):
        """_handle_bridged_room creates a pairing request and pending session."""
        connector = _make_matrix_connector()

        mock_db = AsyncMock()
        mock_db.get_pairing_request_for_user = AsyncMock(return_value=None)
        mock_db.create_pairing_request = AsyncMock()
        mock_db.create_session = AsyncMock()
        connector.server = SimpleNamespace(database=mock_db)
        connector._client = AsyncMock()

        bridge_info = {
            "bridge_type": "meta",
            "ghost_users": ["@meta_123:localhost"],
            "bridge_bots": ["@metabot:localhost"],
            "remote_chat_type": "dm",
        }

        await connector._handle_bridged_room("!room:localhost", "Test Room", bridge_info)

        # Pairing request created with room_id as platform_user_id
        mock_db.create_pairing_request.assert_called_once()
        call_kwargs = mock_db.create_pairing_request.call_args[1]
        assert call_kwargs["platform"] == "matrix"
        assert call_kwargs["platform_user_id"] == "!room:localhost"
        assert "Meta Bridge" in call_kwargs["platform_user_display"]

        # Pending session created with bridge metadata
        mock_db.create_session.assert_called_once()
        session_create = mock_db.create_session.call_args[0][0]
        assert session_create.metadata["pending_approval"] is True
        assert session_create.metadata["bridge_metadata"] == bridge_info

    @pytest.mark.asyncio
    async def test_skips_duplicate_pairing_request(self):
        """_handle_bridged_room skips if a pending request already exists."""
        connector = _make_matrix_connector()

        existing_pr = SimpleNamespace(status="pending")
        mock_db = AsyncMock()
        mock_db.get_pairing_request_for_user = AsyncMock(return_value=existing_pr)
        mock_db.create_pairing_request = AsyncMock()
        connector.server = SimpleNamespace(database=mock_db)

        bridge_info = {
            "bridge_type": "meta",
            "ghost_users": ["@meta_123:localhost"],
            "bridge_bots": [],
            "remote_chat_type": "dm",
        }

        await connector._handle_bridged_room("!room:localhost", "Test Room", bridge_info)

        mock_db.create_pairing_request.assert_not_called()


# ---------------------------------------------------------------------------
# Allowlist room-based approval tests
# ---------------------------------------------------------------------------


class TestAllowlistRoomApproval:
    @pytest.mark.asyncio
    async def test_add_room_to_allowlist(self, tmp_path):
        """_add_to_allowlist with is_room=True adds to allowed_rooms."""
        from parachute.api.bots import _add_to_allowlist, _write_bots_config, init_bots_api
        from parachute.connectors.config import BotsConfig, MatrixConfig

        parachute_dir = tmp_path / ".parachute"
        parachute_dir.mkdir()

        # Write initial config with matrix enabled
        initial_config = BotsConfig(
            matrix=MatrixConfig(
                enabled=True,
                homeserver_url="http://localhost:6167",
                user_id="@parachute:localhost",
                access_token="test-token",
                allowed_rooms=["!existing:localhost"],
            )
        )
        import parachute.api.bots as bots_module
        old_vault = bots_module._vault_path
        bots_module._vault_path = tmp_path
        _write_bots_config(initial_config)

        try:
            await _add_to_allowlist("matrix", "!new_room:localhost", is_room=True)

            # Verify it was written
            updated_config = load_bots_config(tmp_path)
            assert "!existing:localhost" in updated_config.matrix.allowed_rooms
            assert "!new_room:localhost" in updated_config.matrix.allowed_rooms
        finally:
            bots_module._vault_path = old_vault

    @pytest.mark.asyncio
    async def test_add_room_idempotent(self, tmp_path):
        """Adding the same room twice doesn't duplicate."""
        from parachute.api.bots import _add_to_allowlist, _write_bots_config
        from parachute.connectors.config import BotsConfig, MatrixConfig

        parachute_dir = tmp_path / ".parachute"
        parachute_dir.mkdir()

        initial_config = BotsConfig(
            matrix=MatrixConfig(
                enabled=True,
                homeserver_url="http://localhost:6167",
                user_id="@parachute:localhost",
                access_token="test-token",
                allowed_rooms=["!room:localhost"],
            )
        )
        import parachute.api.bots as bots_module
        old_vault = bots_module._vault_path
        bots_module._vault_path = tmp_path
        _write_bots_config(initial_config)

        try:
            await _add_to_allowlist("matrix", "!room:localhost", is_room=True)

            updated_config = load_bots_config(tmp_path)
            assert updated_config.matrix.allowed_rooms.count("!room:localhost") == 1
        finally:
            bots_module._vault_path = old_vault

    @pytest.mark.asyncio
    async def test_add_user_still_works(self, tmp_path):
        """Regular user-based allowlist still works."""
        from parachute.api.bots import _add_to_allowlist, _write_bots_config
        from parachute.connectors.config import BotsConfig, DiscordConfig

        parachute_dir = tmp_path / ".parachute"
        parachute_dir.mkdir()

        initial_config = BotsConfig(
            discord=DiscordConfig(
                enabled=True,
                bot_token="test-token",
                allowed_users=["user1"],
            )
        )
        import parachute.api.bots as bots_module
        old_vault = bots_module._vault_path
        bots_module._vault_path = tmp_path
        _write_bots_config(initial_config)

        try:
            await _add_to_allowlist("discord", "user2")

            updated_config = load_bots_config(tmp_path)
            assert "user1" in updated_config.discord.allowed_users
            assert "user2" in updated_config.discord.allowed_users
        finally:
            bots_module._vault_path = old_vault


# ---------------------------------------------------------------------------
# Fix 1 — Token bucket rate limiter
# ---------------------------------------------------------------------------


class TestRateLimiter:
    def test_allows_messages_within_limit(self):
        c = _make_test_connector()
        # All 10 messages in the window should be allowed
        for _ in range(10):
            assert c._check_rate_limit("chat1") is True

    def test_rejects_11th_message(self):
        c = _make_test_connector()
        for _ in range(10):
            c._check_rate_limit("chat1")
        # 11th should be rejected
        assert c._check_rate_limit("chat1") is False

    def test_per_chat_isolation(self):
        c = _make_test_connector()
        # Exhaust chat1's bucket
        for _ in range(10):
            c._check_rate_limit("chat1")
        assert c._check_rate_limit("chat1") is False
        # chat2 is unaffected
        assert c._check_rate_limit("chat2") is True

    def test_bucket_refills_after_window(self):
        c = _make_test_connector()
        c._rate_window = 0.05  # 50ms window for fast tests
        for _ in range(10):
            c._check_rate_limit("chat1")
        assert c._check_rate_limit("chat1") is False

        # Wait for the window to expire
        time.sleep(0.1)
        assert c._check_rate_limit("chat1") is True

    def test_first_message_always_allowed(self):
        c = _make_test_connector()
        assert c._check_rate_limit("new_chat") is True


# ---------------------------------------------------------------------------
# Fix 2 — Message send retry
# ---------------------------------------------------------------------------


class TestSendWithRetry:
    @pytest.mark.asyncio
    async def test_succeeds_on_first_attempt(self):
        c = _make_test_connector()
        calls = []

        async def factory():
            calls.append(1)

        await c._send_with_retry(factory, "chat1")
        assert len(calls) == 1

    @pytest.mark.asyncio
    async def test_retries_on_failure_then_succeeds(self):
        c = _make_test_connector()
        attempts = []

        async def factory():
            attempts.append(1)
            if len(attempts) < 2:
                raise OSError("network blip")

        with patch("asyncio.sleep", return_value=None):
            await c._send_with_retry(factory, "chat1")

        assert len(attempts) == 2

    @pytest.mark.asyncio
    async def test_gives_up_after_three_attempts(self):
        c = _make_test_connector()
        attempts = []

        async def factory():
            attempts.append(1)
            raise OSError("always fails")

        with patch("asyncio.sleep", return_value=None):
            await c._send_with_retry(factory, "chat1")  # Should not raise

        assert len(attempts) == 3

    @pytest.mark.asyncio
    async def test_backoff_delays_are_1_2_4(self):
        c = _make_test_connector()
        slept = []

        async def fake_sleep(delay):
            slept.append(delay)

        async def factory():
            raise OSError("fail")

        with patch("asyncio.sleep", side_effect=fake_sleep):
            await c._send_with_retry(factory, "chat1")

        # 3 failures → 2 sleeps (1s and 2s; no sleep after the last attempt)
        assert slept == [1.0, 2.0]


# ---------------------------------------------------------------------------
# Fix 3 — State machine raises on invalid transitions
# ---------------------------------------------------------------------------


class TestStateMachineStrictness:
    def test_invalid_transition_raises(self):
        c = _make_test_connector()
        with pytest.raises(RuntimeError, match="Invalid connector state transition"):
            c._set_status(ConnectorState.RECONNECTING)  # stopped -> reconnecting is invalid

    def test_valid_transitions_do_not_raise(self):
        c = _make_test_connector()
        c._set_status(ConnectorState.RUNNING)          # stopped -> running: valid
        c._set_status(ConnectorState.RECONNECTING)     # running -> reconnecting: valid
        c._set_status(ConnectorState.RUNNING)          # reconnecting -> running: valid
        c._set_status(ConnectorState.STOPPED)          # running -> stopped: valid

    def test_all_valid_transitions(self):
        """Every valid transition in _VALID_TRANSITIONS should not raise."""
        from parachute.connectors.base import BotConnector
        for from_state, to_states in BotConnector._VALID_TRANSITIONS.items():
            for to_state in to_states:
                c = _make_test_connector()
                c._status = from_state
                c._set_status(to_state)  # Should not raise


# ---------------------------------------------------------------------------
# Fix 4a + 4b — TTL expiry + nudge counter reset
# ---------------------------------------------------------------------------


class TestPairingTTL:
    @pytest.mark.asyncio
    async def test_expire_stale_requests_marks_expired(self):
        """expire_stale_pairing_requests expires old pending requests."""
        from datetime import timedelta

        c = _make_test_connector()
        mock_db = AsyncMock()

        stale_req = SimpleNamespace(
            id="req-old",
            platform="telegram",
            platform_user_id="111",
            platform_chat_id="chat_111",
        )
        mock_db.get_expired_pairing_requests = AsyncMock(return_value=[stale_req])
        mock_db.expire_pairing_request = AsyncMock()
        c.server = SimpleNamespace(database=mock_db)

        count = await c.expire_stale_pairing_requests(ttl_days=7)

        assert count == 1
        mock_db.expire_pairing_request.assert_called_once_with("req-old")

    @pytest.mark.asyncio
    async def test_expire_stale_resets_nudge_counter(self):
        """Nudge counter is cleared for chats whose pairing request expires."""
        c = _make_test_connector()
        c._init_nudge_sent["chat_111"] = 3  # Pre-populate counter

        mock_db = AsyncMock()
        stale_req = SimpleNamespace(
            id="req-old",
            platform="telegram",
            platform_user_id="111",
            platform_chat_id="chat_111",
        )
        mock_db.get_expired_pairing_requests = AsyncMock(return_value=[stale_req])
        mock_db.expire_pairing_request = AsyncMock()
        c.server = SimpleNamespace(database=mock_db)

        await c.expire_stale_pairing_requests()
        assert "chat_111" not in c._init_nudge_sent

    @pytest.mark.asyncio
    async def test_expire_stale_no_db(self):
        """Returns 0 gracefully when no database is configured."""
        c = _make_test_connector()
        c.server = SimpleNamespace()  # No .database attribute
        count = await c.expire_stale_pairing_requests()
        assert count == 0

    @pytest.mark.asyncio
    async def test_get_expired_pairing_requests(self, test_database):
        """get_expired_pairing_requests returns only old pending rows."""
        import uuid
        from datetime import timedelta

        # Insert a fresh pending request
        fresh_id = str(uuid.uuid4())
        await test_database.create_pairing_request(
            id=fresh_id,
            platform="telegram",
            platform_user_id="111",
            platform_chat_id="chat1",
        )

        # Insert a stale pending request (simulate 8 days old)
        stale_id = str(uuid.uuid4())
        stale_time = (datetime.now(timezone.utc) - timedelta(days=8)).isoformat()
        await test_database.connection.execute(
            """
            INSERT INTO pairing_requests
            (id, platform, platform_user_id, platform_chat_id, status, created_at)
            VALUES (?, 'telegram', '222', 'chat2', 'pending', ?)
            """,
            (stale_id, stale_time),
        )
        await test_database.connection.commit()

        expired = await test_database.get_expired_pairing_requests(ttl_days=7)
        expired_ids = [r.id for r in expired]
        assert stale_id in expired_ids
        assert fresh_id not in expired_ids

    @pytest.mark.asyncio
    async def test_expire_pairing_request(self, test_database):
        """expire_pairing_request marks a pending request as expired."""
        import uuid
        req_id = str(uuid.uuid4())
        await test_database.create_pairing_request(
            id=req_id,
            platform="telegram",
            platform_user_id="333",
            platform_chat_id="chat3",
        )

        await test_database.expire_pairing_request(req_id)

        updated = await test_database.get_pairing_request(req_id)
        assert updated.status == "expired"

    @pytest.mark.asyncio
    async def test_expire_does_not_affect_non_pending(self, test_database):
        """expire_pairing_request is a no-op on already-resolved requests."""
        import uuid
        req_id = str(uuid.uuid4())
        await test_database.create_pairing_request(
            id=req_id,
            platform="telegram",
            platform_user_id="444",
            platform_chat_id="chat4",
        )
        await test_database.resolve_pairing_request(req_id, approved=True, trust_level="sandboxed")

        # Trying to expire an already-approved request should be a no-op
        await test_database.expire_pairing_request(req_id)
        updated = await test_database.get_pairing_request(req_id)
        assert updated.status == "approved"  # Unchanged


# ---------------------------------------------------------------------------
# Fix 4c — Revocation endpoint
# ---------------------------------------------------------------------------


class TestRevokeUser:
    @pytest.mark.asyncio
    async def test_revoke_removes_from_yaml_and_memory(self, tmp_path):
        """DELETE /pairing/{platform}/{user_id} removes from YAML and connector."""
        from parachute.api.bots import revoke_user, _write_bots_config, init_bots_api
        from parachute.connectors.config import BotsConfig, DiscordConfig

        parachute_dir = tmp_path / ".parachute"
        parachute_dir.mkdir()

        initial_config = BotsConfig(
            discord=DiscordConfig(
                enabled=True,
                bot_token="test-token",
                allowed_users=["user1", "user2"],
            )
        )
        import parachute.api.bots as bots_module
        old_vault = bots_module._vault_path
        old_connectors = bots_module._connectors
        bots_module._vault_path = tmp_path
        _write_bots_config(initial_config)

        # Set up mock connector with in-memory state
        mock_connector = MagicMock()
        mock_connector.allowed_users = ["user1", "user2"]
        mock_connector._trust_overrides = {"user1": "sandboxed"}
        bots_module._connectors = {"discord": mock_connector}

        try:
            result = await revoke_user("discord", "user1")
            assert result["success"] is True

            # YAML updated
            updated_config = load_bots_config(tmp_path)
            assert "user1" not in [str(u) for u in updated_config.discord.allowed_users]
            assert "user2" in [str(u) for u in updated_config.discord.allowed_users]

            # In-memory connector updated
            assert "user1" not in [str(u) for u in mock_connector.allowed_users]
            assert "user1" not in mock_connector._trust_overrides
        finally:
            bots_module._vault_path = old_vault
            bots_module._connectors = old_connectors

    @pytest.mark.asyncio
    async def test_revoke_unknown_user_returns_404(self, tmp_path):
        from parachute.api.bots import revoke_user, _write_bots_config
        from parachute.connectors.config import BotsConfig, DiscordConfig
        from fastapi import HTTPException

        parachute_dir = tmp_path / ".parachute"
        parachute_dir.mkdir()

        initial_config = BotsConfig(
            discord=DiscordConfig(enabled=True, bot_token="test-token", allowed_users=["user1"])
        )
        import parachute.api.bots as bots_module
        old_vault = bots_module._vault_path
        bots_module._vault_path = tmp_path
        _write_bots_config(initial_config)

        try:
            with pytest.raises(HTTPException) as exc_info:
                await revoke_user("discord", "nonexistent")
            assert exc_info.value.status_code == 404
        finally:
            bots_module._vault_path = old_vault


# ---------------------------------------------------------------------------
# Fix 5 — Session archived state guard
# ---------------------------------------------------------------------------


class TestSessionArchivedGuard:
    @pytest.mark.asyncio
    async def test_archived_session_sends_notice_and_returns_none(self):
        """get_or_create_session returns None for archived sessions."""
        c = _make_test_connector()
        c.send_message = AsyncMock()

        archived_session = SimpleNamespace(id="sess-abc", archived=True)
        mock_db = AsyncMock()
        mock_db.get_session_by_bot_link = AsyncMock(return_value=archived_session)
        c.server = SimpleNamespace(database=mock_db)

        result = await c.get_or_create_session("telegram", "chat1", "dm", "Alice")

        assert result is None
        c.send_message.assert_called_once()
        msg = c.send_message.call_args[0][1]
        assert "session" in msg.lower() or "ended" in msg.lower()

    @pytest.mark.asyncio
    async def test_active_session_returned_normally(self):
        """get_or_create_session returns an active (non-archived) session."""
        c = _make_test_connector()

        active_session = SimpleNamespace(id="sess-xyz", archived=False)
        mock_db = AsyncMock()
        mock_db.get_session_by_bot_link = AsyncMock(return_value=active_session)
        c.server = SimpleNamespace(database=mock_db)

        result = await c.get_or_create_session("telegram", "chat2", "dm", "Bob")
        assert result is active_session

    @pytest.mark.asyncio
    async def test_no_existing_session_creates_new(self):
        """get_or_create_session creates a new session when none exists."""
        c = _make_test_connector()

        new_session = SimpleNamespace(id="sess-new", archived=False)
        mock_db = AsyncMock()
        mock_db.get_session_by_bot_link = AsyncMock(return_value=None)
        mock_db.create_session = AsyncMock(return_value=new_session)
        c.server = SimpleNamespace(database=mock_db)

        result = await c.get_or_create_session("telegram", "chat3", "dm", "Charlie")
        assert result is new_session
        mock_db.create_session.assert_called_once()


# ---------------------------------------------------------------------------
# Issue #88 Fix 1 — error_occurred flag in _route_to_chat (Discord + Matrix)
# ---------------------------------------------------------------------------


def _make_discord_connector(**kwargs):
    """Create a DiscordConnector for testing."""
    from parachute.connectors.discord_bot import DiscordConnector

    defaults = dict(
        bot_token="test-token",
        server=SimpleNamespace(database=None),
        allowed_users=["user1"],
    )
    defaults.update(kwargs)
    return DiscordConnector(**defaults)


async def _async_events(events):
    """Yield events as an async generator for orchestrate mock."""
    for event in events:
        yield event


class TestErrorOccurredFlagDiscord:
    @pytest.mark.asyncio
    async def test_bare_error_event_suppresses_fallback(self):
        """A bare 'error' event should NOT produce 'No response from agent.'."""
        connector = _make_discord_connector()
        connector.server = SimpleNamespace(
            orchestrate=lambda **kw: _async_events(
                [{"type": "error", "error": "something blew up"}]
            )
        )
        result = await connector._route_to_chat("sess-1", "hi")
        assert result == ""
        assert "No response" not in result

    @pytest.mark.asyncio
    async def test_no_events_produces_fallback(self):
        """No events → fallback 'No response from agent.'"""
        connector = _make_discord_connector()
        connector.server = SimpleNamespace(
            orchestrate=lambda **kw: _async_events([])
        )
        result = await connector._route_to_chat("sess-1", "hi")
        assert result == "No response from agent."

    @pytest.mark.asyncio
    async def test_text_event_returns_content(self):
        """A normal text event returns the content without fallback."""
        connector = _make_discord_connector()
        connector.server = SimpleNamespace(
            orchestrate=lambda **kw: _async_events(
                [{"type": "text", "content": "Hello there!"}]
            )
        )
        result = await connector._route_to_chat("sess-1", "hi")
        assert result == "Hello there!"

    @pytest.mark.asyncio
    async def test_typed_error_suppresses_fallback(self):
        """A typed_error event suppresses the 'No response' fallback."""
        connector = _make_discord_connector()
        connector.server = SimpleNamespace(
            orchestrate=lambda **kw: _async_events(
                [{"type": "typed_error", "title": "Oops", "message": "bad thing"}]
            )
        )
        result = await connector._route_to_chat("sess-1", "hi")
        assert "⚠️" in result
        assert "No response from agent." not in result


class TestErrorOccurredFlagMatrix:
    @pytest.mark.asyncio
    async def test_bare_error_event_suppresses_fallback(self):
        """A bare 'error' event should NOT produce 'No response from agent.'."""
        connector = _make_matrix_connector()
        connector.server = SimpleNamespace(
            orchestrate=lambda **kw: _async_events(
                [{"type": "error", "error": "matrix exploded"}]
            )
        )
        result = await connector._route_to_chat("sess-1", "hi")
        assert result == ""
        assert "No response" not in result

    @pytest.mark.asyncio
    async def test_no_events_produces_fallback(self):
        """No events → fallback 'No response from agent.'"""
        connector = _make_matrix_connector()
        connector.server = SimpleNamespace(
            orchestrate=lambda **kw: _async_events([])
        )
        result = await connector._route_to_chat("sess-1", "hi")
        assert result == "No response from agent."

    @pytest.mark.asyncio
    async def test_typed_error_message_variable_is_message(self):
        """Matrix typed_error handler uses 'message' (not 'msg') local variable."""
        connector = _make_matrix_connector()
        connector.server = SimpleNamespace(
            orchestrate=lambda **kw: _async_events(
                [{"type": "typed_error", "title": "T", "message": "body text"}]
            )
        )
        result = await connector._route_to_chat("sess-1", "hi")
        # Should include the message body in the response
        assert "body text" in result

    @pytest.mark.asyncio
    async def test_warning_message_variable_is_message(self):
        """Matrix warning handler uses 'message' (not 'msg') local variable."""
        connector = _make_matrix_connector()
        connector.server = SimpleNamespace(
            orchestrate=lambda **kw: _async_events(
                [
                    {"type": "text", "content": "main reply"},
                    {"type": "warning", "title": "W", "message": "warn body"},
                ]
            )
        )
        result = await connector._route_to_chat("sess-1", "hi")
        assert "warn body" in result


# ---------------------------------------------------------------------------
# Issue #88 Fix 2 — Discord on_voice_message
# ---------------------------------------------------------------------------


class TestDiscordVoiceMessage:
    def _make_audio_message(self, content_type="audio/ogg", transcription="hello"):
        """Build a minimal mock discord.Message with an audio attachment."""
        attachment = MagicMock()
        attachment.content_type = content_type
        attachment.filename = "voice_message.ogg"  # required by _is_audio_attachment
        attachment.size = 1024  # 1 KB — well within MAX_AUDIO_BYTES limit
        attachment.read = AsyncMock(return_value=b"fake-audio-bytes")

        msg = MagicMock()
        msg.attachments = [attachment]
        msg.author.id = "user1"
        msg.author.display_name = "Alice"
        msg.channel.id = "channel1"
        msg.guild = None  # DM
        msg.reply = AsyncMock()
        return msg

    @pytest.mark.asyncio
    async def test_audio_attachment_transcribed_and_replied(self):
        """Voice message is transcribed and reply is sent."""
        connector = _make_discord_connector(allowed_users=["user1"])
        msg = self._make_audio_message()

        session = SimpleNamespace(id="sess-v", archived=False, metadata={})
        mock_db = AsyncMock()
        mock_db.get_session_by_bot_link = AsyncMock(return_value=session)
        connector.server = SimpleNamespace(
            database=mock_db,
            transcribe_audio=AsyncMock(return_value="transcribed text"),
            orchestrate=lambda **kw: _async_events(
                [{"type": "text", "content": "response"}]
            ),
        )
        connector.is_session_initialized = AsyncMock(return_value=True)

        await connector.on_voice_message(msg, None)

        connector.server.transcribe_audio.assert_called_once_with(b"fake-audio-bytes")
        msg.reply.assert_called()

    @pytest.mark.asyncio
    async def test_no_audio_attachment_returns_silently(self):
        """Message with no audio attachment does nothing."""
        connector = _make_discord_connector(allowed_users=["user1"])
        msg = MagicMock()
        msg.attachments = []  # No attachments

        await connector.on_voice_message(msg, None)
        # No reply sent
        msg.reply = AsyncMock()
        msg.reply.assert_not_called()

    @pytest.mark.asyncio
    async def test_no_transcription_service_sends_error(self):
        """Missing transcribe_audio sends user-friendly error."""
        connector = _make_discord_connector(allowed_users=["user1"])
        msg = self._make_audio_message()
        connector.server = SimpleNamespace(database=None)  # No transcribe_audio

        await connector.on_voice_message(msg, None)
        msg.reply.assert_called_once()
        assert "transcription" in msg.reply.call_args[0][0].lower()

    @pytest.mark.asyncio
    async def test_empty_transcription_sends_error(self):
        """Empty transcription result sends user-friendly error."""
        connector = _make_discord_connector(allowed_users=["user1"])
        msg = self._make_audio_message()
        connector.server = SimpleNamespace(
            database=None,
            transcribe_audio=AsyncMock(return_value=""),
        )

        await connector.on_voice_message(msg, None)
        msg.reply.assert_called_once()
        assert "transcribe" in msg.reply.call_args[0][0].lower()

    @pytest.mark.asyncio
    async def test_unauthorized_user_ignored_silently(self):
        """Unknown user's voice message is silently ignored (no double-reply)."""
        connector = _make_discord_connector(allowed_users=["other_user"])
        msg = self._make_audio_message()
        msg.author.id = "unknown_user"

        await connector.on_voice_message(msg, None)
        msg.reply.assert_not_called()


# ---------------------------------------------------------------------------
# Issue #88 Fix 3a — Matrix ack removal via room_redact
# ---------------------------------------------------------------------------


class TestMatrixAckRemove:
    @pytest.mark.asyncio
    async def test_ack_event_id_captured_and_redacted(self):
        """room_redact is called with the event_id from the ack room_send."""
        connector = _make_matrix_connector(ack_emoji="👀")
        connector._client = AsyncMock()

        ack_resp = SimpleNamespace(event_id="$ack-event-123")
        connector._client.room_send = AsyncMock(return_value=ack_resp)
        connector._client.room_typing = AsyncMock()
        connector._client.room_redact = AsyncMock()

        session = SimpleNamespace(id="sess-m", archived=False, metadata={})
        mock_db = AsyncMock()
        mock_db.get_session_by_bot_link = AsyncMock(return_value=session)
        connector.server = SimpleNamespace(
            database=mock_db,
            orchestrate=lambda **kw: _async_events(
                [{"type": "text", "content": "hi back"}]
            ),
        )
        connector.is_session_initialized = AsyncMock(return_value=True)
        connector._send_room_message = AsyncMock()
        connector._split_matrix_response = MagicMock(return_value=[("hi back", "")])
        connector._get_chat_lock = MagicMock(return_value=asyncio.Lock())
        connector._resolve_bridge_auth = AsyncMock(
            return_value=("dm", True, session)
        )

        event = SimpleNamespace(
            event_id="$orig-event",
            sender="@alice:localhost",
            body="hello",
            source={"content": {"msgtype": "m.text", "body": "hello"}},
        )
        room = SimpleNamespace(room_id="!room:localhost", display_name="Alice")
        update = {"room": room, "event": event}

        await connector.on_text_message(update, None)

        connector._client.room_redact.assert_called_once_with(
            "!room:localhost", "$ack-event-123"
        )

    @pytest.mark.asyncio
    async def test_ack_not_redacted_when_room_send_fails(self):
        """If ack room_send fails, room_redact is not called."""
        connector = _make_matrix_connector(ack_emoji="👀")
        connector._client = AsyncMock()
        connector._client.room_send = AsyncMock(side_effect=Exception("send failed"))
        connector._client.room_typing = AsyncMock()
        connector._client.room_redact = AsyncMock()

        session = SimpleNamespace(id="sess-m2", archived=False, metadata={})
        mock_db = AsyncMock()
        mock_db.get_session_by_bot_link = AsyncMock(return_value=session)
        connector.server = SimpleNamespace(
            database=mock_db,
            orchestrate=lambda **kw: _async_events(
                [{"type": "text", "content": "reply"}]
            ),
        )
        connector.is_session_initialized = AsyncMock(return_value=True)
        connector._send_room_message = AsyncMock()
        connector._split_matrix_response = MagicMock(return_value=[("reply", "")])
        connector._get_chat_lock = MagicMock(return_value=asyncio.Lock())
        connector._resolve_bridge_auth = AsyncMock(
            return_value=("dm", True, session)
        )

        event = SimpleNamespace(
            event_id="$orig-event2",
            sender="@alice:localhost",
            body="hello",
            source={"content": {"msgtype": "m.text", "body": "hello"}},
        )
        room = SimpleNamespace(room_id="!room2:localhost", display_name="Alice")

        await connector.on_text_message({"room": room, "event": event}, None)
        connector._client.room_redact.assert_not_called()


# ---------------------------------------------------------------------------
# Issue #88 Fix 3b — Discord /chat slash command ack emoji
# ---------------------------------------------------------------------------


class TestDiscordSlashAck:
    @pytest.mark.asyncio
    async def test_slash_chat_sends_ephemeral_ack(self):
        """_handle_chat sends ephemeral ack emoji after defer."""
        connector = _make_discord_connector(
            allowed_users=["user1"], ack_emoji="👀"
        )

        interaction = MagicMock()
        interaction.user.id = "user1"
        interaction.user.display_name = "Alice"
        interaction.guild = None
        interaction.channel_id = "chan1"
        interaction.response.defer = AsyncMock()
        interaction.followup.send = AsyncMock()

        session = SimpleNamespace(id="sess-s", archived=False, metadata={})
        mock_db = AsyncMock()
        mock_db.get_session_by_bot_link = AsyncMock(return_value=session)
        connector.server = SimpleNamespace(
            database=mock_db,
            orchestrate=lambda **kw: _async_events(
                [{"type": "text", "content": "slash reply"}]
            ),
        )
        connector.is_session_initialized = AsyncMock(return_value=True)
        connector.get_or_create_session = AsyncMock(return_value=session)
        interaction.channel = MagicMock()

        await connector._handle_chat(interaction, "hello")

        # Ephemeral ack was sent
        ack_calls = [
            call
            for call in interaction.followup.send.call_args_list
            if call.kwargs.get("ephemeral") is True
        ]
        assert len(ack_calls) == 1
        assert ack_calls[0].args[0] == "👀"

    @pytest.mark.asyncio
    async def test_slash_chat_no_ack_when_emoji_not_set(self):
        """_handle_chat does not send ack when ack_emoji is None."""
        connector = _make_discord_connector(
            allowed_users=["user1"], ack_emoji=None
        )

        interaction = MagicMock()
        interaction.user.id = "user1"
        interaction.user.display_name = "Alice"
        interaction.guild = None
        interaction.channel_id = "chan1"
        interaction.response.defer = AsyncMock()
        interaction.followup.send = AsyncMock()

        session = SimpleNamespace(id="sess-s2", archived=False, metadata={})
        connector.server = SimpleNamespace(
            database=None,
            orchestrate=lambda **kw: _async_events(
                [{"type": "text", "content": "reply"}]
            ),
        )
        connector.is_session_initialized = AsyncMock(return_value=True)
        connector.get_or_create_session = AsyncMock(return_value=session)
        interaction.channel = MagicMock()

        await connector._handle_chat(interaction, "hello")

        # No ephemeral ack calls
        ephemeral_calls = [
            call
            for call in interaction.followup.send.call_args_list
            if call.kwargs.get("ephemeral") is True
        ]
        assert len(ephemeral_calls) == 0


# ---------------------------------------------------------------------------
# Issue #88 Fix 4 — Discord group history ring buffer
# ---------------------------------------------------------------------------


class TestDiscordRingBuffer:
    @pytest.mark.asyncio
    async def test_disallowed_user_message_not_recorded(self):
        """Disallowed users' messages are NOT recorded in the ring buffer."""
        import discord

        connector = _make_discord_connector(allowed_users=[])  # No allowed users

        msg = MagicMock()
        msg.author.id = "stranger"
        msg.author.display_name = "Stranger"
        msg.content = "hi everyone"
        msg.created_at = datetime.now(timezone.utc)
        msg.id = 9999
        msg.channel = MagicMock(spec=discord.TextChannel)
        msg.channel.id = "ch42"
        msg.reply = AsyncMock()

        await connector.on_text_message(msg, None)

        # Disallowed user's message must not appear in the ring buffer
        recent = connector.group_history.get_recent("ch42")
        assert len(recent) == 0

    @pytest.mark.asyncio
    async def test_allowed_user_message_recorded_before_mention_gate(self):
        """Allowed users' messages are recorded even if bot isn't mentioned."""
        import discord

        connector = _make_discord_connector(
            allowed_users=["user1"],
            group_mention_mode="mention_only",
        )
        connector.server = SimpleNamespace(database=None)
        # Mock the Discord client so the mention gate can evaluate
        connector._client = MagicMock()
        connector._client.user = MagicMock()

        msg = MagicMock()
        msg.author.id = "user1"
        msg.author.display_name = "Alice"
        msg.content = "hello channel"
        msg.created_at = datetime.now(timezone.utc)
        msg.id = 1234
        msg.channel = MagicMock(spec=discord.TextChannel)
        msg.channel.id = "ch99"
        msg.guild = MagicMock()  # Group context
        # Bot not mentioned — message will be silently ignored after recording
        msg.mentions = []
        msg.reply = AsyncMock()

        await connector.on_text_message(msg, None)

        # Message should be recorded even though bot wasn't mentioned
        recent = connector.group_history.get_recent("ch99")
        assert len(recent) == 1
        assert recent[0].text == "hello channel"

    def test_get_group_history_method_does_not_exist(self):
        """_get_group_history was deleted; it should not exist on DiscordConnector."""
        connector = _make_discord_connector()
        assert not hasattr(connector, "_get_group_history")

    def test_ring_buffer_excludes_triggering_message(self):
        """get_recent excludes the message that triggered the bot response."""
        from parachute.connectors.base import GroupMessage

        connector = _make_discord_connector()
        now = datetime.now(timezone.utc)

        for i in range(3):
            connector.group_history.record(
                "ch1",
                GroupMessage(
                    user_display=f"User{i}",
                    text=f"msg {i}",
                    timestamp=now,
                    message_id=i,
                ),
            )

        # Exclude message_id=2 (the triggering message)
        recent = connector.group_history.get_recent("ch1", exclude_message_id=2)
        ids = [m.message_id for m in recent]
        assert 2 not in ids
        assert 0 in ids
        assert 1 in ids

    def test_ring_buffer_format_for_prompt(self):
        """format_for_prompt produces XML-wrapped group context."""
        from parachute.connectors.base import GroupMessage

        connector = _make_discord_connector()
        now = datetime.now(timezone.utc)

        connector.group_history.record(
            "ch2",
            GroupMessage(
                user_display="Alice",
                text="Hello world",
                timestamp=now,
                message_id=1,
            ),
        )
        recent = connector.group_history.get_recent("ch2")
        prompt = connector.group_history.format_for_prompt(recent)
        assert "<group_context>" in prompt
        assert "Alice" in prompt
        assert "Hello world" in prompt
