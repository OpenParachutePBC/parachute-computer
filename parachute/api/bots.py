"""
Bot connector API endpoints.

Provides status and configuration endpoints for Telegram/Discord
bot connectors.
"""

import asyncio
import logging
from pathlib import Path
from typing import Any, Optional

import yaml
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from parachute.connectors.config import BotsConfig, TelegramConfig, DiscordConfig, TrustLevelStr, load_bots_config


class PairingApproval(BaseModel):
    """Request body for approving a pairing request."""
    trust_level: TrustLevelStr = "vault"


class TelegramConfigUpdate(BaseModel):
    """Partial update for Telegram bot config."""
    enabled: Optional[bool] = None
    bot_token: Optional[str] = None
    allowed_users: Optional[list[int]] = None
    dm_trust_level: Optional[TrustLevelStr] = None
    group_trust_level: Optional[TrustLevelStr] = None


class DiscordConfigUpdate(BaseModel):
    """Partial update for Discord bot config."""
    enabled: Optional[bool] = None
    bot_token: Optional[str] = None
    allowed_users: Optional[list[str]] = None
    allowed_guilds: Optional[list[str]] = None
    dm_trust_level: Optional[TrustLevelStr] = None
    group_trust_level: Optional[TrustLevelStr] = None


class BotsConfigUpdate(BaseModel):
    """Request body for PUT /bots/config."""
    telegram: Optional[TelegramConfigUpdate] = None
    discord: Optional[DiscordConfigUpdate] = None

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/bots", tags=["bots"])

# Module-level state (set during server startup)
_vault_path: Path | None = None
_connectors: dict[str, Any] = {}
_server_ref: Any = None  # Server-like object with .database for connector sessions
_config_lock = asyncio.Lock()  # Serialize writes to bots.yaml


def init_bots_api(vault_path: Path, connectors: dict[str, Any] | None = None, server_ref: Any = None) -> None:
    """Initialize bots API with vault path and active connectors."""
    global _vault_path, _connectors, _server_ref
    _vault_path = vault_path
    _connectors = connectors or {}
    _server_ref = server_ref


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


@router.put("/config")
async def update_bots_config(body: BotsConfigUpdate):
    """Update bot configuration. Preserves existing tokens if not provided."""
    if not _vault_path:
        raise HTTPException(status_code=400, detail="Server not configured")

    async with _config_lock:
        existing = load_bots_config(_vault_path)

        # Merge telegram config
        tg = body.telegram.model_dump(exclude_none=True) if body.telegram else {}
        tg_token = tg.get("bot_token", "")
        if not tg_token and existing.telegram.bot_token:
            tg["bot_token"] = existing.telegram.bot_token  # Preserve existing

        # Merge discord config
        dc = body.discord.model_dump(exclude_none=True) if body.discord else {}
        dc_token = dc.get("bot_token", "")
        if not dc_token and existing.discord.bot_token:
            dc["bot_token"] = existing.discord.bot_token

        # Validate with pydantic
        new_config = BotsConfig(
            telegram=TelegramConfig(**{**existing.telegram.model_dump(), **tg}),
            discord=DiscordConfig(**{**existing.discord.model_dump(), **dc}),
        )

        _write_bots_config(new_config)

    # Restart affected running connectors outside the lock
    for platform in ("telegram", "discord"):
        update = getattr(body, platform, None)
        if update and platform in _connectors:
            logger.info(f"Config changed for {platform}, restarting connector")
            try:
                await _stop_platform(platform)
                await _start_platform(platform)
            except Exception as e:
                logger.error(f"Failed to restart {platform} after config change: {e}")

    # Return masked config (reuse existing endpoint logic)
    return await bots_config()


def _write_bots_config(config: BotsConfig) -> None:
    """Write bots config to YAML with restrictive permissions."""
    import os
    config_path = _vault_path / ".parachute" / "bots.yaml"
    config_path.parent.mkdir(parents=True, exist_ok=True)
    with open(config_path, "w") as f:
        yaml.safe_dump(config.model_dump(), f, default_flow_style=False)
    os.chmod(config_path, 0o600)


async def _stop_platform(platform: str) -> None:
    """Stop a running connector. No-op if not running."""
    connector = _connectors.get(platform)
    if not connector:
        return
    try:
        await connector.stop()
    except Exception as e:
        logger.warning(f"Error stopping {platform} connector: {e}")
    _connectors.pop(platform, None)


