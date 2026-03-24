"""
Configuration management for Parachute server.

Precedence: env vars > .env file > config.yaml > defaults

Config file: ~/.parachute/config.yaml
Token file:  ~/.parachute/.token (separate for security)

System directory: ~/.parachute/
  - All server internals live here (graph DB, sessions, modules, etc.)
"""

import logging
import os
import re
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
    "docker_runtime", "docker_auto_start",
    "credential_broker_secret",
    "api_provider", "api_providers",
    # Legacy keys (backward compat — auto-migrated to credential_providers)
    "github_app_id", "github_broker_secret",
}


def _load_yaml_config(parachute_dir: Path) -> dict[str, Any]:
    """Load config.yaml from ~/.parachute/config.yaml."""
    config_file = parachute_dir / "config.yaml"
    if not config_file.exists():
        return {}
    try:
        with open(config_file) as f:
            data = yaml.safe_load(f) or {}
        if not isinstance(data, dict):
            logger.warning(f"config.yaml is not a dict, ignoring: {config_file}")
            return {}
        # Drop legacy keys that would cause Pydantic validation errors.
        data.pop("vault_path", None)
        return data
    except Exception as e:
        logger.warning(f"Error loading config.yaml: {e}")
        return {}


def _load_token(parachute_dir: Path) -> Optional[str]:
    """Load Claude token from ~/.parachute/.token."""
    token_file = parachute_dir / ".token"
    if not token_file.exists():
        return None
    try:
        token = token_file.read_text().strip()
        return token if token else None
    except Exception as e:
        logger.warning(f"Error reading .token: {e}")
        return None


def save_yaml_config(parachute_dir: Path, data: dict[str, Any]) -> Path:
    """Write config values to ~/.parachute/config.yaml with restricted permissions.

    Uses mkstemp + atomic rename so the file is never world-readable, even
    transiently (the temp file is created with 0o600 before rename).
    """
    import os
    import tempfile

    config_file = parachute_dir / "config.yaml"
    config_file.parent.mkdir(parents=True, exist_ok=True)

    fd, tmp_path = tempfile.mkstemp(dir=config_file.parent, suffix=".yaml.tmp")
    try:
        with os.fdopen(fd, "w") as f:
            yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, str(config_file))
    except Exception:
        Path(tmp_path).unlink(missing_ok=True)
        raise
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

            # Drop legacy keys
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

                # Restrict permissions before rename so file is never world-readable
                os.chmod(temp_path, 0o600)
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

    # Sandbox timeouts
    sandbox_timeout: int = Field(
        default=600,
        description="Overall sandbox session timeout in seconds (default: 600 = 10 min)",
    )
    sandbox_readline_timeout: int = Field(
        default=300,
        description="Per-line readline timeout inside sandbox in seconds (default: 300 = 5 min)",
    )

    # Trusted path timeouts
    trusted_event_timeout: int = Field(
        default=300,
        ge=1,
        description="Per-event timeout for trusted SDK event queue in seconds (default: 300 = 5 min)",
    )

    # Transcription
    transcription_enabled: bool = Field(
        default=True,
        description="Enable server-side transcription (requires parakeet-mlx on macOS)",
    )
    transcription_model_id: Optional[str] = Field(
        default=None,
        description="HuggingFace model ID for transcription (default: mlx-community/parakeet-tdt-0.6b-v3)",
    )

    # Development
    debug: bool = Field(default=False, description="Enable debug mode")
    reload: bool = Field(default=False, description="Enable auto-reload")

    # Model
    default_model: Optional[str] = Field(
        default=None,
        description="Optional model override. If not set, uses Claude Code default.",
    )

    # API providers (bring your own backend)
    api_provider: Optional[str] = Field(
        default=None,
        description="Active API provider name. None = Anthropic default (OAuth token).",
    )
    api_providers: dict[str, dict] = Field(
        default_factory=dict,
        description="Named API provider configs: {name: {base_url, api_key, default_model?, label?}}",
    )

    # Credential broker
    credential_providers: dict[str, dict] = Field(
        default_factory=dict,
        description="Provider configurations (github, cloudflare, etc.)",
    )
    credential_broker_secret: Optional[str] = Field(
        default=None,
        description="Bearer token for credential broker endpoint authentication",
    )

    # Legacy GitHub fields — auto-migrated to credential_providers on load
    github_app_id: Optional[int] = Field(
        default=None,
        description="[Deprecated] GitHub App ID — use credential_providers.github",
    )
    github_installations: dict[str, int] = Field(
        default_factory=dict,
        description="[Deprecated] GitHub installations — use credential_providers.github",
    )
    github_broker_secret: Optional[str] = Field(
        default=None,
        description="[Deprecated] Broker secret — use credential_broker_secret",
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

        # Auto-migrate legacy GitHub fields → credential_providers
        if data.get("github_app_id") and not data.get("credential_providers", {}).get("github"):
            providers = data.setdefault("credential_providers", {})
            providers["github"] = {
                "type": "github-app",
                "app_id": data["github_app_id"],
            }
            if data.get("github_installations"):
                providers["github"]["installations"] = data["github_installations"]

        # Migrate github_broker_secret → credential_broker_secret
        if data.get("github_broker_secret") and not data.get("credential_broker_secret"):
            data["credential_broker_secret"] = data["github_broker_secret"]

        # Migrate legacy full model IDs to short names
        # e.g., "claude-opus-4-6" → "opus", "claude-sonnet-4-6[1m]" → "sonnet[1m]"
        default_model = data.get("default_model")
        if default_model and default_model.startswith("claude-"):
            match = re.match(r'^claude-([a-z]+)-[a-z0-9\-]+(\[\d+[km]\])?$', default_model)
            if match:
                family = match.group(1)
                suffix = match.group(2) or ""
                if family in ("opus", "sonnet", "haiku"):
                    data["default_model"] = f"{family}{suffix}"
                    # Persist migration to config.yaml
                    try:
                        save_yaml_config_atomic(
                            PARACHUTE_DIR,
                            {"default_model": data["default_model"]},
                        )
                    except Exception:
                        pass  # Non-fatal: will retry next startup

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
    def active_provider_config(self) -> dict[str, str] | None:
        """Resolve the active API provider config, or None for Anthropic default."""
        if not self.api_provider:
            return None
        cfg = self.api_providers.get(self.api_provider)
        if not cfg or "base_url" not in cfg or "api_key" not in cfg:
            logger.warning(
                f"API provider '{self.api_provider}' not found or missing base_url/api_key, "
                "falling back to Anthropic default"
            )
            return None
        return cfg

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

    @property
    def github_app_pem_path(self) -> Path:
        """Path to the GitHub App private key PEM file."""
        return PARACHUTE_DIR / "github-app.pem"


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
