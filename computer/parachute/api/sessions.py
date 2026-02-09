"""
Session management API endpoints.
"""

import logging
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel, Field

router = APIRouter()
logger = logging.getLogger(__name__)


class SessionConfigUpdate(BaseModel):
    """Request body for updating session configuration."""

    trust_level: Optional[str] = Field(None, alias="trustLevel", description="Trust level: full, vault, sandboxed")
    module: Optional[str] = Field(None, description="Module to use for this session")
    config_overrides: Optional[dict[str, Any]] = Field(
        None,
        alias="configOverrides",
        description="Config overrides merged into session metadata",
    )
    workspace_id: Optional[str] = Field(None, alias="workspaceId", description="Workspace slug for this session")

    model_config = {"populate_by_name": True}


class PermissionGrantRequest(BaseModel):
    """Request body for granting a permission."""

    request_id: str = Field(alias="requestId", description="The permission request ID")
    pattern: Optional[str] = Field(
        None, description="Glob pattern for the grant (e.g., 'Blogs/**/*')"
    )

    model_config = {"populate_by_name": True}


class PermissionDenyRequest(BaseModel):
    """Request body for denying a permission."""

    request_id: str = Field(alias="requestId", description="The permission request ID")

    model_config = {"populate_by_name": True}


def get_orchestrator(request: Request):
    """Get orchestrator from app state."""
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Server not ready")
    return orchestrator


@router.get("/chat")
async def list_sessions(
    request: Request,
    module: Optional[str] = Query(None, description="Filter by module"),
    search: Optional[str] = Query(None, description="Search sessions by title"),
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    archived: Optional[bool] = Query(None, description="Filter by archived status"),
    workspace_id: Optional[str] = Query(None, alias="workspaceId", description="Filter by workspace slug"),
) -> dict[str, Any]:
    """
    List all sessions.

    Query params:
    - module: Filter by module (chat, daily, build)
    - search: Search sessions by title (case-insensitive LIKE match)
    - limit: Maximum number of sessions to return
    - offset: Number of sessions to skip
    - archived: Filter by archived status
    - workspaceId: Filter by workspace slug
    """
    orchestrator = get_orchestrator(request)

    # If archived is not specified, default to showing non-archived
    show_archived = archived if archived is not None else False

    try:
        sessions = await orchestrator.list_sessions(
            module=module,
            archived=show_archived,
            search=search,
            limit=limit,
            workspace_id=workspace_id,
        )
    except Exception as e:
        logger.error(f"Failed to list sessions: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Session list error: {e}")

    return {"sessions": sessions}


# NOTE: /chat/stats must be BEFORE /chat/{session_id} to avoid "stats" being treated as a session_id
@router.get("/chat/stats")
async def get_session_stats(request: Request) -> dict[str, Any]:
    """
    Get session statistics.
    """
    orchestrator = get_orchestrator(request)

    return await orchestrator.get_session_stats()


@router.get("/chat/{session_id}")
async def get_session(request: Request, session_id: str) -> dict[str, Any]:
    """
    Get session by ID with messages.
    """
    orchestrator = get_orchestrator(request)

    session = await orchestrator.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    return session


@router.delete("/chat/{session_id}")
async def delete_session(request: Request, session_id: str) -> dict[str, Any]:
    """
    Delete a session.
    """
    orchestrator = get_orchestrator(request)

    success = await orchestrator.delete_session(session_id)
    if not success:
        raise HTTPException(status_code=404, detail="Session not found")

    return {"success": True, "deleted": session_id}


@router.post("/chat/{session_id}/archive")
async def archive_session(request: Request, session_id: str) -> dict[str, Any]:
    """
    Archive a session.
    """
    orchestrator = get_orchestrator(request)

    session = await orchestrator.archive_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    return {"success": True, "session": session}


@router.post("/chat/{session_id}/unarchive")
async def unarchive_session(request: Request, session_id: str) -> dict[str, Any]:
    """
    Unarchive a session.
    """
    orchestrator = get_orchestrator(request)

    session = await orchestrator.unarchive_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    return {"success": True, "session": session}


