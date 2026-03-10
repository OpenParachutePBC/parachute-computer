"""
Credential broker API endpoints.

Provides short-lived, scoped credentials to sandboxed containers via a
generalized provider system. Containers call these endpoints via transparent
credential helpers (git credential helper, gh CLI wrapper, env vars).

Endpoints are protected by a bearer secret shared between the host and containers.
"""

import hmac
import logging

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from parachute.config import get_settings
from parachute.lib.credentials import CredentialProviderError, get_broker

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/credentials", tags=["credentials"])


class TokenResponse(BaseModel):
    """Response containing a short-lived credential token."""

    token: str = Field(..., description="Short-lived credential token")
    expires_at: str = Field(..., description="ISO 8601 expiry timestamp")


class BrokerStatusResponse(BaseModel):
    """Response containing broker configuration status."""

    configured: bool
    providers: dict[str, dict] = Field(default_factory=dict)


def _validate_broker_secret(request: Request) -> None:
    """Validate the Authorization header against the broker secret.

    Uses constant-time comparison to prevent timing attacks.
    Raises HTTPException 401 if invalid or not configured.
    """
    settings = get_settings()
    broker_secret = settings.credential_broker_secret
    if not broker_secret:
        raise HTTPException(status_code=503, detail="Credential broker not configured")

    auth_header = request.headers.get("authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Invalid broker secret")

    provided = auth_header[7:]
    if not hmac.compare_digest(provided.encode(), broker_secret.encode()):
        raise HTTPException(status_code=401, detail="Invalid broker secret")


# ── GitHub-specific endpoint (backward compat for existing scripts) ──────────


@router.get("/github/token", response_model=TokenResponse)
async def get_github_token(request: Request, org: str):
    """
    Mint a short-lived GitHub App installation token for an org.

    Called by the git credential helper and gh CLI wrapper in sandbox containers.
    The org-to-installation resolution happens server-side — containers only need
    to know the org name from the git remote URL.

    This is a convenience endpoint that dispatches to the generalized
    /{provider}/token endpoint with scope={"org": org}.
    """
    _validate_broker_secret(request)

    broker = get_broker()
    if not broker.has_provider("github"):
        raise HTTPException(status_code=503, detail="GitHub provider not configured")

    try:
        result = await broker.mint_token("github", {"org": org})
    except CredentialProviderError as e:
        logger.error(f"Failed to mint GitHub token for org '{org}': {e}")
        raise HTTPException(status_code=404, detail=str(e))

    return TokenResponse(token=result.token, expires_at=result.expires_at)


# ── Generalized endpoint ─────────────────────────────────────────────────────


@router.get("/{provider}/token", response_model=TokenResponse)
async def mint_token(request: Request, provider: str, org: str | None = None):
    """
    Mint a short-lived token for any configured provider.

    The scope is passed as query parameters. For GitHub: ?org=unforced.
    For Cloudflare: scope is inferred from the project's grants.

    Requires Bearer authentication with the broker secret.
    """
    _validate_broker_secret(request)

    broker = get_broker()
    if not broker.has_provider(provider):
        raise HTTPException(
            status_code=503,
            detail=f"Provider '{provider}' not configured",
        )

    # Build scope from query params
    scope: dict = {}
    if org:
        scope["org"] = org

    try:
        result = await broker.mint_token(provider, scope)
    except CredentialProviderError as e:
        logger.error(f"Failed to mint {provider} token: {e}")
        raise HTTPException(status_code=404, detail=str(e))

    return TokenResponse(token=result.token, expires_at=result.expires_at)


# ── Status endpoint ──────────────────────────────────────────────────────────


@router.get("/status", response_model=BrokerStatusResponse)
async def get_broker_status(request: Request):
    """
    Check credential broker configuration status.

    Returns which providers are configured. No sensitive data is exposed.
    """
    broker = get_broker()
    status = broker.get_status()
    return BrokerStatusResponse(
        configured=status["configured"],
        providers=status["providers"],
    )
