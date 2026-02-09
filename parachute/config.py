"""
Configuration management for Parachute server.

Precedence: env vars > .env file > config.yaml > defaults

Config file: vault/.parachute/config.yaml
Token file:  vault/.parachute/.token (separate for security)
"""

import logging
import os
from pathlib import Path
from typing import Any, Optional

import yaml
from pydantic import Field, model_validator
from pydantic_settings import BaseSettings

logger = logging.getLogger(__name__)

# Known config keys that can be set via `parachute config set`
CONFIG_KEYS = {
    "vault_path", "port", "host", "default_model", "log_level",
    "cors_origins", "auth_mode", "debug",
}


def _resolve_vault_path() -> Path:
    """Resolve vault path from env or default, before Settings init."""
    raw = os.environ.get("VAULT_PATH", "")
    if raw:
        return Path(raw).expanduser().resolve()
    # Check .env in CWD for backward compat
    env_file = Path.cwd() / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if line.startswith("VAULT_PATH="):
                val = line.split("=", 1)[1].strip()
                return Path(val).expanduser().resolve()
    return Path("./sample-vault").resolve()


def _load_yaml_config(vault_path: Path) -> dict[str, Any]:
    """Load config.yaml from vault/.parachute/config.yaml."""
    config_file = vault_path / ".parachute" / "config.yaml"
    if not config_file.exists():
        return {}
    try:
        with open(config_file) as f:
            data = yaml.safe_load(f) or {}
        if not isinstance(data, dict):
            logger.warning(f"config.yaml is not a dict, ignoring: {config_file}")
            return {}
        return data
    except Exception as e:
        logger.warning(f"Error loading config.yaml: {e}")
        return {}


def _load_token(vault_path: Path) -> Optional[str]:
    """Load Claude token from vault/.parachute/.token."""
    token_file = vault_path / ".parachute" / ".token"
    if not token_file.exists():
        return None
    try:
        token = token_file.read_text().strip()
        return token if token else None
    except Exception as e:
        logger.warning(f"Error reading .token: {e}")
        return None


def save_yaml_config(vault_path: Path, data: dict[str, Any]) -> Path:
    """Write config values to vault/.parachute/config.yaml."""
    config_file = vault_path / ".parachute" / "config.yaml"
    config_file.parent.mkdir(parents=True, exist_ok=True)
    with open(config_file, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
    return config_file


def save_token(vault_path: Path, token: str) -> Path:
    """Write token to vault/.parachute/.token with restricted permissions."""
    token_file = vault_path / ".parachute" / ".token"
    token_file.parent.mkdir(parents=True, exist_ok=True)
    token_file.write_text(token + "\n")
    token_file.chmod(0o600)
    return token_file


def get_config_path(vault_path: Path) -> Path:
    """Get the config.yaml path for a vault."""
    return vault_path / ".parachute" / "config.yaml"


class Settings(BaseSettings):
    """Server configuration. Precedence: env vars > .env > config.yaml > defaults."""

    # Core settings
    vault_path: Path = Field(
        default=Path("./sample-vault"),
        description="Path to the Parachute vault directory",
    )
    port: int = Field(default=3333, description="Server port")
    host: str = Field(default="0.0.0.0", description="Server bind address")

    # Claude authentication
    claude_code_oauth_token: Optional[str] = Field(
        default=None,
        description="Long-lived OAuth token from `claude setup-token` (CLAUDE_CODE_OAUTH_TOKEN)",
    )

    # Security
    api_key: Optional[str] = Field(
        default=None,
        description="Optional API key for authentication (X-API-Key header)",
    )
    cors_origins: str = Field(
        default="*",
        description="Comma-separated list of allowed CORS origins, or * for all",
    )
    auth_mode: str = Field(
        default="remote",
        description="Authentication mode: remote | always | disabled",
    )

    # Limits
    max_message_length: int = Field(
        default=102400,
        description="Maximum message length in bytes",
    )

    # Database
    db_path: Optional[Path] = Field(
        default=None,
        description="Path to SQLite database (defaults to vault/Chat/sessions.db)",
    )

    # Logging
    log_level: str = Field(default="INFO", description="Log level")
    log_format: str = Field(
        default="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        description="Log format string",
    )

    # Development
    debug: bool = Field(default=False, description="Enable debug mode")
    reload: bool = Field(default=False, description="Enable auto-reload")

    # Model
    default_model: Optional[str] = Field(
        default=None,
        description="Optional model override. If not set, uses Claude Code default.",
    )

    model_config = {
        "env_prefix": "",
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }

    @model_validator(mode="before")
    @classmethod
    def _inject_yaml_config(cls, data: Any) -> Any:
        """Inject config.yaml values as fallbacks below env vars and .env."""
        if not isinstance(data, dict):
            data = {}

        # Resolve vault path to find config.yaml
        vault_path = _resolve_vault_path()

        # Load YAML config
        yaml_config = _load_yaml_config(vault_path)

        # Inject YAML values only where not already set (env/explicit take priority)
        for key, value in yaml_config.items():
            if key not in data or data[key] is None:
                # Don't override if env var is set
                env_val = os.environ.get(key.upper()) or os.environ.get(key)
                if env_val is None:
                    data[key] = value

        # Load token from .token file if not already set
        if not data.get("claude_code_oauth_token"):
            env_token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN")
            if not env_token:
                token = _load_token(vault_path)
                if token:
                    data["claude_code_oauth_token"] = token

        return data

    @property
    def database_path(self) -> Path:
        """Get the database path, defaulting to vault/Chat/sessions.db"""
        if self.db_path:
            return self.db_path
        return self.vault_path / "Chat" / "sessions.db"

    @property
    def cors_origins_list(self) -> list[str] | None:
        """Parse CORS origins into a list, or None for wildcard."""
        if self.cors_origins == "*":
            return None
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def config_dir(self) -> Path:
        """Get the .parachute config directory path."""
        return self.vault_path / ".parachute"

    @property
    def log_dir(self) -> Path:
        """Get the daemon log directory path."""
        return self.config_dir / "logs"


# Global settings instance
settings = Settings()


def get_settings() -> Settings:
    """Get the global settings instance."""
    return settings


def reload_settings() -> Settings:
    """Reload settings from environment."""
    global settings
    settings = Settings()
    return settings