@router.patch("/chat/{session_id}/config")
async def update_session_config(
    request: Request,
    session_id: str,
    body: SessionConfigUpdate,
) -> dict[str, Any]:
    """
    Update session configuration (trust level, module).
    """
    db = request.app.state.database
    if not db:
        raise HTTPException(status_code=503, detail="Database not ready")

    session = await db.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    from parachute.models.session import SessionUpdate

    update = SessionUpdate()
    has_changes = False

    if body.trust_level is not None:
        if body.trust_level not in ("full", "vault", "sandboxed"):
            raise HTTPException(status_code=400, detail="Invalid trust level")
        update.trust_level = body.trust_level
        has_changes = True

    if body.module is not None:
        has_changes = True
        await db.update_session_config(session_id, module=body.module)

    if body.config_overrides is not None:
        existing_meta = session.metadata or {} if hasattr(session, "metadata") else {}
        existing_meta["config_overrides"] = body.config_overrides
        update.metadata = existing_meta
        has_changes = True

    if body.workspace_id is not None:
        has_changes = True
        # Empty string clears workspace, otherwise set slug
        ws_value = body.workspace_id if body.workspace_id else None
        await db.update_session_config(session_id, workspace_id=ws_value)

    if not has_changes:
        raise HTTPException(status_code=400, detail="No fields to update")

    if update.trust_level is not None or update.metadata is not None:
        await db.update_session(session_id, update)

    updated = await db.get_session(session_id)

    return {
        "success": True,
        "session": updated.model_dump(by_alias=True) if updated else None,
    }


@router.post("/chat/{session_id}/abort")
async def abort_session(request: Request, session_id: str) -> dict[str, Any]:
    """
    Abort an active streaming session.

    Returns 200 if abort was successful, 404 if no active stream found.
    """
    orchestrator = get_orchestrator(request)

    success = await orchestrator.abort_stream(session_id)
    if not success:
        raise HTTPException(status_code=404, detail="No active stream for this session")

    return {"success": True, "sessionId": session_id}


@router.get("/chat/{session_id}/transcript")
async def get_session_transcript(
    request: Request,
    session_id: str,
    after_compact: bool = Query(
        True,
        description="Only return events after the last compact boundary (default for fast initial load)",
    ),
    segment: Optional[int] = Query(
        None,
        description="Load a specific segment by index (0-based)",
    ),
    full: bool = Query(
        False,
        description="Load all events (overrides after_compact and segment)",
    ),
) -> dict[str, Any]:
    """
    Get the SDK transcript for a session with optional segmentation.

    By default, only returns events after the last compact boundary for fast loading.
    Use the segment parameter to load specific older segments on demand.
    Use full=true to load everything (for export, search, etc.).

    Returns:
    - events: The transcript events (filtered based on parameters)
    - segments: Metadata about all segments (for UI to show collapsed headers)
    - segmentCount: Total number of segments
    - loadedSegmentIndex: Which segment is currently loaded (null if all)
    """
    orchestrator = get_orchestrator(request)

    # full=true overrides everything
    if full:
        after_compact = False
        segment = None

    transcript = await orchestrator.get_session_transcript(
        session_id,
        after_compact=after_compact and segment is None,  # Don't use after_compact if specific segment requested
        segment_index=segment,
        include_segment_metadata=True,
    )
    if not transcript:
        raise HTTPException(status_code=404, detail="Transcript not found")

    return transcript


# =========================================================================
# Permission Management
# =========================================================================


@router.get("/chat/{session_id}/permissions")
async def get_pending_permissions(
    request: Request, session_id: str
) -> dict[str, Any]:
    """
    Get pending permission requests for a session.

    Returns a list of pending permission requests that need user approval.
    This is only relevant when trust mode is disabled for a session.
    """
    orchestrator = get_orchestrator(request)

    pending = orchestrator.get_pending_permissions(session_id)
    return {"pending": pending, "sessionId": session_id}


@router.post("/chat/{session_id}/permissions/grant")
async def grant_permission(
    request: Request, session_id: str, body: PermissionGrantRequest
) -> dict[str, Any]:
    """
    Grant a pending permission request.

    Args:
        session_id: The session ID
        body: Grant request with request_id and optional pattern

    The pattern parameter allows granting broader access:
    - If not provided, only the specific file is granted
    - If provided, the pattern is added to session permissions
      (e.g., "Blogs/**/*" to grant access to all files in Blogs/)
    """
    orchestrator = get_orchestrator(request)

    success = orchestrator.grant_permission(
        session_id, body.request_id, body.pattern
    )

    if not success:
        raise HTTPException(
            status_code=404,
            detail="Permission request not found or already resolved",
        )

    return {
        "success": True,
        "sessionId": session_id,
        "requestId": body.request_id,
        "pattern": body.pattern,
    }


@router.post("/chat/{session_id}/permissions/deny")
async def deny_permission(
    request: Request, session_id: str, body: PermissionDenyRequest
) -> dict[str, Any]:
    """
    Deny a pending permission request.

    This will cause the tool use to fail with a permission denied error.
    """
    orchestrator = get_orchestrator(request)

    success = orchestrator.deny_permission(session_id, body.request_id)

    if not success:
        raise HTTPException(
            status_code=404,
            detail="Permission request not found or already resolved",
        )

    return {
        "success": True,
        "sessionId": session_id,
        "requestId": body.request_id,
    }


# =========================================================================
# Vault Migration
# =========================================================================


# Note: Vault migration is now handled by the standalone script:
# python -m scripts.migrate_vault --from /old/vault --to /new/vault
