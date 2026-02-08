"""Tests for YAML config loading, token management, and migration."""

import os
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

from parachute.config import (
    CONFIG_KEYS,
    Settings,
    _load_token,
    _load_yaml_config,
    get_config_path,
    save_token,
    save_yaml_config,
)


@pytest.fixture
def vault(tmp_path):
    """Create a temporary vault with .parachute directory."""
    vault_path = tmp_path / "vault"
    vault_path.mkdir()
    (vault_path / ".parachute").mkdir()
    return vault_path


class TestYamlConfig:
    def test_load_empty_vault(self, vault):
        result = _load_yaml_config(vault)
        assert result == {}

    def test_save_and_load_roundtrip(self, vault):
        data = {"port": 4444, "host": "127.0.0.1", "vault_path": str(vault)}
        save_yaml_config(vault, data)
        loaded = _load_yaml_config(vault)
        assert loaded["port"] == 4444
        assert loaded["host"] == "127.0.0.1"

    def test_config_file_location(self, vault):
        path = get_config_path(vault)
        assert path == vault / ".parachute" / "config.yaml"

    def test_save_creates_parent_dirs(self, tmp_path):
        vault = tmp_path / "deep" / "vault"
        save_yaml_config(vault, {"port": 3333})
        assert (vault / ".parachute" / "config.yaml").exists()

    def test_load_invalid_yaml_returns_empty(self, vault):
        config_file = vault / ".parachute" / "config.yaml"
        config_file.write_text("[ invalid yaml {{{")
        result = _load_yaml_config(vault)
        assert result == {}

    def test_load_non_dict_yaml_returns_empty(self, vault):
        config_file = vault / ".parachute" / "config.yaml"
        config_file.write_text("- just\n- a\n- list\n")
        result = _load_yaml_config(vault)
        assert result == {}


class TestTokenManagement:
    def test_save_and_load_token(self, vault):
        save_token(vault, "sk-ant-test-token-12345")
        token = _load_token(vault)
        assert token == "sk-ant-test-token-12345"

    def test_token_file_permissions(self, vault):
        save_token(vault, "sk-ant-secret")
        token_file = vault / ".parachute" / ".token"
        mode = oct(token_file.stat().st_mode & 0o777)
        assert mode == "0o600"

    def test_load_missing_token(self, vault):
        assert _load_token(vault) is None

    def test_load_empty_token(self, vault):
        (vault / ".parachute" / ".token").write_text("")
        assert _load_token(vault) is None

    def test_token_stripped(self, vault):
        (vault / ".parachute" / ".token").write_text("  sk-ant-test  \n")
        assert _load_token(vault) == "sk-ant-test"


class TestSettingsYamlIntegration:
    """Tests that need to run in a clean directory (no .env file interference)."""

    def test_settings_loads_yaml_fallback(self, vault, tmp_path, monkeypatch):
        save_yaml_config(vault, {"port": 5555, "host": "10.0.0.1"})
        # Change to tmp_path to avoid .env in CWD being picked up
        monkeypatch.chdir(tmp_path)
        env = {"VAULT_PATH": str(vault), "PATH": os.environ.get("PATH", "")}
        with patch.dict(os.environ, env, clear=True):
            s = Settings()
            assert s.port == 5555
            assert s.host == "10.0.0.1"

    def test_env_vars_override_yaml(self, vault, tmp_path, monkeypatch):
        save_yaml_config(vault, {"port": 5555})
        monkeypatch.chdir(tmp_path)
        env = {"VAULT_PATH": str(vault), "PORT": "9999", "PATH": os.environ.get("PATH", "")}
        with patch.dict(os.environ, env, clear=True):
            s = Settings()
            assert s.port == 9999

    def test_token_loaded_from_file(self, vault, tmp_path, monkeypatch):
        save_token(vault, "sk-ant-yaml-token")
        monkeypatch.chdir(tmp_path)
        env = {"VAULT_PATH": str(vault), "PATH": os.environ.get("PATH", "")}
        with patch.dict(os.environ, env, clear=True):
            s = Settings()
            assert s.claude_code_oauth_token == "sk-ant-yaml-token"

    def test_env_token_overrides_file(self, vault, tmp_path, monkeypatch):
        save_token(vault, "sk-ant-file-token")
        monkeypatch.chdir(tmp_path)
        env = {
            "VAULT_PATH": str(vault),
            "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-env-token",
            "PATH": os.environ.get("PATH", ""),
        }
        with patch.dict(os.environ, env, clear=True):
            s = Settings()
            assert s.claude_code_oauth_token == "sk-ant-env-token"

    def test_auth_mode_field(self, vault, tmp_path, monkeypatch):
        save_yaml_config(vault, {"auth_mode": "always"})
        monkeypatch.chdir(tmp_path)
        env = {"VAULT_PATH": str(vault), "PATH": os.environ.get("PATH", "")}
        with patch.dict(os.environ, env, clear=True):
            s = Settings()
            assert s.auth_mode == "always"

    def test_config_dir_property(self, vault, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        env = {"VAULT_PATH": str(vault), "PATH": os.environ.get("PATH", "")}
        with patch.dict(os.environ, env, clear=True):
            s = Settings()
            assert s.config_dir == vault / ".parachute"

    def test_log_dir_property(self, vault, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        env = {"VAULT_PATH": str(vault), "PATH": os.environ.get("PATH", "")}
        with patch.dict(os.environ, env, clear=True):
            s = Settings()
            assert s.log_dir == vault / ".parachute" / "logs"


class TestConfigKeys:
    def test_known_keys_include_essentials(self):
        assert "vault_path" in CONFIG_KEYS
        assert "port" in CONFIG_KEYS
        assert "host" in CONFIG_KEYS
        assert "log_level" in CONFIG_KEYS
        assert "debug" in CONFIG_KEYS
