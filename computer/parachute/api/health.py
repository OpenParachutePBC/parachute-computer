"""
Health check endpoints.
"""

import subprocess
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Query, Request

from parachute import __version__
from parachute.config import get_settings
from parachute.core.sandbox import DockerSandbox

router = APIRouter()


def _get_git_commit() -> str | None:
    """Get the current git commit hash, if in a git repo."""
    try:
        base_dir = Path(__file__).parent.parent.parent
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=base_dir,
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return None

# Computed once at import time — avoids blocking the event loop on every request
_GIT_COMMIT: str | None = _get_git_commit()

# Server start time for uptime calculation
_start_time = time.time()


@router.get("/health")
async def health_check(
    request: Request,
    detailed: bool = Query(False, description="Include detailed information"),
) -> dict[str, Any]:
    """
    Health check endpoint.

    Returns basic status, or detailed info if requested.
    """
    settings = get_settings()

    basic = {
        "status": "ok",
        "timestamp": int(time.time() * 1000),
        "version": __version__,
        **({"commit": _GIT_COMMIT} if _GIT_COMMIT else {}),
    }

    if not detailed:
        return basic

    # Detailed health check
    vault_status = "ok"
    if not settings.vault_path.exists():
        vault_status = "inaccessible"

    # Module status
    modules_status = []
    module_loader = getattr(request.app.state, 'module_loader', None)
    if module_loader:
        modules_status = module_loader.get_module_status()

    # Docker sandbox availability (use shared instance from app.state or create without token)
    sandbox = getattr(request.app.state, 'sandbox', None)
    if sandbox is None:
        # Fallback: create without token (health check doesn't need it)
        sandbox = DockerSandbox(vault_path=settings.vault_path)
    docker_available = await sandbox.is_available()
    docker_info = {
        "available": docker_available,
        "image": "parachute-sandbox:latest",
    }
    if docker_available:
        docker_info["image_exists"] = await sandbox.image_exists()

    # Bot connector status
    from parachute.api.bots import _connectors
    bots = {}
    for platform in ("telegram", "discord", "matrix"):
        connector = _connectors.get(platform)
        if connector:
            bots[platform] = {"running": connector._running}
        else:
            bots[platform] = {"running": False}

    return {
        **basic,
        "vault": {
            "path": str(settings.vault_path),
            "status": vault_status,
        },
        "modules": modules_status,
        "docker": docker_info,
        "bots": bots,
        "uptime": time.time() - _start_time,
    }
