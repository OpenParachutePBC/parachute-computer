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

from parachute.connectors.base import ConnectorState
from parachute.connectors.config import BotsConfig, TelegramConfig, DiscordConfig, MatrixConfig, TrustLevelStr, load_bots_config


class PairingApproval(BaseModel):
    """Request body for approving a pairing request."""
    trust_level: TrustLevelStr = "untrusted"


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
    dm_trust_level: Optional[TrustLevelStr] = None
    group_trust_level: Optional[TrustLevelStr] = None


class MatrixConfigUpdate(BaseModel):
    """Partial update for Matrix bot config."""
    enabled: Optional[bool] = None
    homeserver_url: Optional[str] = None
    user_id: Optional[str] = None
    access_token: Optional[str] = None
    device_id: Optional[str] = None
    allowed_rooms: Optional[list[str]] = None
    dm_trust_level: Optional[TrustLevelStr] = None
    group_trust_level: Optional[TrustLevelStr] = None


class BotsConfigUpdate(BaseModel):
    """Request body for PUT /bots/config."""
    telegram: Optional[TelegramConfigUpdate] = None
    discord: Optional[DiscordConfigUpdate] = None
    matrix: Optional[MatrixConfigUpdate] = None

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


_EMPTY_CONNECTOR_STATUS = {
    "status": "stopped",
    "running": False,
    "failure_count": 0,
    "last_error": None,
    "last_error_time": None,
    "uptime": None,
    "last_message_time": None,
    "reconnect_attempts": 0,
    "allowed_users_count": 0,
}


@router.get("/status")
async def bots_status():
    """Get status of all bot connectors."""
    if not _vault_path:
        return {"configured": False, "connectors": {}}

    config = load_bots_config(_vault_path)

    connectors = {}
    for platform in ("telegram", "discord", "matrix"):
        config_section = getattr(config, platform, None)
        connector = _connectors.get(platform)
        has_credentials = False
        if platform == "matrix":
            has_credentials = bool(getattr(config_section, "access_token", None))
        else:
            has_credentials = bool(getattr(config_section, "bot_token", None))
        connectors[platform] = {
            "enabled": config_section.enabled if config_section else False,
            "has_token": has_credentials,
            **(connector.status if connector else _EMPTY_CONNECTOR_STATUS),
        }

    return {"configured": True, "connectors": connectors}


@router.get("/config")
async def bots_config():
    """Get bot configuration (tokens masked)."""
    if not _vault_path:
        return {"telegram": {}, "discord": {}, "matrix": {}}

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
            "allowed_users": config.discord.allowed_users,
            "dm_trust_level": config.discord.dm_trust_level,
            "group_trust_level": config.discord.group_trust_level,
        },
        "matrix": {
            "enabled": config.matrix.enabled,
            "has_token": bool(config.matrix.access_token),
            "homeserver_url": config.matrix.homeserver_url,
            "user_id": config.matrix.user_id,
            "allowed_rooms": config.matrix.allowed_rooms,
            "dm_trust_level": config.matrix.dm_trust_level,
            "group_trust_level": config.matrix.group_trust_level,
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

        # Merge matrix config
        mx = body.matrix.model_dump(exclude_none=True) if body.matrix else {}
        mx_token = mx.get("access_token", "")
        if not mx_token and existing.matrix.access_token:
            mx["access_token"] = existing.matrix.access_token

        # Validate with pydantic
        new_config = BotsConfig(
            telegram=TelegramConfig(**{**existing.telegram.model_dump(), **tg}),
            discord=DiscordConfig(**{**existing.discord.model_dump(), **dc}),
            matrix=MatrixConfig(**{**existing.matrix.model_dump(), **mx}),
        )

        _write_bots_config(new_config)

    # Restart affected running connectors outside the lock
    for platform in ("telegram", "discord", "matrix"):
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
    async with _config_lock:
        existing = _connectors.get(platform)
        if existing and existing._status in (ConnectorState.RUNNING, ConnectorState.RECONNECTING):
            logger.warning(f"{platform} connector already active (status: {existing._status})")
            return

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
                ack_emoji=platform_config.ack_emoji,
            )
        elif platform == "discord":
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
                ack_emoji=platform_config.ack_emoji,
            )
        elif platform == "matrix":
            from parachute.connectors.matrix_bot import MatrixConnector, MATRIX_AVAILABLE
            if not MATRIX_AVAILABLE:
                raise RuntimeError("matrix-nio not installed")
            connector = MatrixConnector(
                homeserver_url=platform_config.homeserver_url,
                user_id=platform_config.user_id,
                access_token=platform_config.access_token,
                device_id=platform_config.device_id,
                server=_server_ref,
                allowed_users=[],
                allowed_rooms=platform_config.allowed_rooms,
                dm_trust_level=platform_config.dm_trust_level,
                group_trust_level=platform_config.group_trust_level,
                group_mention_mode=platform_config.group_mention_mode,
                ack_emoji=platform_config.ack_emoji,
            )
        else:
            raise RuntimeError(f"Unknown platform: {platform}")

        def _on_connector_error(task: asyncio.Task) -> None:
            if task.cancelled():
                return
            exc = task.exception()
            if exc:
                logger.error(f"{platform} connector start() failed: {exc}")
                connector = _connectors.get(platform)
                if connector:
                    connector.mark_failed(exc)
                # Don't remove from _connectors — keep so status endpoint can report failure

        task = asyncio.create_task(connector.start())
        task.add_done_callback(_on_connector_error)
        _connectors[platform] = connector


