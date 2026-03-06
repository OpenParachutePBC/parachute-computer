"""
Configuration management for Parachute server.

Precedence: env vars > .env file > config.yaml > defaults

Config file: ~/.parachute/config.yaml
Token file:  ~/.parachute/.token (separate for security)

System directory: ~/.parachute/
  - All server internals live here (graph DB, sessions, modules, etc.)
  - No more ~/Parachute vault — the user's home dir is the filesystem root
"""

import logging
import os
from pathlib import Path
from typing import Any, Optional

import yaml
from pydantic import Field, model_validator
from pydantic_settings import BaseSettings

logger = logging.getLogger(__name__)

# The Parachute system directory — always ~/.parachute/
PARACHUTE_DIR = Path.home() / ".parachute"

# Known config keys that can be set via `parachute config set`
CONFIG_KEYS = {
    "port", "host", "default_model", "log_level",
    "cors_origins", "auth_mode", "debug",
}


def _load_yaml_config(parachute_dir: Path) -> dict[str, Any]:
    """Load config.yaml from ~/.parachute/config.yaml."""
    config_file = parachute_dir / "config.yaml"
    if not config_file.exists():
        # Fallback: check legacy location ~/Parachute/.parachute/config.yaml
        legacy = Path.home() / "Parachute" / ".parachute" / "config.yaml"
        if legacy.exists():
            config_file = legacy
        else:
            return {}
    try:
        with open(config_file) as f:
            data = yaml.safe_load(f) or {}
        if not isinstance(data, dict):
            logger.warning(f"config.yaml is not a dict, ignoring: {config_file}")
            return {}
        # Drop vault_path — no longer a valid config key
        data.pop("vault_path", None)
        return data
    except Exception as e:
        logger.warning(f"Error loading config.yaml: {e}")
        return {}


def _load_token(parachute_dir: Path) -> Optional[str]:
    """Load Claude token from ~/.parachute/.token."""
    token_file = parachute_dir / ".token"
    if not token_file.exists():
        # Fallback: legacy location
        token_file = Path.home() / "Parachute" / ".parachute" / ".token"
        if not token_file.exists():
            return None
    try:
        token = token_file.read_text().strip()
        return token if token else None
    except Exception as e:
        logger.warning(f"Error reading .token: {e}")
        return None


def save_yaml_config(parachute_dir: Path, data: dict[str, Any]) -> Path:
    """Write config values to ~/.parachute/config.yaml."""
    config_file = parachute_dir / "config.yaml"
    config_file.parent.mkdir(parents=True, exist_ok=True)
    with open(config_file, "w") as f:
        yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
    return config_file


def save_yaml_config_atomic(parachute_dir: Path, updates: dict[str, Any]) -> Path:
    """
    Atomically update config.yaml with file locking.

    ARCHITECTURE: Prevents race conditions from concurrent writes
    (supervisor API, CLI tool, potential server writes).

    Pattern:
    1. Acquire exclusive lock on .config.lock
    2. Read current config
    3. Merge updates
    4. Write to temp file
    5. Atomic rename
    6. Release lock
    """
    import fcntl
    import tempfile

    config_file = parachute_dir / "config.yaml"
    lock_file = parachute_dir / ".config.lock"

    config_file.parent.mkdir(parents=True, exist_ok=True)

    with open(lock_file, 'w') as lock:
        # Acquire exclusive lock (blocks if another process is writing)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)

        try:
            # Read current config
            current = {}
            if config_file.exists():
                with open(config_file) as f:
                    current = yaml.safe_load(f) or {}

            # Drop vault_path if present (legacy)
            updates.pop("vault_path", None)
            current.pop("vault_path", None)

            # Merge updates
            current.update(updates)

            # Write to temp file
            fd, temp_path = tempfile.mkstemp(
                dir=config_file.parent,
                prefix=".config-",
                suffix=".yaml.tmp"
            )
            try:
                with os.fdopen(fd, "w") as f:
                    yaml.safe_dump(current, f, default_flow_style=False, sort_keys=False)

                # Atomic rename (POSIX guarantee)
                os.replace(temp_path, config_file)
            except Exception:
                # Clean up temp file on error
                Path(temp_path).unlink(missing_ok=True)
                raise
        finally:
            # Release lock
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    return config_file


def save_token(parachute_dir: Path, token: str) -> Path:
    """Write token to ~/.parachute/.token with restricted permissions."""
    token_file = parachute_dir / ".token"
    token_file.parent.mkdir(parents=True, exist_ok=True)
    token_file.write_text(token + "\n")
    token_file.chmod(0o600)
    return token_file


def get_config_path(parachute_dir: Path) -> Path:
    """Get the config.yaml path."""
    return parachute_dir / "config.yaml"


class Settings(BaseSettings):
    """Server configuration. Precedence: env vars > .env > config.yaml > defaults."""

    # Core settings — parachute_dir is always ~/.parachute/, not configurable
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

    # Logging
    log_level: str = Field(default="INFO", description="Log level")
    log_format: str = Field(
        default="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        description="Log format string",
    )

    # Plugins
    plugin_dirs: list[str] = Field(
        default_factory=list,
        description="Additional plugin directories to load",
    )
    include_user_plugins: bool = Field(
        default=True,
        description="Load plugins from ~/.claude/plugins/",
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

        # Load YAML config from ~/.parachute/config.yaml
        yaml_config = _load_yaml_config(PARACHUTE_DIR)

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
                token = _load_token(PARACHUTE_DIR)
                if token:
                    data["claude_code_oauth_token"] = token

        return data

    @property
    def parachute_dir(self) -> Path:
        """The Parachute system directory. Always ~/.parachute/."""
        return PARACHUTE_DIR

    @property
    def brain_db_path(self) -> Path:
        """Path to the Kuzu brain database."""
        return PARACHUTE_DIR / "graph" / "parachute.kz"

    @property
    def sessions_dir(self) -> Path:
        """Path to SDK JSONL transcript storage."""
        return PARACHUTE_DIR / "sessions"

    @property
    def modules_dir(self) -> Path:
        """Path to user-installed vault modules."""
        return PARACHUTE_DIR / "modules"

    @property
    def sandbox_dir(self) -> Path:
        """Path to Docker sandbox env homes."""
        return PARACHUTE_DIR / "sandbox"

    @property
    def cors_origins_list(self) -> list[str] | None:
        """Parse CORS origins into a list, or None for wildcard."""
        if self.cors_origins == "*":
            return None
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def log_dir(self) -> Path:
        """Get the daemon log directory path."""
        return PARACHUTE_DIR / "logs"


# Global settings instance (lazy-initialized so CLI can set env vars first)
_settings: Optional[Settings] = None


def get_settings() -> Settings:
    """Get the global settings instance (lazy-initialized on first call)."""
    global _settings
    if _settings is None:
        _settings = Settings()
    return _settings


def reload_settings() -> Settings:
    """Reload settings from environment."""
    global _settings
    _settings = Settings()
    return _settings
