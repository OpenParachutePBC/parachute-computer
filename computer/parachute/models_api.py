"""Anthropic Models API client with caching and filtering."""

import asyncio
import logging
from datetime import datetime, timedelta
from typing import Optional

import httpx
from pydantic import BaseModel, Field

logger = logging.getLogger(__name__)


class ModelInfo(BaseModel):
    """Model metadata from Anthropic API."""
    id: str = Field(..., pattern=r"^claude-[a-z0-9\-]+$")
    display_name: str = Field(..., min_length=1)
    created_at: datetime
    family: str  # "opus" | "sonnet" | "haiku"
    is_latest: bool = False


async def fetch_available_models(api_key: str) -> list[ModelInfo]:
    """
    Query Anthropic /v1/models and return filtered model list.

    Handles pagination (though likely <50 models total).
    Uses httpx.AsyncClient (never sync httpx.get).
    """
    all_models: list[ModelInfo] = []
    after_id: Optional[str] = None

    async with httpx.AsyncClient(timeout=10.0) as client:
        while True:
            params = {"limit": 100}  # Right-sized (not 1000)
            if after_id:
                params["after_id"] = after_id

            response = await client.get(
                "https://api.anthropic.com/v1/models",
                headers={
                    "x-api-key": api_key,
                    "anthropic-version": "2023-06-01"
                },
                params=params
            )
            response.raise_for_status()

            data = response.json()

            # Parse models from API response
            for model_data in data["data"]:
                model = ModelInfo(
                    id=model_data["id"],
                    display_name=model_data.get("display_name", model_data["id"]),
                    created_at=datetime.fromisoformat(model_data["created_at"].replace("Z", "+00:00")),
                    family=_extract_family(model_data["id"]),
                )
                all_models.append(model)

            if not data.get("has_more"):
                break

            after_id = data["data"][-1]["id"]

    return _filter_and_sort_models(all_models)


def _extract_family(model_id: str) -> str:
    """Extract family from model ID: claude-{family}-*"""
    parts = model_id.split('-')
    if len(parts) >= 2:
        return parts[1]  # "opus", "sonnet", "haiku"
    return "unknown"


def _filter_and_sort_models(models: list[ModelInfo]) -> list[ModelInfo]:
    """
    Group by family, mark latest per family.

    Filtering strategy:
    - Default view: latest per family (3-5 models)
    - "Show all" view: all Claude models with dated versions
    """
    # Group by family
    by_family: dict[str, list[ModelInfo]] = {}
    for model in models:
        if model.family not in by_family:
            by_family[model.family] = []
        by_family[model.family].append(model)

    # Sort each family by created_at (newest first)
    for family in by_family:
        by_family[family].sort(key=lambda m: m.created_at, reverse=True)

    # Mark latest per family
    result = []
    for family, family_models in by_family.items():
        if family_models:
            family_models[0].is_latest = True  # First = newest
        result.extend(family_models)

    return result


class ModelsCache:
    """Thread-safe cache for Anthropic model list (1-hour TTL)."""

    def __init__(self, ttl_seconds: int = 3600):
        self._models: list[ModelInfo] = []
        self._cached_at: Optional[datetime] = None
        self._ttl = timedelta(seconds=ttl_seconds)
        self._lock = asyncio.Lock()  # Use asyncio.Lock for async code

    async def get(self, api_key: str) -> tuple[list[ModelInfo], Optional[datetime], bool]:
        """
        Get cached models if fresh, else fetch from API.

        Returns: (models, cached_at, is_stale)
        """
        async with self._lock:
            now = datetime.now()

            # Return fresh cache
            if self._cached_at and (now - self._cached_at) < self._ttl:
                return self._models, self._cached_at, False

            # Cache miss or stale — fetch from API
            try:
                self._models = await fetch_available_models(api_key)
                self._cached_at = now
                return self._models, self._cached_at, False
            except Exception as e:
                logger.error(f"Anthropic API error: {e}")

                # Return stale cache if available
                if self._models:
                    return self._models, self._cached_at, True

                raise


# Global cache instance
_models_cache = ModelsCache(ttl_seconds=3600)


async def get_cached_models(api_key: str, show_all: bool = False) -> dict:
    """
    Get models with caching.

    Args:
        api_key: Anthropic API key
        show_all: If true, return all models. If false, filter to latest per family.

    Returns:
        {
            "models": [...],
            "cached_at": datetime,
            "is_stale": bool
        }
    """
    models, cached_at, is_stale = await _models_cache.get(api_key)

    if not show_all:
        # Filter to latest per family only
        models = [m for m in models if m.is_latest]

    return {
        "models": models,
        "cached_at": cached_at,
        "is_stale": is_stale,
    }
