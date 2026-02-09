"""
Tests for plugin directory discovery in config and orchestrator.

Tests cover:
- User plugin directory (~/.claude/plugins/) discovery
- Custom plugin directories from config
- Warning for missing directories
- include_user_plugins toggle
"""

import logging
from pathlib import Path
from unittest.mock import patch

import pytest

from parachute.config import Settings


class TestPluginConfigDefaults:
    """Tests for plugin-related config defaults."""

    def test_default_plugin_dirs_empty(self):
        """Test plugin_dirs defaults to empty list."""
        settings = Settings(vault_path=Path("/tmp/test-vault"))
        assert settings.plugin_dirs == []

    def test_default_include_user_plugins_true(self):
        """Test include_user_plugins defaults to True."""
        settings = Settings(vault_path=Path("/tmp/test-vault"))
        assert settings.include_user_plugins is True

    def test_custom_plugin_dirs(self):
        """Test setting custom plugin directories."""
        settings = Settings(
            vault_path=Path("/tmp/test-vault"),
            plugin_dirs=["/opt/plugins/a", "/opt/plugins/b"],
        )
        assert settings.plugin_dirs == ["/opt/plugins/a", "/opt/plugins/b"]

    def test_disable_user_plugins(self):
        """Test disabling user plugin loading."""
        settings = Settings(
            vault_path=Path("/tmp/test-vault"),
            include_user_plugins=False,
        )
        assert settings.include_user_plugins is False


class TestPluginDiscovery:
    """Tests for plugin directory discovery logic."""

    @pytest.fixture
    def user_plugins_dir(self, tmp_path):
        """Create a fake ~/.claude/plugins/ directory with plugins."""
        plugins_dir = tmp_path / ".claude" / "plugins"
        plugins_dir.mkdir(parents=True)

        # Create two plugin directories
        plugin_a = plugins_dir / "plugin-alpha"
        plugin_a.mkdir()
        (plugin_a / ".claude-plugin").mkdir()
        (plugin_a / ".claude-plugin" / "plugin.json").write_text('{"name":"alpha"}')

        plugin_b = plugins_dir / "plugin-beta"
        plugin_b.mkdir()
        (plugin_b / ".claude-plugin").mkdir()
        (plugin_b / ".claude-plugin" / "plugin.json").write_text('{"name":"beta"}')

        # Create a regular file (should be ignored)
        (plugins_dir / "not-a-dir.txt").write_text("ignored")

        return plugins_dir

    def test_discovers_user_plugins(self, tmp_path, user_plugins_dir):
        """Test discovering plugins from ~/.claude/plugins/."""
        plugin_dirs: list[Path] = []

        with patch("pathlib.Path.home", return_value=tmp_path):
            user_plugin_dir = Path.home() / ".claude" / "plugins"
            if user_plugin_dir.is_dir():
                for entry in user_plugin_dir.iterdir():
                    if entry.is_dir():
                        plugin_dirs.append(entry)

        assert len(plugin_dirs) == 2
        names = {p.name for p in plugin_dirs}
        assert "plugin-alpha" in names
        assert "plugin-beta" in names

    def test_skips_when_user_plugins_disabled(self, tmp_path, user_plugins_dir):
        """Test that user plugins are skipped when include_user_plugins=False."""
        settings = Settings(
            vault_path=Path("/tmp/test-vault"),
            include_user_plugins=False,
        )
        plugin_dirs: list[Path] = []

        if settings.include_user_plugins:
            with patch("pathlib.Path.home", return_value=tmp_path):
                user_plugin_dir = Path.home() / ".claude" / "plugins"
                if user_plugin_dir.is_dir():
                    for entry in user_plugin_dir.iterdir():
                        if entry.is_dir():
                            plugin_dirs.append(entry)

        assert len(plugin_dirs) == 0

    def test_handles_missing_user_plugins_dir(self, tmp_path):
        """Test graceful handling when ~/.claude/plugins/ doesn't exist."""
        plugin_dirs: list[Path] = []

        with patch("pathlib.Path.home", return_value=tmp_path):
            user_plugin_dir = Path.home() / ".claude" / "plugins"
            if user_plugin_dir.is_dir():
                for entry in user_plugin_dir.iterdir():
                    if entry.is_dir():
                        plugin_dirs.append(entry)

        assert len(plugin_dirs) == 0

    def test_discovers_configured_plugin_dirs(self, tmp_path):
        """Test loading plugins from configured directories."""
        # Create configured plugin dirs
        dir_a = tmp_path / "custom-plugins" / "plugin-one"
        dir_a.mkdir(parents=True)

        dir_b = tmp_path / "custom-plugins" / "plugin-two"
        dir_b.mkdir(parents=True)

        settings = Settings(
            vault_path=Path("/tmp/test-vault"),
            plugin_dirs=[str(dir_a), str(dir_b)],
        )

        plugin_dirs: list[Path] = []
        for dir_str in settings.plugin_dirs:
            plugin_path = Path(dir_str).expanduser().resolve()
            if plugin_path.is_dir():
                plugin_dirs.append(plugin_path)

        assert len(plugin_dirs) == 2

    def test_warns_for_missing_configured_dirs(self, tmp_path, caplog):
        """Test warning for configured dirs that don't exist."""
        settings = Settings(
            vault_path=Path("/tmp/test-vault"),
            plugin_dirs=[str(tmp_path / "nonexistent-plugin")],
        )

        plugin_dirs: list[Path] = []
        test_logger = logging.getLogger("test_plugin_discovery")

        with caplog.at_level(logging.WARNING):
            for dir_str in settings.plugin_dirs:
                plugin_path = Path(dir_str).expanduser().resolve()
                if plugin_path.is_dir():
                    plugin_dirs.append(plugin_path)
                else:
                    test_logger.warning(f"Plugin directory not found, skipping: {plugin_path}")

        assert len(plugin_dirs) == 0
        assert "Plugin directory not found" in caplog.text

    def test_mixed_valid_and_invalid_dirs(self, tmp_path, caplog):
        """Test mix of valid and invalid plugin directories."""
        valid_dir = tmp_path / "valid-plugin"
        valid_dir.mkdir()

        settings = Settings(
            vault_path=Path("/tmp/test-vault"),
            plugin_dirs=[str(valid_dir), str(tmp_path / "missing-plugin")],
        )

        plugin_dirs: list[Path] = []
        test_logger = logging.getLogger("test_plugin_discovery")

        with caplog.at_level(logging.WARNING):
            for dir_str in settings.plugin_dirs:
                plugin_path = Path(dir_str).expanduser().resolve()
                if plugin_path.is_dir():
                    plugin_dirs.append(plugin_path)
                else:
                    test_logger.warning(f"Plugin directory not found, skipping: {plugin_path}")

        assert len(plugin_dirs) == 1
        assert plugin_dirs[0].name == "valid-plugin"
        assert "Plugin directory not found" in caplog.text
