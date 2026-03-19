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
# Env var names: uppercase letters/digits/underscores, 1-64 chars
_ENV_VAR_RE = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")


class TokenResponse(BaseModel):
    """Response containing a short-lived credential token."""

    token: str = Field(..., description="Short-lived credential token")
    expires_at: str = Field(..., description="ISO 8601 expiry timestamp")


class BrokerStatusResponse(BaseModel):
    """Response containing broker configuration status."""

    configured: bool
    providers: dict[str, dict] = Field(default_factory=dict)


class SetupRequest(BaseModel):
    """Request to configure a credential helper."""

    name: str = Field(..., description="Helper name (e.g., 'github')")
    method: str = Field(..., description="Setup method (e.g., 'personal-token')")
    fields: dict[str, str] = Field(default_factory=dict, description="Field values")


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


def _validate_setup_auth(request: Request) -> None:
    """Validate that setup/delete requests come from localhost or carry a valid secret.

    Config-mutating endpoints require either:
    - Request from localhost (127.0.0.1 / ::1) — the server owner
    - Valid broker secret in Authorization header — programmatic access
    """
    client_host = request.client.host if request.client else None
    if client_host in ("127.0.0.1", "::1", "localhost"):
        return  # Localhost is trusted

    # Not localhost — require broker secret
    _validate_broker_secret(request)


def _validate_no_newlines(value: str, field_name: str) -> str:
    """Reject values containing newlines to prevent env var injection."""
    if "\n" in value or "\r" in value:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid {field_name}: must not contain newlines",
        )
    return value


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


# ── Helper manifests (for app UI) ────────────────────────────────────────────


@router.get("/helpers")
async def get_helpers():
    """
    List all credential helper manifests.

    Returns manifest JSON for each registered helper, describing setup
    fields, capabilities, and health check info. The app renders setup
    forms generically from these manifests.

    No authentication required — manifests contain no sensitive data.
    """
    broker = get_broker()
    return broker.get_manifests()


# ── Setup endpoint ────────────────────────────────────────────────────────────


@router.post("/setup")
async def setup_helper(request: Request, body: SetupRequest):
    """
    Configure a credential helper.

    Validates the provided fields, saves to config, and reloads the broker.
    Used by both the CLI wizard and the app UI.

    Requires localhost or valid broker secret — config mutation must be authenticated.
    """
    _validate_setup_auth(request)

    from parachute.config import get_settings, save_yaml_config_atomic
    from parachute.lib.credentials.broker import reset_broker

    settings = get_settings()
    name = body.name
    method = body.method
    fields = body.fields

    # Build the config entry based on method
    if method == "personal-token":
        token = _validate_no_newlines(fields.get("token", "").strip(), "token")
        if not token:
            raise HTTPException(status_code=400, detail="Token is required")
        config_entry = {
            "type": "personal-token",
            "token": token,
        }
    elif method == "github-app":
        app_id = fields.get("app_id", "").strip()
        if not app_id:
            raise HTTPException(status_code=400, detail="App ID is required")
        try:
            app_id_int = int(app_id)
        except ValueError:
            raise HTTPException(status_code=400, detail="App ID must be a number")
        config_entry = {
            "type": "github-app",
            "app_id": app_id_int,
            "installations": {},  # User adds installations later
        }
    elif method == "cloudflare-parent":
        token = _validate_no_newlines(
            fields.get("parent_token", "").strip(), "parent_token"
        )
        if not token:
            raise HTTPException(status_code=400, detail="Parent token is required")
        config_entry = {
            "type": "cloudflare-parent",
            "parent_token": token,
        }
        account_id = fields.get("account_id", "").strip()
        if account_id:
            config_entry["account_id"] = account_id
    elif method == "env-passthrough":
        env_var = fields.get("env_var", "").strip()
        token = _validate_no_newlines(fields.get("token", "").strip(), "token")
        if not env_var or not token:
            raise HTTPException(
                status_code=400, detail="Both env_var and token are required"
            )
        if not _ENV_VAR_RE.match(env_var):
            raise HTTPException(
                status_code=400,
                detail="Invalid env var name (must be UPPERCASE_WITH_UNDERSCORES)",
            )
        config_entry = {
            "type": "env-passthrough",
            "env_var": env_var,
            "token": token,
        }
        display_name = fields.get("display_name", "").strip()
        if display_name:
            config_entry["display_name"] = display_name
        health_url = fields.get("health_url", "").strip()
        if health_url:
            config_entry["health_url"] = health_url
    else:
        raise HTTPException(status_code=400, detail=f"Unknown method: {method}")

    # Update config
    current_providers = dict(settings.credential_providers)
    current_providers[name] = config_entry

    # Ensure broker secret exists
    import secrets

    broker_secret = settings.credential_broker_secret
    if not broker_secret:
        broker_secret = secrets.token_hex(32)

    config_data = {
        "credential_providers": current_providers,
        "credential_broker_secret": broker_secret,
    }

    save_yaml_config_atomic(settings.parachute_dir, config_data)

    # Reset broker to pick up new config
    reset_broker()

    logger.info(f"Configured credential helper '{name}' with method '{method}'")
    return {"status": "ok", "name": name, "method": method}


# ── Remove endpoint ──────────────────────────────────────────────────────────


@router.delete("/{provider}")
async def remove_helper(request: Request, provider: str):
    """
    Remove a configured credential helper.

    Deletes the provider from config and reloads the broker.
    Requires localhost or valid broker secret.
    """
    _validate_setup_auth(request)
    _validate_provider(provider)

    from parachute.config import get_settings, save_yaml_config_atomic
    from parachute.lib.credentials.broker import reset_broker

    settings = get_settings()
    current_providers = dict(settings.credential_providers)

    if provider not in current_providers:
        raise HTTPException(status_code=404, detail=f"Provider '{provider}' not configured")

    del current_providers[provider]

    config_data = {"credential_providers": current_providers}
    save_yaml_config_atomic(settings.parachute_dir, config_data)

    reset_broker()

    logger.info(f"Removed credential helper '{provider}'")
    return {"status": "ok", "removed": provider}
