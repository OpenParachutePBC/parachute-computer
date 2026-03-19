"""
API endpoints for Claude model selection.

Returns a static list of model families (opus, sonnet, haiku).
The Claude Code CLI resolves short names to the latest version.
"""

from typing import Optional

from fastapi import APIRouter
from pydantic import BaseModel, Field

from parachute.config import get_settings

router = APIRouter(prefix="/models")

# Static model list — CLI resolves short names to latest versions
AVAILABLE_MODELS = [
    {"id": "opus", "display_name": "Opus", "family": "opus"},
    {"id": "sonnet", "display_name": "Sonnet", "family": "sonnet"},
    {"id": "haiku", "display_name": "Haiku", "family": "haiku"},
]


class ModelsListResponse(BaseModel):
    """Response from GET /api/models."""
    models: list
    current_model: Optional[str]


@router.get("", response_model=ModelsListResponse, status_code=200)
async def list_models() -> ModelsListResponse:
    """
    Return available Claude model families.

    Returns a static list — the Claude Code CLI resolves short names
    (opus, sonnet, haiku) to the latest version at runtime.
    """
    settings = get_settings()

    return ModelsListResponse(
        models=AVAILABLE_MODELS,
        current_model=settings.default_model,
    )
