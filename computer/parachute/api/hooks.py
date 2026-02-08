"""
Hooks API endpoints.

Provides visibility into registered hooks and recent errors.
"""

import logging
from typing import Any

from fastapi import APIRouter

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/hooks", tags=["hooks"])

# Module-level state (set during server startup)
_hook_runner: Any = None


def init_hooks_api(hook_runner: Any) -> None:
    """Initialize hooks API with the active HookRunner."""
    global _hook_runner
    _hook_runner = hook_runner


@router.get("")
async def list_hooks():
    """List all registered hooks."""
    if not _hook_runner:
        return {"hooks": [], "message": "Hooks system not initialized"}

    return {
        "hooks": _hook_runner.get_registered_hooks(),
        "health": _hook_runner.health_info(),
    }


@router.get("/errors")
async def hook_errors():
    """Get recent hook errors."""
    if not _hook_runner:
        return {"errors": []}

    return {
        "errors": _hook_runner.get_recent_errors(),
    }
