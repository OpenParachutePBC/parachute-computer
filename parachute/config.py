"""
Configuration management for Parachute server.

Loads configuration from environment variables with sensible defaults.
"""

from pathlib import Path
from typing import Optional

from pydantic import Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Server configuration loaded from environment variables."""

    # Core settings
    vault_path: Path = Field(
        default=Path("./sample-vault"),
        description="Path to the Parachute vault directory",
    )
    port: int = Field(default=3333, description="Server port")
    host: str = Field(default="0.0.0.0", description="Server bind address")

    # Security
    api_key: Optional[str] = Field(
        default=None,
        description="Optional API key for authentication (X-API-Key header)",
    )
    cors_origins: str = Field(
        default="*",
        description="Comma-separated list of allowed CORS origins, or * for all",
    )

    # Limits
    max_message_length: int = Field(
        default=102400,
        description="Maximum message length in bytes",
    )

    # Database
    db_path: Optional[Path] = Field(
        default=None,
        description="Path to SQLite database (defaults to vault/.parachute/sessions.db)",
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

    model_config = {
        "env_prefix": "",
        "env_file": ".env",
        "env_file_encoding": "utf-8",
        "extra": "ignore",
    }

    @property
    def database_path(self) -> Path:
        """Get the database path, defaulting to vault/.parachute/sessions.db"""
        if self.db_path:
            return self.db_path
        return self.vault_path / ".parachute" / "sessions.db"

    @property
    def cors_origins_list(self) -> list[str] | None:
        """Parse CORS origins into a list, or None for wildcard."""
        if self.cors_origins == "*":
            return None
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


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
