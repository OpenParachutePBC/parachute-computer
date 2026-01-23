"""
Usage tracking API endpoints.

Provides access to Claude usage limits for display in the app.
"""

from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, Request
from pydantic import BaseModel

from parachute.core.claude_usage import fetch_claude_usage
from parachute.config import get_settings

router = APIRouter()


class UsageLimitResponse(BaseModel):
    """A single usage limit bucket."""
    utilization: float
    resets_at: Optional[str]  # ISO format datetime


class ExtraUsageResponse(BaseModel):
    """Extra usage credits."""
    is_enabled: bool
    monthly_limit: int
    used_credits: float
    utilization: float


class ClaudeUsageResponse(BaseModel):
    """Complete Claude usage response."""
    five_hour: Optional[UsageLimitResponse]
    seven_day: Optional[UsageLimitResponse]
    seven_day_sonnet: Optional[UsageLimitResponse]
    seven_day_opus: Optional[UsageLimitResponse]
    extra_usage: Optional[ExtraUsageResponse]
    subscription_type: Optional[str]
    rate_limit_tier: Optional[str]
    error: Optional[str]


def _format_limit(limit) -> Optional[UsageLimitResponse]:
    """Format a UsageLimit for API response."""
    if not limit:
        return None
    return UsageLimitResponse(
        utilization=limit.utilization,
        resets_at=limit.resets_at.isoformat() if limit.resets_at else None,
    )


def _format_extra_usage(extra) -> Optional[ExtraUsageResponse]:
    """Format ExtraUsage for API response."""
    if not extra:
        return None
    return ExtraUsageResponse(
        is_enabled=extra.is_enabled,
        monthly_limit=extra.monthly_limit,
        used_credits=extra.used_credits,
        utilization=extra.utilization,
    )


@router.get("/usage", response_model=ClaudeUsageResponse)
async def get_usage() -> ClaudeUsageResponse:
    """
    Get current Claude usage limits.

    Returns usage information for 5-hour and 7-day windows,
    as well as subscription details. Credentials are first looked up
    in the vault ({vault}/.claude/.credentials.json) for self-contained
    operation, then falls back to ~/.claude/.credentials.json.
    """
    settings = get_settings()
    vault_path = Path(settings.vault_path) if settings.vault_path else None

    usage = await fetch_claude_usage(vault_path)

    return ClaudeUsageResponse(
        five_hour=_format_limit(usage.five_hour),
        seven_day=_format_limit(usage.seven_day),
        seven_day_sonnet=_format_limit(usage.seven_day_sonnet),
        seven_day_opus=_format_limit(usage.seven_day_opus),
        extra_usage=_format_extra_usage(usage.extra_usage),
        subscription_type=usage.subscription_type,
        rate_limit_tier=usage.rate_limit_tier,
        error=usage.error,
    )
