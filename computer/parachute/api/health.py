"""
Health check endpoints.
"""

import time
from typing import Any

from fastapi import APIRouter, Query, Request

from parachute.config import get_settings

router = APIRouter()

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

    basic = {
        "status": "ok",
        "timestamp": int(time.time() * 1000),
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
        "version": "0.1.0",
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
