"""
Claude usage tracking service.

Fetches usage limits from Claude's OAuth API using credentials
stored by Claude Code. When Parachute is fully self-contained,
credentials are stored at {vault}/.claude/.credentials.json.
"""

import json
import logging
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

import httpx

logger = logging.getLogger(__name__)

USAGE_API_URL = "https://api.anthropic.com/api/oauth/usage"


@dataclass
class UsageLimit:
    """A single usage limit bucket."""
    utilization: float  # Percentage used (0-100)
    resets_at: Optional[datetime]


@dataclass
class ExtraUsage:
    """Extra usage credits (for Max plan)."""
    is_enabled: bool
    monthly_limit: int
    used_credits: float
    utilization: float


@dataclass
class ClaudeUsage:
    """Complete Claude usage information."""
    five_hour: Optional[UsageLimit]
    seven_day: Optional[UsageLimit]
    seven_day_sonnet: Optional[UsageLimit]
    seven_day_opus: Optional[UsageLimit]
    extra_usage: Optional[ExtraUsage]
    subscription_type: Optional[str]  # "pro", "max", etc.
    rate_limit_tier: Optional[str]
    error: Optional[str] = None


def get_claude_credentials(vault_path: Optional[Path] = None) -> Optional[dict]:
    """
    Retrieve Claude Code credentials.

    When vault_path is provided, looks for credentials in {vault}/.claude/.credentials.json
    (self-contained Parachute mode). Otherwise falls back to ~/.claude/.credentials.json.

    Returns the full credentials dict or None if not available.
    """
    # Try vault-based credentials first if vault_path is provided
    if vault_path:
        creds_path = vault_path / ".claude" / ".credentials.json"
        if creds_path.exists():
            try:
                with open(creds_path) as f:
                    creds = json.load(f)
                logger.debug(f"Using vault credentials from {creds_path}")
                return creds
            except (json.JSONDecodeError, Exception) as e:
                logger.warning(f"Failed to read vault credentials: {e}")

    # Fall back to system-wide credentials
    creds_path = Path.home() / ".claude" / ".credentials.json"
    if not creds_path.exists():
        logger.debug(f"Credentials file not found: {creds_path}")
        return None

    try:
        with open(creds_path) as f:
            creds = json.load(f)
        return creds
    except json.JSONDecodeError as e:
        logger.warning(f"Failed to parse credentials file: {e}")
        return None
    except Exception as e:
        logger.warning(f"Error reading credentials file: {e}")
        return None


def _parse_datetime(s: Optional[str]) -> Optional[datetime]:
    """Parse ISO datetime string."""
    if not s:
        return None
    try:
        # Handle timezone-aware ISO format
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def _parse_limit(data: Optional[dict]) -> Optional[UsageLimit]:
    """Parse a usage limit from API response."""
    if not data:
        return None
    return UsageLimit(
        utilization=data.get("utilization", 0),
        resets_at=_parse_datetime(data.get("resets_at")),
    )


def _parse_extra_usage(data: Optional[dict]) -> Optional[ExtraUsage]:
    """Parse extra usage from API response."""
    if not data:
        return None
    # Only return ExtraUsage if it's actually enabled
    # When disabled, the other fields are null
    if not data.get("is_enabled", False):
        return None
    return ExtraUsage(
        is_enabled=True,
        monthly_limit=data.get("monthly_limit") or 0,
        used_credits=data.get("used_credits") or 0,
        utilization=data.get("utilization") or 0,
    )


async def fetch_claude_usage(vault_path: Optional[Path] = None) -> ClaudeUsage:
    """
    Fetch current Claude usage from the API.

    Args:
        vault_path: Optional vault path for self-contained credentials

    Returns a ClaudeUsage object with current limits, or with an error
    message if the fetch failed.
    """
    creds = get_claude_credentials(vault_path)

    if not creds:
        return ClaudeUsage(
            five_hour=None,
            seven_day=None,
            seven_day_sonnet=None,
            seven_day_opus=None,
            extra_usage=None,
            subscription_type=None,
            rate_limit_tier=None,
            error="Claude Code credentials not found in keychain",
        )

    oauth_data = creds.get("claudeAiOauth", {})
    access_token = oauth_data.get("accessToken")

    if not access_token:
        return ClaudeUsage(
            five_hour=None,
            seven_day=None,
            seven_day_sonnet=None,
            seven_day_opus=None,
            extra_usage=None,
            subscription_type=None,
            rate_limit_tier=None,
            error="No access token in Claude Code credentials",
        )

    # Extract subscription info from credentials
    subscription_type = oauth_data.get("subscriptionType")
    rate_limit_tier = oauth_data.get("rateLimitTier")

    try:
        async with httpx.AsyncClient() as client:
            response = await client.get(
                USAGE_API_URL,
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "User-Agent": "claude-code/2.0.31",
                    "Authorization": f"Bearer {access_token}",
                    "anthropic-beta": "oauth-2025-04-20",
                },
                timeout=10.0,
            )

            if response.status_code != 200:
                return ClaudeUsage(
                    five_hour=None,
                    seven_day=None,
                    seven_day_sonnet=None,
                    seven_day_opus=None,
                    extra_usage=None,
                    subscription_type=subscription_type,
                    rate_limit_tier=rate_limit_tier,
                    error=f"API request failed: {response.status_code}",
                )

            data = response.json()

            return ClaudeUsage(
                five_hour=_parse_limit(data.get("five_hour")),
                seven_day=_parse_limit(data.get("seven_day")),
                seven_day_sonnet=_parse_limit(data.get("seven_day_sonnet")),
                seven_day_opus=_parse_limit(data.get("seven_day_opus")),
                extra_usage=_parse_extra_usage(data.get("extra_usage")),
                subscription_type=subscription_type,
                rate_limit_tier=rate_limit_tier,
            )

    except httpx.TimeoutException:
        return ClaudeUsage(
            five_hour=None,
            seven_day=None,
            seven_day_sonnet=None,
            seven_day_opus=None,
            extra_usage=None,
            subscription_type=subscription_type,
            rate_limit_tier=rate_limit_tier,
            error="Request timed out",
        )
    except Exception as e:
        logger.exception("Error fetching Claude usage")
        return ClaudeUsage(
            five_hour=None,
            seven_day=None,
            seven_day_sonnet=None,
            seven_day_opus=None,
            extra_usage=None,
            subscription_type=subscription_type,
            rate_limit_tier=rate_limit_tier,
            error=str(e),
        )