async def _start_platform(platform: str) -> None:
    """Start a connector for the given platform. Raises on failure."""
    config = load_bots_config(_vault_path)
    platform_config = getattr(config, platform)

    if platform == "telegram":
        from parachute.connectors.telegram import TelegramConnector, TELEGRAM_AVAILABLE
        if not TELEGRAM_AVAILABLE:
            raise RuntimeError("python-telegram-bot not installed")
        connector = TelegramConnector(
            bot_token=platform_config.bot_token,
            server=_server_ref,
            allowed_users=platform_config.allowed_users,
            dm_trust_level=platform_config.dm_trust_level,
            group_trust_level=platform_config.group_trust_level,
            group_mention_mode=platform_config.group_mention_mode,
        )
    else:
        from parachute.connectors.discord_bot import DiscordConnector, DISCORD_AVAILABLE
        if not DISCORD_AVAILABLE:
            raise RuntimeError("discord.py not installed")
        connector = DiscordConnector(
            bot_token=platform_config.bot_token,
            server=_server_ref,
            allowed_users=platform_config.allowed_users,
            dm_trust_level=platform_config.dm_trust_level,
            group_trust_level=platform_config.group_trust_level,
            group_mention_mode=platform_config.group_mention_mode,
        )

    def _on_connector_error(task: asyncio.Task) -> None:
        if task.cancelled():
            return
        exc = task.exception()
        if exc:
            logger.error(f"{platform} connector crashed: {exc}")
            _connectors.pop(platform, None)

    task = asyncio.create_task(connector.start())
    task.add_done_callback(_on_connector_error)
    _connectors[platform] = connector


async def auto_start_connectors() -> None:
    """Start enabled connectors with valid tokens. Errors are logged, not raised."""
    if not _vault_path:
        return

    config = load_bots_config(_vault_path)
    for platform in ("telegram", "discord"):
        cfg = getattr(config, platform)
        if cfg.enabled and cfg.bot_token:
            try:
                await _start_platform(platform)
                logger.info(f"Auto-started {platform} connector")
            except Exception as e:
                logger.error(f"Failed to auto-start {platform}: {e}")


@router.post("/{platform}/start")
async def start_connector(platform: str):
    """Start a bot connector."""
    if platform not in ("telegram", "discord"):
        raise HTTPException(status_code=400, detail=f"Unknown platform: {platform}")
    if not _vault_path:
        raise HTTPException(status_code=400, detail="Server not configured")
    if platform in _connectors and _connectors[platform]._running:
        raise HTTPException(status_code=409, detail=f"{platform} connector already running")

    config = load_bots_config(_vault_path)
    platform_config = getattr(config, platform)

    if not platform_config.bot_token:
        raise HTTPException(status_code=400, detail=f"{platform} bot token not configured")

    try:
        await _start_platform(platform)
        return {"success": True, "message": f"{platform} connector started"}
    except Exception as e:
        logger.error(f"Failed to start {platform} connector: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/{platform}/stop")
async def stop_connector(platform: str):
    """Stop a bot connector."""
    if platform not in ("telegram", "discord"):
        raise HTTPException(status_code=400, detail=f"Unknown platform: {platform}")

    if platform not in _connectors:
        return {"success": True, "message": f"{platform} connector not running"}

    try:
        await _stop_platform(platform)
        return {"success": True, "message": f"{platform} connector stopped"}
    except Exception as e:
        logger.error(f"Failed to stop {platform} connector: {e}")
        return {"success": False, "error": str(e)}