async def auto_start_connectors() -> None:
    """Start enabled connectors with valid tokens. Errors are logged, not raised."""
    if not _vault_path:
        return

    config = load_bots_config(_vault_path)
    for platform in ("telegram", "discord", "matrix"):
        cfg = getattr(config, platform)
        has_credentials = cfg.bot_token if hasattr(cfg, "bot_token") else cfg.access_token
        if cfg.enabled and has_credentials:
            try:
                await _start_platform(platform)
                logger.info(f"Auto-started {platform} connector")
            except Exception as e:
                logger.error(f"Failed to auto-start {platform}: {e}")


@router.post("/{platform}/start")
async def start_connector(platform: str):
    """Start a bot connector."""
    if platform not in ("telegram", "discord", "matrix"):
        raise HTTPException(status_code=400, detail=f"Unknown platform: {platform}")
    if not _vault_path:
        raise HTTPException(status_code=400, detail="Server not configured")
    existing = _connectors.get(platform)
    if existing and existing._status in (ConnectorState.RUNNING, ConnectorState.RECONNECTING):
        raise HTTPException(status_code=409, detail=f"{platform} connector already running")

    config = load_bots_config(_vault_path)
    platform_config = getattr(config, platform)

    credentials = platform_config.bot_token if hasattr(platform_config, "bot_token") else platform_config.access_token
    if not credentials:
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
    if platform not in ("telegram", "discord", "matrix"):
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
    if platform not in ("telegram", "discord", "matrix"):
        raise HTTPException(status_code=400, detail=f"Unknown platform: {platform}")
    if not _vault_path:
        raise HTTPException(status_code=400, detail="Server not configured")

    config = load_bots_config(_vault_path)
    platform_config = getattr(config, platform)

    if platform == "matrix":
        if not platform_config.enabled or not platform_config.access_token:
            raise HTTPException(status_code=400, detail=f"{platform} not configured")
    else:
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
        elif platform == "discord":
            from parachute.connectors.discord_bot import DISCORD_AVAILABLE
            if not DISCORD_AVAILABLE:
                return {"success": False, "error": "discord.py not installed"}
            import aiohttp
            import ssl
            import certifi
            ssl_ctx = ssl.create_default_context(cafile=certifi.where())
            conn = aiohttp.TCPConnector(ssl=ssl_ctx)
            async with aiohttp.ClientSession(connector=conn) as session:
                headers = {"Authorization": f"Bot {platform_config.bot_token}"}
                async with session.get(
                    "https://discord.com/api/v10/users/@me", headers=headers
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        return {"success": True, "bot_name": data.get("username"), "bot_id": data.get("id")}
                    return {"success": False, "error": f"HTTP {resp.status}"}
        elif platform == "matrix":
            from parachute.connectors.matrix_bot import MATRIX_AVAILABLE
            if not MATRIX_AVAILABLE:
                return {"success": False, "error": "matrix-nio not installed"}
            from nio import AsyncClient
            client = AsyncClient(platform_config.homeserver_url, platform_config.user_id)
            client.access_token = platform_config.access_token
            try:
                resp = await client.whoami()
                if hasattr(resp, "user_id"):
                    return {"success": True, "user_id": resp.user_id}
                return {"success": False, "error": str(resp)}
            finally:
                await client.close()
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


@router.get("/pairing/count")
async def get_pending_pairing_count():
    """Get count of pending pairing requests. Lightweight endpoint for polling."""
    if not _server_ref or not hasattr(_server_ref, "database"):
        raise HTTPException(status_code=500, detail="Database not available")

    db = _server_ref.database
    count = await db.get_pending_pairing_count()
    return {"pending": count}


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

    # Determine if this is a room-based approval (Matrix bridged rooms use room IDs)
    is_room_approval = pr.platform == "matrix" and pr.platform_user_id.startswith("!")

    if is_room_approval:
        # Room-based approval — add to allowed_rooms
        await _add_to_allowlist("matrix", pr.platform_user_id, is_room=True)

        # Update running connector's in-memory allowed_rooms
        connector = _connectors.get("matrix")
        if connector and hasattr(connector, "allowed_rooms"):
            if pr.platform_user_id not in connector.allowed_rooms:
                connector.allowed_rooms.append(pr.platform_user_id)
    else:
        # User-based approval (Telegram/Discord/Matrix DM)
        await _add_to_allowlist(pr.platform, pr.platform_user_id)

        # Update running connector's in-memory allowlist and trust cache
        connector = _connectors.get(pr.platform)
        if connector and hasattr(connector, "allowed_users"):
            if pr.platform_user_id not in [str(u) for u in connector.allowed_users]:
                typed_id = int(pr.platform_user_id) if pr.platform == "telegram" else pr.platform_user_id
                connector.allowed_users.append(typed_id)

    connector = _connectors.get(pr.platform)
    if connector and hasattr(connector, "update_trust_override"):
        connector.update_trust_override(pr.platform_user_id, body.trust_level)

    # Activate the pending session: clear pending_approval, update trust level
    linked_session = await db.get_session_by_bot_link(pr.platform, pr.platform_chat_id)
    if linked_session and linked_session.metadata and linked_session.metadata.get("pending_approval"):
        updated_metadata = dict(linked_session.metadata)
        updated_metadata.pop("pending_approval", None)
        from parachute.models.session import SessionUpdate
        await db.update_session(linked_session.id, SessionUpdate(
            metadata=updated_metadata,
            trust_level=body.trust_level,
        ))
        logger.info(f"Activated pending session {linked_session.id[:8]} for approved user")

    # Send approval message to user
    connector = _connectors.get(pr.platform)
    if connector and hasattr(connector, "send_approval_message"):
        try:
            await connector.send_approval_message(pr.platform_chat_id)
        except Exception as e:
            logger.warning(f"Failed to send approval message: {e}")

    # For bridged rooms, send relay setup notice
    if is_room_approval and linked_session and linked_session.metadata:
        bridge_meta = linked_session.metadata.get("bridge_metadata", {})
        bridge_type = bridge_meta.get("bridge_type", "")
        if bridge_type and connector and hasattr(connector, "send_message"):
            try:
                await connector.send_message(
                    pr.platform_chat_id,
                    f"To relay my responses back through the bridge, "
                    f"run `!{bridge_type} set-relay` in this room as the admin user.",
                )
            except Exception as e:
                logger.warning(f"Failed to send relay notice: {e}")

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

    # Archive the pending session linked to this request
    linked_session = await db.get_session_by_bot_link(pr.platform, pr.platform_chat_id)
    if linked_session and linked_session.metadata and linked_session.metadata.get("pending_approval"):
        await db.archive_session(linked_session.id)
        logger.info(f"Archived pending session {linked_session.id[:8]} for denied user")

    # Send denial notification to the user if connector is running
    connector = _connectors.get(pr.platform)
    if connector:
        try:
            await connector.send_denial_message(pr.platform_chat_id)
        except Exception as e:
            logger.warning(f"Failed to send denial notification: {e}")

    return {"success": True}


async def _add_to_allowlist(platform: str, identifier: str, *, is_room: bool = False) -> None:
    """Persist a user or room addition to the platform's allowlist in bots.yaml."""
    if not _vault_path:
        return

    async with _config_lock:
        config = load_bots_config(_vault_path)
        platform_config = getattr(config, platform, None)
        if not platform_config:
            return

        if is_room and hasattr(platform_config, "allowed_rooms"):
            if identifier not in platform_config.allowed_rooms:
                platform_config.allowed_rooms.append(identifier)
                _write_bots_config(config)
                logger.info(f"Added room {identifier} to {platform} allowed_rooms")
        else:
            current_users = [str(u) for u in platform_config.allowed_users]
            if identifier in current_users:
                return
            # Telegram uses int IDs, Discord uses string IDs
            typed_id = int(identifier) if platform == "telegram" else identifier
            platform_config.allowed_users.append(typed_id)
            _write_bots_config(config)
            logger.info(f"Added user {identifier} to {platform} allowlist")
