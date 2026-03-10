"""
Credential broker API endpoints.

Provides short-lived, scoped credentials to sandboxed containers via a
generalized provider system. Containers call these endpoints via transparent
credential helpers (git credential helper, gh CLI wrapper, env vars).

Endpoints are protected by a bearer secret shared between the host and containers.
"""

import hmac
import logging
import re

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from parachute.config import get_settings
from parachute.lib.credentials import CredentialProviderError, get_broker

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/credentials", tags=["credentials"])

# Org names: alphanumeric start, then alphanumeric/hyphens/underscores, max 39 chars
_ORG_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]{0,38}$")
# Provider names: lowercase alphanumeric with hyphens/underscores, max 32 chars
_PROVIDER_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")


class TokenResponse(BaseModel):
    """Response containing a short-lived credential token."""

    token: str = Field(..., description="Short-lived credential token")
    expires_at: str = Field(..., description="ISO 8601 expiry timestamp")


class BrokerStatusResponse(BaseModel):
    """Response containing broker configuration status."""

    configured: bool
    providers: dict[str, dict[str, str]] = Field(default_factory=dict)


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


def _validate_org(org: str) -> None:
    """Validate org name format to prevent URL injection.

    GitHub org names: alphanumeric start, alphanumeric/hyphens/underscores, max 39 chars.
    """
    if not _ORG_RE.match(org):
        raise HTTPException(status_code=400, detail="Invalid org name format")


def _validate_provider(provider: str) -> None:
    """Validate provider name format to prevent log injection and enumeration."""
    if not _PROVIDER_RE.match(provider):
        raise HTTPException(status_code=400, detail="Invalid provider name")


def _handle_provider_error(e: CredentialProviderError, provider: str) -> HTTPException:
    """Map CredentialProviderError to appropriate HTTP status code.

    - "No ... installation for org" / "scope must include" → 404 (not found / bad request)
    - "Network error" / "Failed to mint" → 502 (upstream failure)
    - Other → 500
    """
    msg = str(e)
    if "installation for org" in msg or "scope must include" in msg:
        return HTTPException(status_code=404, detail=msg)
    elif "Network error" in msg or "Failed to mint" in msg or "API error" in msg:
        return HTTPException(status_code=502, detail=msg)
    else:
        return HTTPException(status_code=500, detail=msg)


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
    _validate_org(org)

    broker = get_broker()
    if not broker.has_provider("github"):
        raise HTTPException(status_code=503, detail="GitHub provider not configured")

    try:
        result = await broker.mint_token("github", {"org": org})
    except CredentialProviderError as e:
        logger.error(f"Failed to mint GitHub token for org '{org}': {e}")
        raise _handle_provider_error(e, "github")

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
    _validate_provider(provider)

    if org:
        _validate_org(org)

    broker = get_broker()
    if not broker.has_provider(provider):
        raise HTTPException(
            status_code=503,
            detail="Requested provider not configured",
        )

    # Build scope from query params
    scope: dict = {}
    if org:
        scope["org"] = org

    try:
        result = await broker.mint_token(provider, scope)
    except CredentialProviderError as e:
        logger.error(f"Failed to mint {provider} token: {e}")
        raise _handle_provider_error(e, provider)

    return TokenResponse(token=result.token, expires_at=result.expires_at)


# ── Status endpoint ──────────────────────────────────────────────────────────


@router.get("/status", response_model=BrokerStatusResponse)
async def get_broker_status(request: Request):
    """
    Check credential broker configuration status.

    Returns which providers are configured. No sensitive data is exposed.
    Requires authentication to prevent provider enumeration.
    """
    _validate_broker_secret(request)
    broker = get_broker()
    status = broker.get_status()
    return BrokerStatusResponse(
        configured=status["configured"],
        providers=status["providers"],
    )
