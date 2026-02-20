"""
Tests for bot connectors: base class, message formatter, config loading, resilience.
"""

import asyncio
import tempfile
import time
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
    def test_default_config(self):
        config = BotsConfig()
        assert not config.telegram.enabled
        assert not config.discord.enabled
        assert config.telegram.dm_trust_level == "vault"
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
        config = DiscordConfig(
            enabled=True,
            bot_token="test-token",
            allowed_guilds=["guild1", "guild2"],
        )
        assert config.enabled
        assert len(config.allowed_guilds) == 2

    def test_full_config_parsing(self):
        config = BotsConfig(**{
            "telegram": {
                "enabled": True,
                "bot_token": "tg-token",
                "allowed_users": [111],
                "dm_trust_level": "full",
                "group_trust_level": "sandboxed",
            },
            "discord": {
                "enabled": True,
                "bot_token": "dc-token",
                "allowed_guilds": ["g1"],
            },
        })
        assert config.telegram.enabled
        assert config.telegram.dm_trust_level == "full"
        assert config.discord.enabled

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
    def test_is_user_allowed_int(self):
        class TestConnector(BotConnector):
            platform = "test"
            async def start(self): pass
            async def stop(self): pass
            async def on_text_message(self, update, context): pass
            async def _run_loop(self): pass

        connector = TestConnector(
            bot_token="test",
            server=None,
            allowed_users=[123, 456],
        )
        assert connector.is_user_allowed(123)
        assert connector.is_user_allowed(456)
        assert not connector.is_user_allowed(789)

    def test_is_user_allowed_string(self):
        class TestConnector(BotConnector):
            platform = "test"
            async def start(self): pass
            async def stop(self): pass
            async def on_text_message(self, update, context): pass
            async def _run_loop(self): pass

        connector = TestConnector(
            bot_token="test",
            server=None,
            allowed_users=["123", "456"],
        )
        assert connector.is_user_allowed("123")
        assert connector.is_user_allowed(123)  # int matches string

    def test_get_trust_level(self):
        class TestConnector(BotConnector):
            platform = "test"
            async def start(self): pass
            async def stop(self): pass
            async def on_text_message(self, update, context): pass
            async def _run_loop(self): pass

        connector = TestConnector(
            bot_token="test",
            server=None,
            allowed_users=[],
            dm_trust_level="vault",
            group_trust_level="sandboxed",
        )
        assert connector.get_trust_level("dm") == "vault"
        assert connector.get_trust_level("group") == "sandboxed"

    def test_status_enriched_fields(self):
        class TestConnector(BotConnector):
            platform = "test"
            async def start(self): pass
            async def stop(self): pass
            async def on_text_message(self, update, context): pass
            async def _run_loop(self): pass

        connector = TestConnector(
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
        from parachute.api.bots import router
        assert router.prefix == "/api/bots"


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
        """Invalid transitions should be rejected."""
        c = _make_test_connector()
        # stopped -> reconnecting is invalid
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
        assert config.dm_trust_level == "untrusted"
        assert config.group_trust_level == "untrusted"
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

    def test_trust_level_normalization(self):
        config = MatrixConfig(
            dm_trust_level="full",
            group_trust_level="sandboxed",
        )
        assert config.dm_trust_level == "trusted"
        assert config.group_trust_level == "untrusted"

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
