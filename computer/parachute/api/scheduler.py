"""
Scheduler management API endpoints.

Provides endpoints to view scheduled tasks and reload configuration.

Schedule configuration is read from daily agent files:
- Daily agents: Daily/.agents/{name}.md (schedule field in frontmatter)
"""

import logging
from typing import Any

from fastapi import APIRouter, HTTPException

from parachute.config import get_settings
from parachute.core.scheduler import (
    get_scheduler_status,
    reload_scheduler,
    trigger_job_now,
    trigger_agent_now,
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
    - agents: Configuration for all daily agents
    - config: Legacy field
    """
    settings = get_settings()
    return get_scheduler_status(settings.vault_path)


@router.post("/scheduler/reload")
async def reload_scheduler_config() -> dict[str, Any]:
    """
    Reload scheduler configuration from agent files.

    Call this after editing Daily/.agents/*.md to apply schedule changes.
    """
    settings = get_settings()
    result = reload_scheduler(settings.vault_path)

    if not result.get("success"):
        raise HTTPException(status_code=500, detail=result.get("error", "Unknown error"))

    return result


@router.post("/scheduler/agents/{agent_name}/trigger")
async def trigger_agent(agent_name: str) -> dict[str, Any]:
    """
    Manually trigger a daily agent to run immediately.

    Args:
        agent_name: Name of the agent (e.g., "content-scout")

    Note: daily_agent module is not yet available in modular architecture (Phase 3).
    This endpoint will return an error until then.
    """
    settings = get_settings()

    result = await trigger_agent_now(
        agent_name=agent_name,
        vault_path=settings.vault_path,
    )

    if result.get("status") == "error" or not result.get("success", True):
        raise HTTPException(status_code=500, detail=result.get("error", "Unknown error"))

    return result
