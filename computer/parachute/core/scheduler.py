"""
Scheduler for automated tasks.

Uses APScheduler to run background jobs like:
- Daily curator at a configured time (default: 3am)
- Future: Weekly summaries, cleanup tasks, etc.

Configuration is read from the curator agent files themselves:
- Daily curator: Daily/.agents/curator.md (schedule field in frontmatter)
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


def _load_daily_curator_config(vault_path: Path) -> Optional[dict[str, Any]]:
    """
    Load daily curator config from Daily/.agents/curator.md frontmatter.

    Returns None if the file doesn't exist (curator is disabled).
    Returns config dict with schedule info if file exists.
    """
    curator_file = vault_path / "Daily" / ".agents" / "curator.md"

    if not curator_file.exists():
        logger.info("Daily curator agent file not found, curator disabled")
        return None

    try:
        import frontmatter
        post = frontmatter.loads(curator_file.read_text())
        metadata = post.metadata

        # Get schedule config from frontmatter
        schedule = metadata.get("schedule", {})

        # Support both dict format and simple time string
        if isinstance(schedule, str):
            hour, minute = _parse_time(schedule)
            enabled = True
        elif isinstance(schedule, dict):
            enabled = schedule.get("enabled", True)
            time_str = schedule.get("time", "3:00")
            hour, minute = _parse_time(time_str)
        else:
            # Default: enabled at 3:00
            enabled = True
            hour, minute = 3, 0

        return {
            "enabled": enabled,
            "hour": hour,
            "minute": minute,
            "source": str(curator_file),
        }

    except Exception as e:
        logger.warning(f"Error reading curator config: {e}, using defaults")
        return {
            "enabled": True,
            "hour": 3,
            "minute": 0,
            "source": str(curator_file),
        }


async def _run_daily_curator_job():
    """Job function that runs the daily curator."""
    global _vault_path

    if _vault_path is None:
        logger.error("Scheduler: vault_path not set, skipping daily curator")
        return

    # Check if curator still exists (user might have deleted it)
    curator_file = _vault_path / "Daily" / ".agents" / "curator.md"
    if not curator_file.exists():
        logger.info("Scheduler: Daily curator agent file not found, skipping")
        return

    logger.info("Scheduler: Running daily curator job")

    try:
        from parachute.core.daily_curator import run_daily_curator

        result = await run_daily_curator(
            vault_path=_vault_path,
            date=None,  # Today
            force=False,
        )

        logger.info(f"Scheduler: Daily curator completed: {result.get('status')}")

    except Exception as e:
        logger.error(f"Scheduler: Daily curator job failed: {e}", exc_info=True)


def _schedule_daily_curator(scheduler: AsyncIOScheduler, vault_path: Path) -> bool:
    """Schedule or update the daily curator job based on curator.md config."""
    job_id = "daily_curator"

    # Remove existing job if present
    try:
        scheduler.remove_job(job_id)
    except JobLookupError:
        pass

    # Load config from curator.md
    config = _load_daily_curator_config(vault_path)

    if config is None:
        logger.info("Scheduler: Daily curator not configured (no curator.md)")
        return False

    if not config.get("enabled", True):
        logger.info("Scheduler: Daily curator disabled in config")
        return False

    hour = config.get("hour", 3)
    minute = config.get("minute", 0)

    trigger = CronTrigger(hour=hour, minute=minute)

    scheduler.add_job(
        _run_daily_curator_job,
        trigger=trigger,
        id=job_id,
        name="Daily Curator",
        replace_existing=True,
    )

    logger.info(f"Scheduler: Daily curator scheduled for {hour:02d}:{minute:02d}")
    return True


async def init_scheduler(vault_path: Path) -> AsyncIOScheduler:
    """Initialize and start the scheduler."""
    global _scheduler, _vault_path

    _vault_path = vault_path

    if _scheduler is not None:
        logger.warning("Scheduler already initialized")
        return _scheduler

    # Create scheduler
    _scheduler = AsyncIOScheduler()

    # Schedule jobs based on what's configured in the vault
    _schedule_daily_curator(_scheduler, vault_path)

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

    # Load config from curator.md
    daily_config = _load_daily_curator_config(vault_path)

    status = {
        "running": _scheduler is not None and _scheduler.running if _scheduler else False,
        "jobs": [],
        "config": {
            "daily_curator": daily_config,
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
    """Reload scheduler configuration from curator files."""
    global _scheduler

    if not _scheduler or not _scheduler.running:
        return {"success": False, "error": "Scheduler not running"}

    # Re-schedule daily curator
    scheduled = _schedule_daily_curator(_scheduler, vault_path)

    return {
        "success": True,
        "daily_curator_scheduled": scheduled,
        "next_run": _get_next_run("daily_curator"),
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
    if job_id == "daily_curator":
        global _vault_path
        _vault_path = vault_path

        try:
            await _run_daily_curator_job()
            return {"success": True, "job_id": job_id, "message": "Job executed"}
        except Exception as e:
            return {"success": False, "job_id": job_id, "error": str(e)}

    return {"success": False, "job_id": job_id, "error": f"Unknown job: {job_id}"}
