"""
Session management API endpoints.
"""

import logging
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Query, Request

router = APIRouter()
logger = logging.getLogger(__name__)


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
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    archived: Optional[bool] = Query(None, description="Filter by archived status"),
) -> dict[str, Any]:
    """
    List all sessions.

    Query params:
    - module: Filter by module (chat, daily, build)
    - limit: Maximum number of sessions to return
    - offset: Number of sessions to skip
    - archived: Filter by archived status
    """
    orchestrator = get_orchestrator(request)

    # If archived is not specified, default to showing non-archived
    show_archived = archived if archived is not None else False

    try:
        sessions = await orchestrator.list_sessions(
            module=module,
            archived=show_archived,
            limit=limit,
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
