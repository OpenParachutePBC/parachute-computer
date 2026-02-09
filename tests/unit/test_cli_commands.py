"""Tests for CLI commands (config, doctor, migration)."""

import os
from pathlib import Path
from unittest.mock import patch

import pytest
import yaml

from parachute.cli import (
    _config_get,
    _config_set,
    _config_show,
    _migrate_env_to_yaml,
    _migrate_server_yaml,
)
from parachute.config import _load_yaml_config, _load_token, save_yaml_config, save_token


@pytest.fixture
def vault(tmp_path):
    vault_path = tmp_path / "vault"
    vault_path.mkdir()
    (vault_path / ".parachute").mkdir()
    return vault_path


class TestMigrateEnvToYaml:
    def test_migrates_env_values(self, vault, tmp_path):
        env_file = tmp_path / ".env"
        env_file.write_text(
            "VAULT_PATH=/my/vault\nPORT=4444\nCLAUDE_CODE_OAUTH_TOKEN=sk-test-123\n"
        )

        with patch("parachute.cli._get_env_file", return_value=env_file):
            result = _migrate_env_to_yaml(vault)

        assert result is True
        config = _load_yaml_config(vault)
        assert config["port"] == 4444
        assert config["vault_path"] == "/my/vault"

        # Token should be in .token file
        token = _load_token(vault)
        assert token == "sk-test-123"

        # .env renamed
        assert not env_file.exists()
        assert (tmp_path / ".env.migrated").exists()

    def test_no_env_file_returns_false(self, vault, tmp_path):
        env_file = tmp_path / ".env"
        with patch("parachute.cli._get_env_file", return_value=env_file):
            result = _migrate_env_to_yaml(vault)
        assert result is False

    def test_empty_env_returns_false(self, vault, tmp_path):
        env_file = tmp_path / ".env"
        env_file.write_text("")
        with patch("parachute.cli._get_env_file", return_value=env_file):
            result = _migrate_env_to_yaml(vault)
        assert result is False

    def test_doesnt_overwrite_existing_yaml_values(self, vault, tmp_path):
        save_yaml_config(vault, {"port": 9999})

        env_file = tmp_path / ".env"
        env_file.write_text("PORT=4444\nHOST=0.0.0.0\n")

        with patch("parachute.cli._get_env_file", return_value=env_file):
            _migrate_env_to_yaml(vault)

        config = _load_yaml_config(vault)
        assert config["port"] == 9999  # Not overwritten
        assert config["host"] == "0.0.0.0"  # New key added

    def test_converts_port_to_int(self, vault, tmp_path):
        env_file = tmp_path / ".env"
        env_file.write_text("PORT=5555\n")

        with patch("parachute.cli._get_env_file", return_value=env_file):
            _migrate_env_to_yaml(vault)

        config = _load_yaml_config(vault)
        assert isinstance(config["port"], int)

    def test_converts_debug_to_bool(self, vault, tmp_path):
        env_file = tmp_path / ".env"
        env_file.write_text("DEBUG=true\n")

        with patch("parachute.cli._get_env_file", return_value=env_file):
            _migrate_env_to_yaml(vault)

        config = _load_yaml_config(vault)
        assert config["debug"] is True


class TestMigrateServerYaml:
    def test_migrates_auth_mode(self, vault):
        server_yaml = vault / ".parachute" / "server.yaml"
        server_yaml.write_text(
            yaml.dump({"security": {"require_auth": "always"}, "server": {"port": 5555}})
        )

        result = _migrate_server_yaml(vault)
        assert result is True

        config = _load_yaml_config(vault)
        assert config["auth_mode"] == "always"
        assert config["port"] == 5555

    def test_no_server_yaml_returns_false(self, vault):
        result = _migrate_server_yaml(vault)
        assert result is False

    def test_doesnt_overwrite_existing_values(self, vault):
        save_yaml_config(vault, {"auth_mode": "disabled"})

        server_yaml = vault / ".parachute" / "server.yaml"
        server_yaml.write_text(yaml.dump({"security": {"require_auth": "always"}}))

        _migrate_server_yaml(vault)

        config = _load_yaml_config(vault)
        assert config["auth_mode"] == "disabled"  # Not overwritten


class TestConfigSetGet:
    def test_set_and_get_port(self, vault, capsys):
        with patch("parachute.cli._get_vault_path", return_value=vault):
            with patch.dict(os.environ, {}, clear=False):
                # Remove PORT from env if present
                os.environ.pop("PORT", None)
                _config_set("port", "7777")
                _config_get("port")

        out = capsys.readouterr().out
        assert "7777" in out

    def test_set_rejects_unknown_key(self, vault):
        with patch("parachute.cli._get_vault_path", return_value=vault):
            with pytest.raises(SystemExit):
                _config_set("unknown_key", "value")

    def test_set_rejects_token(self, vault):
        with patch("parachute.cli._get_vault_path", return_value=vault):
            with pytest.raises(SystemExit):
                _config_set("token", "sk-secret")

    def test_set_converts_port_to_int(self, vault):
        with patch("parachute.cli._get_vault_path", return_value=vault):
            _config_set("port", "8888")
        config = _load_yaml_config(vault)
        assert isinstance(config["port"], int)

    def test_set_rejects_non_numeric_port(self, vault):
        with patch("parachute.cli._get_vault_path", return_value=vault):
            with pytest.raises(SystemExit):
                _config_set("port", "not-a-number")

    def test_get_env_override(self, vault, capsys):
        save_yaml_config(vault, {"port": 3333})
        with patch("parachute.cli._get_vault_path", return_value=vault):
            with patch.dict(os.environ, {"PORT": "9999"}):
                _config_get("port")
        out = capsys.readouterr().out
        assert "9999" in out

    def test_get_nonexistent_key(self, vault):
        with patch("parachute.cli._get_vault_path", return_value=vault):
            with pytest.raises(SystemExit):
                _config_get("nonexistent")

    def test_show_empty_config(self, vault, capsys):
        with patch("parachute.cli._get_vault_path", return_value=vault):
            _config_show()
        out = capsys.readouterr().out
        assert "empty" in out

    def test_show_with_values(self, vault, capsys):
        save_yaml_config(vault, {"port": 3333, "host": "0.0.0.0"})
        with patch("parachute.cli._get_vault_path", return_value=vault):
            _config_show()
        out = capsys.readouterr().out
        assert "3333" in out
        assert "0.0.0.0" in out
