"""
Server configuration management.

Handles the server.yaml config file in the vault's .parachute directory.
"""

import logging
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import Optional

import yaml

from parachute.lib.auth import APIKey, verify_key

logger = logging.getLogger(__name__)


class AuthMode(str, Enum):
    """Authentication mode for the server."""

    ALWAYS = "always"  # All requests need auth
    REMOTE = "remote"  # Only non-localhost requests need auth (default)
    DISABLED = "disabled"  # No auth required (dev only)


@dataclass
class SecurityConfig:
    """Security configuration."""

    require_auth: AuthMode = AuthMode.REMOTE
    api_keys: list[APIKey] = field(default_factory=list)


@dataclass
class ServerSettings:
    """Server settings from config file."""

    port: int = 3333
    expose_to_tailnet: bool = False


@dataclass
class ServerConfig:
    """Complete server configuration."""

    security: SecurityConfig = field(default_factory=SecurityConfig)
    server: ServerSettings = field(default_factory=ServerSettings)

    _config_path: Optional[Path] = field(default=None, repr=False)

    def save(self) -> None:
        """Save configuration to file."""
        if not self._config_path:
            raise ValueError("Config path not set")

        data = {
            "security": {
                "require_auth": self.security.require_auth.value,
                "api_keys": [key.to_dict() for key in self.security.api_keys],
            },
            "server": {
                "port": self.server.port,
                "expose_to_tailnet": self.server.expose_to_tailnet,
            },
        }

        self._config_path.parent.mkdir(parents=True, exist_ok=True)

        with open(self._config_path, "w") as f:
            yaml.safe_dump(data, f, default_flow_style=False, sort_keys=False)

        logger.info(f"Saved server config to {self._config_path}")

    def add_api_key(self, key: APIKey) -> None:
        """Add an API key and save."""
        self.security.api_keys.append(key)
        self.save()

    def remove_api_key(self, key_id: str) -> bool:
        """Remove an API key by ID. Returns True if found and removed."""
        for i, key in enumerate(self.security.api_keys):
            if key.id == key_id:
                self.security.api_keys.pop(i)
                self.save()
                return True
        return False

    def get_api_key(self, key_id: str) -> Optional[APIKey]:
        """Get an API key by ID."""
        for key in self.security.api_keys:
            if key.id == key_id:
                return key
        return None

    def validate_key(self, provided_key: str) -> Optional[APIKey]:
        """
        Validate a provided key against stored keys.

        Returns the matching APIKey if valid, None otherwise.
        Also updates last_used_at on successful validation.
        """
        for key in self.security.api_keys:
            if verify_key(provided_key, key.key_hash):
                # Update last used timestamp
                key.last_used_at = datetime.utcnow()
                self.save()
                return key
        return None


def load_server_config(vault_path: Path) -> ServerConfig:
    """
    Load server configuration from vault.

    Args:
        vault_path: Path to the Parachute vault

    Returns:
        ServerConfig with loaded or default values
    """
    config_path = vault_path / ".parachute" / "server.yaml"

    config = ServerConfig(_config_path=config_path)

    if not config_path.exists():
        logger.info(f"No server config found at {config_path}, using defaults")
        return config

    try:
        with open(config_path) as f:
            data = yaml.safe_load(f) or {}

        # Parse security section
        if "security" in data:
            sec = data["security"]
            if "require_auth" in sec:
                config.security.require_auth = AuthMode(sec["require_auth"])
            if "api_keys" in sec:
                config.security.api_keys = [
                    APIKey.from_dict(k) for k in sec["api_keys"]
                ]

        # Parse server section
        if "server" in data:
            srv = data["server"]
            if "port" in srv:
                config.server.port = srv["port"]
            if "expose_to_tailnet" in srv:
                config.server.expose_to_tailnet = srv["expose_to_tailnet"]

        logger.info(f"Loaded server config from {config_path}")

    except Exception as e:
        logger.warning(f"Error loading server config: {e}, using defaults")

    return config


# Global config instance (initialized on server startup)
_server_config: Optional[ServerConfig] = None


def init_server_config(vault_path: Path) -> ServerConfig:
    """Initialize and return the global server config."""
    global _server_config
    _server_config = load_server_config(vault_path)
    return _server_config


def get_server_config() -> Optional[ServerConfig]:
    """Get the global server config instance."""
    return _server_config
