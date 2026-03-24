"""
API provider management endpoints.

Lets users configure and switch between Anthropic-compatible API backends
(e.g., Moonshot/Kimi K2.5, Synthetic.new, self-hosted proxies).
"""

import logging
import re
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from parachute.config import (
    PARACHUTE_DIR,
    get_settings,
    reload_settings,
    save_yaml_config_atomic,
)

router = APIRouter()
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------

class ProviderCreate(BaseModel):
    """Request body for adding/updating a provider."""

    label: Optional[str] = Field(default=None, description="Human-readable label")
    base_url: str = Field(description="Anthropic-compatible API base URL")
    api_key: str = Field(description="API key for the provider")
    default_model: Optional[str] = Field(
        default=None,
        description="Default model to use with this provider (e.g., 'kimi-k2.5')",
    )


class ActiveProviderUpdate(BaseModel):
    """Request body for switching the active provider."""

    provider: Optional[str] = Field(
        default=None,
        description="Provider name to activate, or null for Anthropic default",
    )


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]*$")


def _redact_key(key: str) -> str:
    """Return a redacted hint for an API key (last 4 chars)."""
    if len(key) <= 4:
        return "****"
    return f"...{key[-4:]}"


def _provider_response(name: str, cfg: dict, is_active: bool) -> dict:
    """Build a safe provider response dict (keys redacted)."""
    return {
        "name": name,
        "label": cfg.get("label", name),
        "base_url": cfg.get("base_url", ""),
        "key_hint": _redact_key(cfg.get("api_key", "")),
        "default_model": cfg.get("default_model"),
        "active": is_active,
    }


def _validate_name(name: str) -> None:
    """Validate provider name (lowercase alphanumeric + hyphens/underscores)."""
    if not _NAME_RE.match(name):
        raise HTTPException(
            status_code=400,
            detail="Provider name must be lowercase alphanumeric with hyphens/underscores",
        )


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.get("/providers")
async def list_providers() -> dict:
    """List all configured API providers and which is active."""
    settings = get_settings()
    active = settings.api_provider
    providers = [
        _provider_response(name, cfg, name == active)
        for name, cfg in settings.api_providers.items()
    ]
    return {
        "active": active,
        "providers": providers,
    }


@router.post("/providers/{name}", status_code=201)
async def add_provider(name: str, body: ProviderCreate) -> dict:
    """Add or update a named API provider."""
    _validate_name(name)

    settings = get_settings()
    providers = dict(settings.api_providers)
    is_new = name not in providers

    providers[name] = {
        "label": body.label or name,
        "base_url": body.base_url.rstrip("/"),
        "api_key": body.api_key,
        **({"default_model": body.default_model} if body.default_model else {}),
    }

    save_yaml_config_atomic(PARACHUTE_DIR, {"api_providers": providers})
    reload_settings()

    logger.info(f"{'Added' if is_new else 'Updated'} API provider: {name}")
    return {
        "ok": True,
        "provider": _provider_response(name, providers[name], name == settings.api_provider),
    }


@router.delete("/providers/{name}")
async def remove_provider(name: str) -> dict:
    """Remove a named API provider."""
    settings = get_settings()
    providers = dict(settings.api_providers)

    if name not in providers:
        raise HTTPException(status_code=404, detail=f"Provider '{name}' not found")

    del providers[name]

    # If deleting the active provider, clear active
    updates: dict = {"api_providers": providers}
    if settings.api_provider == name:
        updates["api_provider"] = None

    save_yaml_config_atomic(PARACHUTE_DIR, updates)
    reload_settings()

    logger.info(f"Removed API provider: {name}")
    return {"ok": True, "active": updates.get("api_provider", settings.api_provider)}


@router.put("/providers/active")
async def set_active_provider(body: ActiveProviderUpdate) -> dict:
    """Switch the active API provider (or set to null for Anthropic default)."""
    settings = get_settings()

    if body.provider is not None:
        if body.provider not in settings.api_providers:
            raise HTTPException(
                status_code=404,
                detail=f"Provider '{body.provider}' not found. Add it first.",
            )

    save_yaml_config_atomic(PARACHUTE_DIR, {"api_provider": body.provider})
    new_settings = reload_settings()

    provider_label = body.provider or "Anthropic (default)"
    logger.info(f"Switched active API provider to: {provider_label}")

    # Return the effective model so the app can update its display
    effective_model = None
    if body.provider:
        cfg = new_settings.api_providers.get(body.provider, {})
        effective_model = cfg.get("default_model")
    effective_model = effective_model or new_settings.default_model

    return {
        "ok": True,
        "active": body.provider,
        "effective_model": effective_model,
    }