@router.post("/{platform}/test")
async def test_connector(platform: str):
    """Test a bot connector's connection."""
    if platform not in ("telegram", "discord"):
        raise HTTPException(status_code=400, detail=f"Unknown platform: {platform}")
    if not _vault_path:
        raise HTTPException(status_code=400, detail="Server not configured")

    config = load_bots_config(_vault_path)
    platform_config = getattr(config, platform)
    if not platform_config.enabled or not platform_config.bot_token:
        raise HTTPException(status_code=400, detail=f"{platform} not configured")

    try:
        if platform == "telegram":
            from parachute.connectors.telegram import TELEGRAM_AVAILABLE
            if not TELEGRAM_AVAILABLE:
                return {"success": False, "error": "python-telegram-bot not installed"}
            from telegram import Bot
            bot = Bot(token=platform_config.bot_token)
            me = await bot.get_me()
            return {"success": True, "bot_name": me.first_name, "bot_username": me.username}
        else:
            from parachute.connectors.discord_bot import DISCORD_AVAILABLE
            if not DISCORD_AVAILABLE:
                return {"success": False, "error": "discord.py not installed"}
            import aiohttp
            async with aiohttp.ClientSession() as session:
                headers = {"Authorization": f"Bot {platform_config.bot_token}"}
                async with session.get(
                    "https://discord.com/api/v10/users/@me", headers=headers
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        return {"success": True, "bot_name": data.get("username"), "bot_id": data.get("id")}
                    return {"success": False, "error": f"HTTP {resp.status}"}
    except Exception as e:
        return {"success": False, "error": str(e)}


# =========================================================================
# Pairing Requests
# =========================================================================

@router.get("/pairing")
async def list_pairing_requests():
    """List pending pairing requests."""
    if not _server_ref or not hasattr(_server_ref, "database"):
        raise HTTPException(status_code=500, detail="Database not available")

    db = _server_ref.database
    requests = await db.get_pending_pairing_requests()
    return {"requests": [r.model_dump(by_alias=True) for r in requests]}


@router.post("/pairing/{request_id}/approve")
async def approve_pairing(request_id: str, body: PairingApproval):
    """Approve a pairing request. Adds user to platform allowlist."""
    if not _server_ref or not hasattr(_server_ref, "database"):
        raise HTTPException(status_code=500, detail="Database not available")

    db = _server_ref.database
    pr = await db.get_pairing_request(request_id)
    if not pr:
        raise HTTPException(status_code=404, detail="Pairing request not found")
    if pr.status != "pending":
        raise HTTPException(status_code=409, detail=f"Request already {pr.status}")

    resolved = await db.resolve_pairing_request(
        request_id, approved=True, trust_level=body.trust_level
    )

    # Add user to connector's allowlist in bots.yaml
    await _add_to_allowlist(pr.platform, pr.platform_user_id)

    # Update running connector's in-memory allowlist and trust cache
    connector = _connectors.get(pr.platform)
    if connector and hasattr(connector, "allowed_users"):
        if pr.platform_user_id not in [str(u) for u in connector.allowed_users]:
            typed_id = int(pr.platform_user_id) if pr.platform == "telegram" else pr.platform_user_id
            connector.allowed_users.append(typed_id)
        if hasattr(connector, "update_trust_override"):
            connector.update_trust_override(pr.platform_user_id, body.trust_level)

    # Send approval message to user
    if connector and hasattr(connector, "send_approval_message"):
        try:
            await connector.send_approval_message(pr.platform_chat_id)
        except Exception as e:
            logger.warning(f"Failed to send approval message: {e}")

    return {"success": True, "request": resolved.model_dump(by_alias=True) if resolved else None}


@router.post("/pairing/{request_id}/deny")
async def deny_pairing(request_id: str):
    """Deny a pairing request."""
    if not _server_ref or not hasattr(_server_ref, "database"):
        raise HTTPException(status_code=500, detail="Database not available")

    db = _server_ref.database
    pr = await db.get_pairing_request(request_id)
    if not pr:
        raise HTTPException(status_code=404, detail="Pairing request not found")
    if pr.status != "pending":
        raise HTTPException(status_code=409, detail=f"Request already {pr.status}")

    await db.resolve_pairing_request(request_id, approved=False)
    return {"success": True}


async def _add_to_allowlist(platform: str, user_id: str) -> None:
    """Persist a user addition to the platform's allowlist in bots.yaml."""
    if not _vault_path:
        return

    async with _config_lock:
        config = load_bots_config(_vault_path)
        platform_config = getattr(config, platform, None)
        if not platform_config:
            return

        current_users = [str(u) for u in platform_config.allowed_users]
        if user_id in current_users:
            return

        # Telegram uses int IDs, Discord uses string IDs
        typed_id = int(user_id) if platform == "telegram" else user_id
        platform_config.allowed_users.append(typed_id)

        _write_bots_config(config)
        logger.info(f"Added user {user_id} to {platform} allowlist")
