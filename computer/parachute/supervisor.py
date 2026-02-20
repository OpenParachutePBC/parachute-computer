"""
Parachute Computer Supervisor Service

Lightweight FastAPI service that manages the main Parachute server.
- Runs independently (survives main server crashes)
- Provides server lifecycle control (start/stop/restart)
- Streams server logs
- Manages config updates

CRITICAL: NO module loading, NO Claude SDK, NO orchestrator.
Supervisor must be ultra-stable and defensive.
"""

import asyncio
import json
import logging
import os
import re
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Optional

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from parachute import __version__

logger = logging.getLogger(__name__)

# Track supervisor start time for uptime
_start_time = time.time()

# Defensive config loading (survives corrupted config.yaml)
settings = None
try:
    from parachute.config import get_settings
    settings = get_settings()
except Exception as e:
    logger.error(f"Config load failed: {e}. Using fallback settings.")
    # Supervisor still starts, but endpoints return degraded status


# === Health Check Cache ===
class ServerHealthCache:
    """TTL cache for main server health checks (90% overhead reduction)."""

    def __init__(self, ttl: float = 5.0):
        self._ttl = ttl
        self._cache: Optional[dict] = None
        self._cached_at: float = 0

    async def get_health(self) -> dict:
        """Get server health with TTL caching."""
        now = time.time()
        if self._cache and (now - self._cached_at) < self._ttl:
            return {**self._cache, "cached": True}

        try:
            async with httpx.AsyncClient(timeout=2.0) as client:
                resp = await client.get("http://localhost:3333/api/health?detailed=true")
                resp.raise_for_status()
                self._cache = {"running": True, "status": resp.json()}
        except Exception as e:
            self._cache = {"running": False, "error": str(e)}

        self._cached_at = now
        return {**self._cache, "cached": False}


_health_cache = ServerHealthCache(ttl=5.0)


