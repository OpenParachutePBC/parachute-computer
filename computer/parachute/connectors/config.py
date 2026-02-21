"""
Bot connector configuration.

Loads bot settings from vault/.parachute/bots.yaml.
"""

import logging
from pathlib import Path
from typing import Literal, Optional

import yaml
from pydantic import BaseModel, Field, field_validator

from parachute.core.trust import TrustLevelStr, normalize_trust_level

logger = logging.getLogger(__name__)


class TelegramConfig(BaseModel):
    """Telegram bot configuration."""

    enabled: bool = False
    bot_token: str = ""
    allowed_users: list[int] = Field(default_factory=list)
    default_trust_level: TrustLevelStr = "sandboxed"
    dm_trust_level: TrustLevelStr = "sandboxed"
    group_trust_level: TrustLevelStr = "sandboxed"
    group_mention_mode: Literal["mention_only", "all_messages"] = "mention_only"
    ack_emoji: Optional[str] = "👀"

    @field_validator("default_trust_level", "dm_trust_level", "group_trust_level", mode="before")
    @classmethod
    def normalize_trust(cls, v: str) -> str:
        return normalize_trust_level(v)


class DiscordConfig(BaseModel):
    """Discord bot configuration."""

    enabled: bool = False
    bot_token: str = ""
    allowed_users: list[str] = Field(default_factory=list)
    default_trust_level: TrustLevelStr = "sandboxed"
    dm_trust_level: TrustLevelStr = "sandboxed"
    group_trust_level: TrustLevelStr = "sandboxed"
    group_mention_mode: Literal["mention_only", "all_messages"] = "mention_only"
    ack_emoji: Optional[str] = "👀"

    @field_validator("default_trust_level", "dm_trust_level", "group_trust_level", mode="before")
    @classmethod
    def normalize_trust(cls, v: str) -> str:
        return normalize_trust_level(v)


class MatrixConfig(BaseModel):
    """Matrix bot configuration."""

    enabled: bool = False
    homeserver_url: str = ""
    user_id: str = ""
    access_token: str = ""
    device_id: str = "PARACHUTE01"
    allowed_rooms: list[str] = Field(default_factory=list)
    default_trust_level: TrustLevelStr = "sandboxed"
    dm_trust_level: TrustLevelStr = "sandboxed"
    group_trust_level: TrustLevelStr = "sandboxed"
    group_mention_mode: Literal["mention_only", "all_messages"] = "mention_only"
    ack_emoji: Optional[str] = "👀"

    @field_validator("default_trust_level", "dm_trust_level", "group_trust_level", mode="before")
    @classmethod
    def normalize_trust(cls, v: str) -> str:
        return normalize_trust_level(v)


class BotsConfig(BaseModel):
    """Top-level bot connector configuration."""

    telegram: TelegramConfig = Field(default_factory=TelegramConfig)
    discord: DiscordConfig = Field(default_factory=DiscordConfig)
    matrix: MatrixConfig = Field(default_factory=MatrixConfig)


def load_bots_config(vault_path: Path) -> BotsConfig:
    """Load bot configuration from vault/.parachute/bots.yaml."""
    config_path = vault_path / ".parachute" / "bots.yaml"

    if not config_path.exists():
        logger.info("No bots.yaml found, bot connectors disabled")
        return BotsConfig()

    try:
        with open(config_path) as f:
            raw = yaml.safe_load(f) or {}
        config = BotsConfig(**raw)
        logger.info(
            f"Loaded bots config: telegram={config.telegram.enabled}, "
            f"discord={config.discord.enabled}, "
            f"matrix={config.matrix.enabled}"
        )
        return config
    except Exception as e:
        logger.error(f"Failed to load bots.yaml: {e}")
        return BotsConfig()
