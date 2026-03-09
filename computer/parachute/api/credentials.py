"""
Credential broker API endpoints.

Provides short-lived GitHub App installation tokens to sandboxed containers.
Containers call these endpoints via transparent credential helpers (git credential
helper + gh CLI wrapper) — the agent never sees the token directly.

Endpoints are protected by a bearer secret shared between the host and containers.
"""

import hmac
import logging

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from parachute.config import get_settings
from parachute.lib.github_app import GitHubAppError, get_broker

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/credentials", tags=["credentials"])


class GitHubTokenResponse(BaseModel):
    """Response containing a short-lived GitHub installation token."""

    token: str = Field(..., description="GitHub installation access token (1-hour expiry)")
    expires_at: str = Field(..., description="ISO 8601 expiry timestamp")


class BrokerStatusResponse(BaseModel):
    """Response containing broker configuration status."""

    configured: bool
    app_id: int | None = None


def _validate_broker_secret(request: Request) -> None:
    """Validate the Authorization header against the broker secret.

    Uses constant-time comparison to prevent timing attacks.
    Raises HTTPException 401 if invalid or not configured.
    """
    settings = get_settings()
    broker_secret = settings.github_broker_secret
    if not broker_secret:
        raise HTTPException(status_code=503, detail="Credential broker not configured")

    auth_header = request.headers.get("authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Invalid broker secret")

    provided = auth_header[7:]
    if not hmac.compare_digest(provided.encode(), broker_secret.encode()):
        raise HTTPException(status_code=401, detail="Invalid broker secret")


@router.get("/github/token", response_model=GitHubTokenResponse)
async def get_github_token(request: Request, org: str):
    """
    Mint a short-lived GitHub App installation token for an org.

    Called by the git credential helper and gh CLI wrapper in sandbox containers.
    The org-to-installation resolution happens server-side — containers only need
    to know the org name from the git remote URL.

    Requires Bearer authentication with the broker secret.
    """
    _validate_broker_secret(request)

    broker = get_broker()
    if not broker:
        raise HTTPException(status_code=503, detail="GitHub App broker not configured")

    try:
        result = await broker.get_token_for_org(org)
    except GitHubAppError as e:
        logger.error(f"Failed to mint token for org '{org}': {e}")
        raise HTTPException(status_code=404, detail=str(e))

    return GitHubTokenResponse(token=result.token, expires_at=result.expires_at)


@router.get("/github/status", response_model=BrokerStatusResponse)
async def get_broker_status(request: Request):
    """
    Check credential broker configuration status.

    Returns only whether the broker is configured and the app ID.
    No sensitive data is exposed.
    """
    broker = get_broker()
    if not broker:
        return BrokerStatusResponse(configured=False)

    return BrokerStatusResponse(
        configured=True,
        app_id=broker.app_id,
    )