# === Lifespan ===
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Supervisor startup/shutdown tasks."""
    logger.info("Supervisor starting...")
    yield
    logger.info("Supervisor shutting down...")


# === FastAPI App ===
app = FastAPI(
    title="Parachute Supervisor",
    version=__version__,
    lifespan=lifespan
)


# === Pydantic Models ===
class SupervisorStatusResponse(BaseModel):
    """Response from GET /supervisor/status."""
    supervisor_uptime_seconds: int
    supervisor_version: str
    main_server_healthy: bool
    main_server_status: str  # "running" | "stopped" | "crashed"
    main_server_uptime_seconds: Optional[int] = None  # None if stopped
    main_server_version: Optional[str] = None
    main_server_port: Optional[int] = None
    config_loaded: bool  # False if config.yaml corrupted


class ServerActionResponse(BaseModel):
    """Response from POST /supervisor/server/*."""
    success: bool
    message: str


class ConfigUpdateRequest(BaseModel):
    """Request body for PUT /supervisor/config."""
    values: dict[str, Any] = Field(
        ...,
        examples=[{"default_model": "claude-sonnet-4-5-20250929"}]
    )
    restart: bool = Field(default=True, description="Whether to restart server after update")


class ConfigUpdateResponse(BaseModel):
    """Response from PUT /supervisor/config."""
    success: bool
    updated_keys: list[str]
    server_restarted: bool


# === Helper Functions ===
def _redact_log_line(line: str) -> str:
    """Redact sensitive patterns from log lines (SECURITY requirement)."""
    REDACT_PATTERNS = [
        (re.compile(r'para_[a-zA-Z0-9]{32}'), '[REDACTED_API_KEY]'),
        (re.compile(r'CLAUDE_CODE_OAUTH_TOKEN=[^\s]+'), 'CLAUDE_CODE_OAUTH_TOKEN=[REDACTED]'),
        (re.compile(r'/Users/[^/]+/'), '/Users/[REDACTED]/'),
    ]

    for pattern, replacement in REDACT_PATTERNS:
        line = pattern.sub(replacement, line)
    return line


# === Endpoints ===
@app.get("/supervisor/status", response_model=SupervisorStatusResponse, status_code=200)
async def get_status() -> SupervisorStatusResponse:
    """Check supervisor health and main server status."""
    server_health = await _health_cache.get_health()
    is_running = server_health.get("running", False)

    # Extract server details from health check if available
    main_server_uptime = None
    main_server_version = None
    main_server_port = None

    if is_running and settings:
        main_server_port = settings.port
        # Get version and uptime from nested status object
        status_data = server_health.get("status", {})
        if "version" in status_data:
            main_server_version = status_data["version"]
        # The health endpoint returns "uptime" (seconds as float), not "uptime_seconds"
        if "uptime" in status_data:
            main_server_uptime = int(status_data["uptime"])

    return SupervisorStatusResponse(
        supervisor_uptime_seconds=int(time.time() - _start_time),
        supervisor_version=__version__,
        main_server_healthy=is_running,
        main_server_status="running" if is_running else "stopped",
        main_server_uptime_seconds=main_server_uptime,
        main_server_version=main_server_version,
        main_server_port=main_server_port,
        config_loaded=settings is not None,
    )


@app.post("/supervisor/server/start", response_model=ServerActionResponse, status_code=200)
async def start_server() -> ServerActionResponse:
    """Start the main server via daemon manager."""
    if not settings:
        raise HTTPException(status_code=503, detail="Config not loaded")

    from parachute.daemon import get_daemon_manager
    from parachute.config import get_config_path
    import yaml

    def _start_sync():
        # Load config from vault
        config_path = get_config_path(settings.vault_path)
        config = {}
        if config_path.exists():
            with open(config_path) as f:
                config = yaml.safe_load(f) or {}

        daemon = get_daemon_manager(settings.vault_path, config)
        daemon.start()

    try:
        await asyncio.to_thread(_start_sync)  # Wrap blocking daemon call
        return ServerActionResponse(success=True, message="Server started")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Server start failed: {e}")


@app.post("/supervisor/server/stop", response_model=ServerActionResponse, status_code=200)
async def stop_server() -> ServerActionResponse:
    """Stop the main server (SIGTERM → SIGKILL after 5s)."""
    if not settings:
        raise HTTPException(status_code=503, detail="Config not loaded")

    from parachute.daemon import get_daemon_manager
    from parachute.config import get_config_path
    import yaml

    def _stop_sync():
        # Load config from vault
        config_path = get_config_path(settings.vault_path)
        config = {}
        if config_path.exists():
            with open(config_path) as f:
                config = yaml.safe_load(f) or {}

        daemon = get_daemon_manager(settings.vault_path, config)
        daemon.stop()

    try:
        await asyncio.to_thread(_stop_sync)
        return ServerActionResponse(success=True, message="Server stopped")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Server stop failed: {e}")


@app.post("/supervisor/server/restart", response_model=ServerActionResponse, status_code=200)
async def restart_server() -> ServerActionResponse:
    """Restart the main server (stop + start)."""
    if not settings:
        raise HTTPException(status_code=503, detail="Config not loaded")

    from parachute.daemon import get_daemon_manager
    from parachute.config import get_config_path
    import yaml

    def _restart_sync():
        # Load config from vault
        config_path = get_config_path(settings.vault_path)
        config = {}
        if config_path.exists():
            with open(config_path) as f:
                config = yaml.safe_load(f) or {}

        daemon = get_daemon_manager(settings.vault_path, config)
        daemon.restart()

    try:
        await asyncio.to_thread(_restart_sync)
        return ServerActionResponse(success=True, message="Server restarted")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Server restart failed: {e}")


@app.get("/supervisor/logs")
async def stream_logs(
    request: Request,
    lines: int = 50,
) -> StreamingResponse:
    """
    Stream recent server log lines via SSE with backpressure control.

    Security: Log lines are redacted (API keys, tokens, paths).
    Performance: Bounded memory usage via line limit.
    """
    # Cap at 500 to prevent OOM
    lines = min(lines, 500)

    log_file = Path.home() / "Library" / "Logs" / "Parachute" / "server.log"

    async def log_generator():
        if not log_file.exists():
            yield f"data: {json.dumps({'error': 'Log file not found'})}\n\n"
            return

        # Read last N lines in thread (blocking I/O)
        def read_tail(path: Path, n: int) -> list[str]:
            from collections import deque
            try:
                with open(path, 'rb') as f:
                    return [line.decode('utf-8', errors='replace') for line in deque(f, maxlen=n)]
            except Exception as e:
                logger.error(f"Failed to read log file: {e}")
                return []

        try:
            lines_list = await asyncio.to_thread(read_tail, log_file, lines)

            for line in lines_list:
                if await request.is_disconnected():
                    return

                # SECURITY: Redact sensitive patterns
                line = _redact_log_line(line)

                yield f"data: {json.dumps({'line': line})}\n\n"
                await asyncio.sleep(0)  # Yield to event loop (backpressure)

        except Exception as e:
            logger.error(f"Log streaming error: {e}")
            yield f"data: {json.dumps({'error': str(e)})}\n\n"

    return StreamingResponse(
        log_generator(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive"},
    )


@app.get("/supervisor/config", response_model=dict)
async def get_config() -> dict:
    """
    Read current config values.

    SECURITY: Secrets are redacted (api_key, tokens).
    """
    if not settings:
        raise HTTPException(status_code=503, detail="Config not loaded (corrupted yaml)")

    import yaml

    config_file = settings.vault_path / ".parachute" / "config.yaml"

    def _read_config():
        if not config_file.exists():
            return {}
        with open(config_file) as f:
            return yaml.safe_load(f) or {}

    try:
        data = await asyncio.to_thread(_read_config)

        # SECURITY: Redact secrets
        REDACTED = "[REDACTED]"
        for secret_key in ["api_key", "claude_code_oauth_token"]:
            if secret_key in data:
                data[secret_key] = REDACTED

        return {"config": data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Config read failed: {e}")


@app.put("/supervisor/config", response_model=ConfigUpdateResponse, status_code=200)
async def update_config(body: ConfigUpdateRequest) -> ConfigUpdateResponse:
    """
    Update config values with atomic write + file locking.

    SECURITY: Validates model name format before writing.
    ARCHITECTURE: Uses atomic write to prevent race conditions.
    """
    if not settings:
        raise HTTPException(status_code=503, detail="Config not loaded")

    # SECURITY: Validate model name format
    if "default_model" in body.values:
        model_id = body.values["default_model"]
        if not re.match(r'^claude-[a-z0-9\-]+$', model_id):
            raise HTTPException(status_code=400, detail="Invalid model ID format")

    try:
        from parachute.config import save_yaml_config_atomic

        vault_path = settings.vault_path
        await asyncio.to_thread(save_yaml_config_atomic, vault_path, body.values)

        restarted = False
        if body.restart:
            await restart_server()
            restarted = True

        return ConfigUpdateResponse(
            success=True,
            updated_keys=list(body.values.keys()),
            server_restarted=restarted,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Config update failed: {e}")


@app.get("/supervisor/models")
async def get_available_models(show_all: bool = False):
    """
    GET /supervisor/models?show_all=false

    Query Anthropic Models API and return filtered list.
    - show_all=false (default): Latest version per family only
    - show_all=true: All versions, grouped by family

    Requires: settings.claude_code_oauth_token
    """
    if not settings:
        raise HTTPException(status_code=503, detail="Config not loaded")

    api_key = settings.claude_code_oauth_token
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail="CLAUDE_CODE_OAUTH_TOKEN not configured"
        )

    try:
        from parachute.models_api import fetch_available_models

        models = await fetch_available_models(api_key)

        if not show_all:
            # Filter to latest version per family
            models = [m for m in models if m.is_latest]

        return {
            "models": [m.model_dump() for m in models],
            "count": len(models),
            "show_all": show_all,
        }
    except Exception as e:
        logger.error(f"Failed to fetch models: {e}")
        raise HTTPException(status_code=500, detail=f"Models API error: {e}")


