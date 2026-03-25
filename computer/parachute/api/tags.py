"""
Universal tag API — graph-native tags across all entity types.

Replaces the chat-specific tag endpoints in sessions.py with a unified
surface. Any entity in the brain graph can be tagged via TAGGED_WITH edges.
"""

import re
from typing import Any

from fastapi import APIRouter, HTTPException, Query, Request

from parachute.db.brain_chat_store import BrainChatStore

router = APIRouter(prefix="/tags")

_TAG_RE = re.compile(r"[a-z0-9](?:[a-z0-9\-]{0,46}[a-z0-9])?")
_VALID_TAGGED_BY = {"user", "agent", "api"}


def _get_store(request: Request) -> BrainChatStore:
    db = request.app.state.session_store
    if not db:
        raise HTTPException(status_code=503, detail="Database not ready")
    return db


# ── Global tag endpoints ─────────────────────────────────────────────────


@router.get("")
async def list_tags(request: Request) -> dict[str, Any]:
    """List all tags with usage counts."""
    db = _get_store(request)
    tags = await db.list_all_tags()
    return {"tags": tags}


@router.get("/{tag}")
async def get_entities_by_tag(
    request: Request,
    tag: str,
    type: str | None = Query(None, description="Filter by entity type: chat, note, card, entity, agent"),
    limit: int = Query(50, ge=1, le=500),
) -> dict[str, Any]:
    """Get all entities with a given tag, optionally filtered by type."""
    db = _get_store(request)
    tag = tag.lower().strip()
    if type and type not in BrainChatStore.TAG_ENTITY_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown entity type: {type}. Valid: {', '.join(BrainChatStore.TAG_ENTITY_TYPES)}",
        )
    entities = await db.get_entities_by_tag(tag, entity_type=type, limit=limit)
    return {"tag": tag, "entities": entities, "count": len(entities)}


# ── Per-entity tag endpoints ─────────────────────────────────────────────


@router.get("/{entity_type}/{entity_id:path}")
async def get_entity_tags(
    request: Request,
    entity_type: str,
    entity_id: str,
) -> dict[str, Any]:
    """List tags for a specific entity."""
    db = _get_store(request)
    if entity_type not in BrainChatStore.TAG_ENTITY_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown entity type: {entity_type}. Valid: {', '.join(BrainChatStore.TAG_ENTITY_TYPES)}",
        )
    tags = await db.get_entity_tags(entity_type, entity_id)
    return {"entity_type": entity_type, "entity_id": entity_id, "tags": tags}


@router.post("/{entity_type}/{entity_id:path}")
async def add_entity_tag(
    request: Request,
    entity_type: str,
    entity_id: str,
    body: dict[str, Any],
) -> dict[str, Any]:
    """Add a tag to an entity."""
    db = _get_store(request)
    if entity_type not in BrainChatStore.TAG_ENTITY_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown entity type: {entity_type}. Valid: {', '.join(BrainChatStore.TAG_ENTITY_TYPES)}",
        )
    tag = body.get("tag")
    if not tag or not isinstance(tag, str) or not tag.strip():
        raise HTTPException(status_code=400, detail="Tag is required")
    tag = tag.lower().strip()
    if not _TAG_RE.fullmatch(tag):
        raise HTTPException(
            status_code=400,
            detail="Invalid tag format — lowercase alphanumeric with hyphens, max 48 chars",
        )
    tagged_by = body.get("tagged_by", "user")
    if tagged_by not in _VALID_TAGGED_BY:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid tagged_by: {tagged_by!r}. Valid: {', '.join(sorted(_VALID_TAGGED_BY))}",
        )
    try:
        await db.add_tag(entity_type, entity_id, tag, tagged_by=tagged_by)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"success": True, "entity_type": entity_type, "entity_id": entity_id, "tag": tag}


@router.delete("/{entity_type}/{entity_id:path}/{tag}")
async def remove_entity_tag(
    request: Request,
    entity_type: str,
    entity_id: str,
    tag: str,
) -> dict[str, Any]:
    """Remove a tag from an entity."""
    db = _get_store(request)
    if entity_type not in BrainChatStore.TAG_ENTITY_TYPES:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown entity type: {entity_type}. Valid: {', '.join(BrainChatStore.TAG_ENTITY_TYPES)}",
        )
    try:
        await db.remove_tag(entity_type, entity_id, tag)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    return {"success": True, "entity_type": entity_type, "entity_id": entity_id, "tag": tag, "removed": True}
