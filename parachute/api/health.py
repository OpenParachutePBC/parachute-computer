"""
Health check endpoints.
"""

import time
from typing import Any

from fastapi import APIRouter, Query

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
