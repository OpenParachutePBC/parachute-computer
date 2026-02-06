"""
Tests for bot connectors: base class, message formatter, config loading.
"""

import tempfile
from pathlib import Path

import pytest

from parachute.connectors.base import BotConnector
from parachute.connectors.config import (
    BotsConfig,
    DiscordConfig,
    TelegramConfig,
    load_bots_config,
)
from parachute.connectors.message_formatter import (
    claude_to_discord,
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

        connector = TestConnector(
            bot_token="test",
            server=None,
            allowed_users=[],
            dm_trust_level="vault",
            group_trust_level="sandboxed",
        )
        assert connector.get_trust_level("dm") == "vault"
        assert connector.get_trust_level("group") == "sandboxed"

    def test_status(self):
        class TestConnector(BotConnector):
            platform = "test"
            async def start(self): pass
            async def stop(self): pass
            async def on_text_message(self, update, context): pass

        connector = TestConnector(
            bot_token="test",
            server=None,
            allowed_users=[1, 2, 3],
        )
        status = connector.status
        assert status["platform"] == "test"
        assert status["running"] is False
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
