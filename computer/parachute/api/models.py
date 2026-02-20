"""
API endpoints for Claude model selection and management.
"""

import logging
import os
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from parachute.config import get_settings

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/models")


class ModelsListResponse(BaseModel):
    """Response from GET /api/models."""
    models: list
    current_model: Optional[str]
    cached_at: Optional[str]
    is_stale: bool = Field(default=False, description="Whether cache is stale")


@router.get("", response_model=ModelsListResponse, status_code=200)
async def list_models(show_all: bool = False) -> ModelsListResponse:
    """
    Return available Claude models from Anthropic API.

    Args:
        show_all: If false (default), return latest per family only.
                  If true, return all Claude models with dated versions.

    Caching: 1-hour TTL, gracefully degrades if Anthropic API unreachable.
    """
    settings = get_settings()

    # Get API key from config
    api_key = settings.claude_code_oauth_token or os.getenv("CLAUDE_CODE_OAUTH_TOKEN")
    if not api_key:
        raise HTTPException(status_code=503, detail="Anthropic API key not configured")

    try:
        from parachute.models_api import get_cached_models

        result = await get_cached_models(api_key, show_all=show_all)

        # Include current active model from config
        current_model = settings.default_model

        # Convert models to dict for JSON serialization
        models_list = [m.model_dump() for m in result["models"]]

        return ModelsListResponse(
            models=models_list,
            current_model=current_model,
            cached_at=result["cached_at"].isoformat() if result["cached_at"] else None,
            is_stale=result["is_stale"],
        )
    except Exception as e:
        logger.error(f"Failed to fetch models: {e}")
        raise HTTPException(status_code=503, detail=f"Model fetch failed: {e}")
