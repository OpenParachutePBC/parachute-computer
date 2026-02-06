"""
Bot connector API endpoints.

Provides status and configuration endpoints for Telegram/Discord
bot connectors.
"""

import logging
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException

from parachute.connectors.config import BotsConfig, load_bots_config

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/bots", tags=["bots"])

# Module-level state (set during server startup)
_vault_path: Path | None = None
_connectors: dict[str, Any] = {}


def init_bots_api(vault_path: Path, connectors: dict[str, Any] | None = None) -> None:
    """Initialize bots API with vault path and active connectors."""
    global _vault_path, _connectors
    _vault_path = vault_path
    _connectors = connectors or {}


@router.get("/status")
async def bots_status():
    """Get status of all bot connectors."""
    if not _vault_path:
        return {"configured": False, "connectors": {}}

    config = load_bots_config(_vault_path)

    status = {
        "configured": True,
        "connectors": {
            "telegram": {
                "enabled": config.telegram.enabled,
                "has_token": bool(config.telegram.bot_token),
                "allowed_users_count": len(config.telegram.allowed_users),
                "running": "telegram" in _connectors and _connectors["telegram"]._running,
            },
            "discord": {
                "enabled": config.discord.enabled,
                "has_token": bool(config.discord.bot_token),
                "allowed_guilds_count": len(config.discord.allowed_guilds),
                "running": "discord" in _connectors and _connectors["discord"]._running,
            },
        },
    }

    return status


@router.get("/config")
async def bots_config():
    """Get bot configuration (tokens masked)."""
    if not _vault_path:
        return {"telegram": {}, "discord": {}}

    config = load_bots_config(_vault_path)

    return {
        "telegram": {
            "enabled": config.telegram.enabled,
            "has_token": bool(config.telegram.bot_token),
            "allowed_users": config.telegram.allowed_users,
            "dm_trust_level": config.telegram.dm_trust_level,
            "group_trust_level": config.telegram.group_trust_level,
        },
        "discord": {
            "enabled": config.discord.enabled,
            "has_token": bool(config.discord.bot_token),
            "allowed_guilds": config.discord.allowed_guilds,
            "dm_trust_level": config.discord.dm_trust_level,
            "group_trust_level": config.discord.group_trust_level,
        },
    }


@router.post("/telegram/test")
async def test_telegram():
    """Test Telegram bot connection."""
    if not _vault_path:
        raise HTTPException(status_code=400, detail="Server not configured")

    config = load_bots_config(_vault_path)
    if not config.telegram.enabled or not config.telegram.bot_token:
        raise HTTPException(status_code=400, detail="Telegram not configured")

    try:
        from parachute.connectors.telegram import TELEGRAM_AVAILABLE

        if not TELEGRAM_AVAILABLE:
            return {
                "success": False,
                "error": "python-telegram-bot not installed",
            }

        from telegram import Bot

        bot = Bot(token=config.telegram.bot_token)
        me = await bot.get_me()
        return {
            "success": True,
            "bot_name": me.first_name,
            "bot_username": me.username,
        }
    except Exception as e:
        return {"success": False, "error": str(e)}


@router.post("/discord/test")
async def test_discord():
    """Test Discord bot connection (validates token only)."""
    if not _vault_path:
        raise HTTPException(status_code=400, detail="Server not configured")

    config = load_bots_config(_vault_path)
    if not config.discord.enabled or not config.discord.bot_token:
        raise HTTPException(status_code=400, detail="Discord not configured")

    try:
        from parachute.connectors.discord_bot import DISCORD_AVAILABLE

        if not DISCORD_AVAILABLE:
            return {
                "success": False,
                "error": "discord.py not installed",
            }

        # Basic token validation - try to get gateway info
        import aiohttp

        async with aiohttp.ClientSession() as session:
            headers = {"Authorization": f"Bot {config.discord.bot_token}"}
            async with session.get(
                "https://discord.com/api/v10/users/@me", headers=headers
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return {
                        "success": True,
                        "bot_name": data.get("username"),
                        "bot_id": data.get("id"),
                    }
                return {"success": False, "error": f"HTTP {resp.status}"}
    except Exception as e:
        return {"success": False, "error": str(e)}
