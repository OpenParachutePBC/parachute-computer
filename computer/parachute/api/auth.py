"""
API key management endpoints.

These endpoints allow managing API keys for remote device access.
All endpoints require localhost access or a valid existing API key.
"""

from datetime import datetime
from typing import Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field

from parachute.lib.auth import create_api_key
from parachute.lib.server_config import get_server_config, AuthMode

router = APIRouter(prefix="/auth", tags=["auth"])


class CreateKeyRequest(BaseModel):
    """Request to create a new API key."""

    label: str = Field(..., description="Human-readable label for the key", min_length=1, max_length=100)


class CreateKeyResponse(BaseModel):
    """Response containing the new API key."""

    id: str = Field(..., description="Key ID for display/revocation")
    label: str
    key: str = Field(..., description="The full API key - shown only once!")
    created_at: datetime


class KeyInfo(BaseModel):
    """API key information (without the actual key)."""

    id: str
    label: str
    created_at: datetime
    last_used_at: Optional[datetime] = None


class ListKeysResponse(BaseModel):
    """Response containing all API keys."""

    keys: list[KeyInfo]
    auth_mode: str


class AuthSettingsRequest(BaseModel):
    """Request to update auth settings."""

    require_auth: str = Field(..., description="Auth mode: 'always', 'remote', or 'disabled'")


class AuthSettingsResponse(BaseModel):
    """Response containing current auth settings."""

    require_auth: str
    key_count: int


@router.get("/keys", response_model=ListKeysResponse)
async def list_keys(request: Request):
    """
    List all API keys.

    Returns key metadata (IDs, labels, timestamps) but never the actual keys.
    """
    server_config = get_server_config()
    if not server_config:
        raise HTTPException(status_code=500, detail="Server config not initialized")

    keys = [
        KeyInfo(
            id=k.id,
            label=k.label,
            created_at=k.created_at,
            last_used_at=k.last_used_at,
        )
        for k in server_config.security.api_keys
    ]

    return ListKeysResponse(
        keys=keys,
        auth_mode=server_config.security.require_auth.value,
    )


@router.post("/keys", response_model=CreateKeyResponse)
async def create_key(request: Request, body: CreateKeyRequest):
    """
    Create a new API key.

    The full key is returned exactly once in this response.
    Store it securely - it cannot be retrieved again.
    """
    server_config = get_server_config()
    if not server_config:
        raise HTTPException(status_code=500, detail="Server config not initialized")

    # Create the key
    api_key, plaintext_key = create_api_key(body.label)

    # Store it
    server_config.add_api_key(api_key)

    return CreateKeyResponse(
        id=api_key.id,
        label=api_key.label,
        key=plaintext_key,
        created_at=api_key.created_at,
    )


@router.delete("/keys/{key_id}")
async def delete_key(request: Request, key_id: str):
    """
    Revoke an API key.

    The key will immediately stop working for authentication.
    """
    server_config = get_server_config()
    if not server_config:
        raise HTTPException(status_code=500, detail="Server config not initialized")

    if not server_config.remove_api_key(key_id):
        raise HTTPException(status_code=404, detail=f"Key not found: {key_id}")

    return {"status": "deleted", "id": key_id}


@router.get("/settings", response_model=AuthSettingsResponse)
async def get_auth_settings(request: Request):
    """Get current authentication settings."""
    server_config = get_server_config()
    if not server_config:
        raise HTTPException(status_code=500, detail="Server config not initialized")

    return AuthSettingsResponse(
        require_auth=server_config.security.require_auth.value,
        key_count=len(server_config.security.api_keys),
    )


@router.put("/settings", response_model=AuthSettingsResponse)
async def update_auth_settings(request: Request, body: AuthSettingsRequest):
    """
    Update authentication settings.

    WARNING: Setting require_auth to 'disabled' removes all authentication.
    Only use this for development.
    """
    server_config = get_server_config()
    if not server_config:
        raise HTTPException(status_code=500, detail="Server config not initialized")

    try:
        auth_mode = AuthMode(body.require_auth)
    except ValueError:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid auth mode: {body.require_auth}. Must be 'always', 'remote', or 'disabled'",
        )

    server_config.security.require_auth = auth_mode
    server_config.save()

    return AuthSettingsResponse(
        require_auth=server_config.security.require_auth.value,
        key_count=len(server_config.security.api_keys),
    )
