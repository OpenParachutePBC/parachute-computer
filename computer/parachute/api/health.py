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

router = APIRouter()


def _get_git_commit() -> str | None:
    """Get the current git commit hash, if in a git repo."""
    try:
        # Get the directory where this file lives (parachute/api/)
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

# Server start time for uptime calculation
_start_time = time.time()


@router.get("/health")
async def health_check(
    detailed: bool = Query(False, description="Include detailed information"),
) -> dict[str, Any]:
    """
    Health check endpoint.

    Returns basic status, or detailed info if requested.
    """
    settings = get_settings()

    commit = _get_git_commit()
    basic = {
        "status": "ok",
        "timestamp": int(time.time() * 1000),
        "version": __version__,
        **({"commit": commit} if commit else {}),
    }

    if not detailed:
        return basic

    # Detailed health check
    vault_status = "ok"
    if not settings.vault_path.exists():
        vault_status = "inaccessible"

    return {
        **basic,
        "vault": {
            "path": str(settings.vault_path),
            "status": vault_status,
        },
        "uptime": time.time() - _start_time,
    }


@router.get("/debug/auth")
async def debug_auth(request: Request) -> dict[str, Any]:
    """
    Debug endpoint to check what auth headers are received.

    This helps diagnose 401 issues by showing exactly what the server sees.
    """
    client_host = request.client.host if request.client else "unknown"

    return {
        "client_host": client_host,
        "is_localhost": client_host in ("127.0.0.1", "::1", "localhost"),
        "headers": {
            "x-api-key": request.headers.get("x-api-key", "(not set)"),
            "authorization": request.headers.get("authorization", "(not set)"),
            "user-agent": request.headers.get("user-agent", "(not set)"),
        },
        "has_api_key": bool(
            request.headers.get("x-api-key") or
            request.headers.get("authorization", "").replace("Bearer ", "")
        ),
    }
