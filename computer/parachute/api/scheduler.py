"""
Scheduler management API endpoints.

Provides endpoints to view scheduled tasks and reload configuration.

Schedule configuration is read from curator agent files:
- Daily curator: Daily/.agents/curator.md (schedule field in frontmatter)
"""

import logging
from typing import Any

from fastapi import APIRouter, HTTPException

from parachute.config import get_settings
from parachute.core.scheduler import (
    get_scheduler_status,
    reload_scheduler,
    trigger_job_now,
)

logger = logging.getLogger(__name__)

router = APIRouter()


@router.get("/scheduler")
async def get_scheduler_info() -> dict[str, Any]:
    """
    Get the current scheduler status and configuration.

    Returns:
    - running: Whether the scheduler is active
    - jobs: List of scheduled jobs with next run times
    - config: Current schedule configuration (read from curator.md files)
    """
    settings = get_settings()
    return get_scheduler_status(settings.vault_path)


@router.post("/scheduler/reload")
async def reload_scheduler_config() -> dict[str, Any]:
    """
    Reload scheduler configuration from curator files.

    Call this after editing Daily/.agents/curator.md to apply schedule changes.
    """
    settings = get_settings()
    result = reload_scheduler(settings.vault_path)

    if not result.get("success"):
        raise HTTPException(status_code=500, detail=result.get("error", "Unknown error"))

    return result


@router.post("/scheduler/daily-curator/trigger")
async def trigger_daily_curator_now() -> dict[str, Any]:
    """
    Manually trigger the daily curator to run immediately.

    This is the same as POST /modules/daily/curate but runs through
    the scheduler infrastructure.
    """
    settings = get_settings()

    result = await trigger_job_now("daily_curator", settings.vault_path)

    if not result.get("success"):
        raise HTTPException(status_code=500, detail=result.get("error", "Unknown error"))

    return result
