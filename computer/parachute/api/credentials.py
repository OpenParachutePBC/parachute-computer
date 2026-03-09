"""
Credential broker API endpoints.

Provides short-lived GitHub App installation tokens to sandboxed containers.
Containers call these endpoints via transparent credential helpers (git credential
helper + gh CLI wrapper) — the agent never sees the token directly.

Endpoints are protected by a bearer secret shared between the host and containers.
"""

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


class InstallationResponse(BaseModel):
    """Response containing an installation ID for an org."""

    installation_id: int
    org: str


class BrokerStatusResponse(BaseModel):
    """Response containing broker configuration status."""

    configured: bool
    app_id: int | None = None
    installations: dict[str, int] = Field(default_factory=dict)


def _validate_broker_secret(request: Request) -> None:
    """Validate the Authorization header against the broker secret.

    Raises HTTPException 401 if invalid or not configured.
    """
    settings = get_settings()
    broker_secret = settings.github_broker_secret
    if not broker_secret:
        raise HTTPException(status_code=503, detail="Credential broker not configured")

    auth_header = request.headers.get("authorization", "")
    if not auth_header.startswith("Bearer ") or auth_header[7:] != broker_secret:
        raise HTTPException(status_code=401, detail="Invalid broker secret")


@router.get("/github/token", response_model=GitHubTokenResponse)
async def get_github_token(request: Request, installation_id: int):
    """
    Mint a short-lived GitHub App installation token.

    Called by the git credential helper and gh CLI wrapper in sandbox containers.
    Requires Bearer authentication with the broker secret.
    """
    _validate_broker_secret(request)

    broker = get_broker()
    if not broker:
        raise HTTPException(status_code=503, detail="GitHub App broker not configured")

    # Verify this installation_id is in our configured installations
    valid_ids = set(broker.installations.values())
    if installation_id not in valid_ids:
        raise HTTPException(
            status_code=404,
            detail=f"Unknown installation ID: {installation_id}",
        )

    try:
        result = await broker.get_token(installation_id)
    except GitHubAppError as e:
        logger.error(f"Failed to mint token for installation {installation_id}: {e}")
        raise HTTPException(status_code=502, detail=str(e))

    return GitHubTokenResponse(token=result["token"], expires_at=result["expires_at"])


@router.get("/github/installation", response_model=InstallationResponse)
async def get_installation(request: Request, org: str):
    """
    Resolve a GitHub org/account name to an installation ID.

    Convenience endpoint so credential helpers don't need a local copy
    of the installations mapping.
    """
    _validate_broker_secret(request)

    broker = get_broker()
    if not broker:
        raise HTTPException(status_code=503, detail="GitHub App broker not configured")

    installation_id = broker.get_installation_id(org)
    if installation_id is None:
        raise HTTPException(
            status_code=404,
            detail=f"No GitHub App installation for org: {org}",
        )

    return InstallationResponse(installation_id=installation_id, org=org)


@router.get("/github/status", response_model=BrokerStatusResponse)
async def get_broker_status(request: Request):
    """
    Check credential broker configuration status.

    This endpoint does NOT require broker secret authentication —
    it only returns whether the broker is configured, not any secrets.
    """
    broker = get_broker()
    if not broker:
        return BrokerStatusResponse(configured=False)

    return BrokerStatusResponse(
        configured=True,
        app_id=broker.app_id,
        installations=broker.installations,
    )
