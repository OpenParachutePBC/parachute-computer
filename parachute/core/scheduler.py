"""
Scheduler for automated tasks.

Uses APScheduler to run background jobs like:
- Daily agents at configured times (from Daily/.agents/*.md)
- Future: Weekly summaries, cleanup tasks, etc.

Configuration is read from agent markdown files with YAML frontmatter:
- Daily agents: Daily/.agents/{name}.md (schedule field in frontmatter)

Each agent can have its own schedule time. The scheduler discovers all
agents and schedules them according to their configuration.
"""

import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.jobstores.base import JobLookupError

logger = logging.getLogger(__name__)

# Global scheduler instance
_scheduler: Optional[AsyncIOScheduler] = None
_vault_path: Optional[Path] = None


def _parse_time(time_str: str) -> tuple[int, int]:
    """Parse a time string like '3:00' or '06:30' into (hour, minute)."""
    try:
        parts = time_str.strip().split(":")
        hour = int(parts[0])
        minute = int(parts[1]) if len(parts) > 1 else 0
        return (hour % 24, minute % 60)
    except (ValueError, IndexError):
        logger.warning(f"Invalid time format '{time_str}', using default 3:00")
        return (3, 0)


# =============================================================================
# Generic Daily Agent Scheduling
# DAILY_AGENT REMOVED - daily_agent module not yet available in modular architecture.
# These functions are stubbed out. They will be restored in Phase 3
# when parachute.core.daily_agent is implemented.
# =============================================================================

async def _run_daily_agent_job(agent_name: str):
    """Job function that runs a daily agent."""
    # DAILY_AGENT REMOVED - daily_agent not available yet
    logger.warning(f"Scheduler: daily_agent module not available, cannot run agent '{agent_name}'")
    return


def _schedule_daily_agent(scheduler: AsyncIOScheduler, vault_path: Path, agent_name: str) -> bool:
    """Schedule a daily agent based on its config file."""
    # DAILY_AGENT REMOVED - daily_agent not available yet
    logger.info(f"Scheduler: daily_agent module not available, skipping agent '{agent_name}'")
    return False


def _schedule_all_daily_agents(scheduler: AsyncIOScheduler, vault_path: Path) -> dict[str, bool]:
    """Discover and schedule all daily agents."""
    # DAILY_AGENT REMOVED - daily_agent not available yet
    logger.info("Scheduler: daily_agent module not available, no agents to schedule")
    return {}


# =============================================================================
# Legacy Support (for backward compatibility)
# =============================================================================

def _load_daily_reflection_config(vault_path: Path) -> Optional[dict[str, Any]]:
    """
    Load daily reflection config from Daily/.agents/reflection.md frontmatter.

    Returns None if the file doesn't exist (reflection agent is disabled).
    Returns config dict with schedule info if file exists.
    """
    # DAILY_AGENT REMOVED - daily_agent not available yet
    return None


# =============================================================================
# Scheduler Lifecycle
# =============================================================================

async def init_scheduler(vault_path: Path) -> AsyncIOScheduler:
    """Initialize and start the scheduler."""
    global _scheduler, _vault_path

    _vault_path = vault_path

    if _scheduler is not None:
        logger.warning("Scheduler already initialized")
        return _scheduler

    # Create scheduler
    _scheduler = AsyncIOScheduler()

    # Schedule all daily agents
    results = _schedule_all_daily_agents(_scheduler, vault_path)
    logger.info(f"Scheduled daily agents: {results}")

    # Start the scheduler
    _scheduler.start()
    logger.info("Scheduler started")

    return _scheduler


async def stop_scheduler():
    """Stop the scheduler."""
    global _scheduler

    if _scheduler is not None:
        _scheduler.shutdown(wait=False)
        _scheduler = None
        logger.info("Scheduler stopped")


def get_scheduler() -> Optional[AsyncIOScheduler]:
    """Get the scheduler instance."""
    return _scheduler


def get_scheduler_status(vault_path: Path) -> dict[str, Any]:
    """Get the current scheduler status."""
    global _scheduler

    # DAILY_AGENT REMOVED - discover_daily_agents not available yet
    agents_config: dict[str, Any] = {}

    status = {
        "running": _scheduler is not None and _scheduler.running if _scheduler else False,
        "jobs": [],
        "agents": agents_config,
        # Legacy field for backward compatibility
        "config": {
            "daily_reflection": agents_config.get("reflection"),
        },
    }

    if _scheduler and _scheduler.running:
        for job in _scheduler.get_jobs():
            next_run = job.next_run_time
            status["jobs"].append({
                "id": job.id,
                "name": job.name,
                "next_run": next_run.isoformat() if next_run else None,
                "trigger": str(job.trigger),
            })

    return status


def reload_scheduler(vault_path: Path) -> dict[str, Any]:
    """Reload scheduler configuration from agent files."""
    global _scheduler

    if not _scheduler or not _scheduler.running:
        return {"success": False, "error": "Scheduler not running"}

    # Re-schedule all daily agents
    results = _schedule_all_daily_agents(_scheduler, vault_path)

    # Build response with next run times
    agents_scheduled = {}
    for name, scheduled in results.items():
        agents_scheduled[name] = {
            "scheduled": scheduled,
            "next_run": _get_next_run(f"daily_{name}"),
        }

    return {
        "success": True,
        "agents": agents_scheduled,
        # Legacy field
        "daily_reflection_scheduled": results.get("reflection", False),
        "next_run": _get_next_run("daily_reflection"),
    }


def _get_next_run(job_id: str) -> Optional[str]:
    """Get next run time for a job."""
    global _scheduler

    if not _scheduler or not _scheduler.running:
        return None

    try:
        job = _scheduler.get_job(job_id)
        if job and job.next_run_time:
            return job.next_run_time.isoformat()
    except Exception:
        pass

    return None


async def trigger_job_now(job_id: str, vault_path: Path) -> dict[str, Any]:
    """Manually trigger a scheduled job immediately."""
    global _vault_path
    _vault_path = vault_path

    # Handle legacy job_id format
    if job_id == "daily_reflection":
        agent_name = "reflection"
    elif job_id.startswith("daily_"):
        agent_name = job_id[6:]  # Remove "daily_" prefix
    else:
        agent_name = job_id

    try:
        await _run_daily_agent_job(agent_name)
        return {"success": True, "job_id": job_id, "agent": agent_name, "message": "Job executed"}
    except Exception as e:
        return {"success": False, "job_id": job_id, "agent": agent_name, "error": str(e)}


async def trigger_agent_now(agent_name: str, vault_path: Path, date: Optional[str] = None, force: bool = False) -> dict[str, Any]:
    """
    Manually trigger a daily agent immediately.

    Args:
        agent_name: Name of the agent to run
        vault_path: Path to the vault
        date: Optional date override (YYYY-MM-DD)
        force: Force run even if already processed

    Returns:
        Result dict from the agent run
    """
    # DAILY_AGENT REMOVED - daily_agent not available yet
    logger.warning(f"trigger_agent_now: daily_agent module not available, cannot run agent '{agent_name}'")
    return {"success": False, "error": "daily_agent module not available in modular architecture"}
