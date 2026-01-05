"""
Curator API endpoints.

Provides visibility into the background curator system:
- View curator session for a chat
- List curator tasks and their status
- Manually trigger curator tasks
"""

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel
from typing import Any, Optional

router = APIRouter(prefix="/curator")


class CuratorSessionResponse(BaseModel):
    """Curator session info."""
    id: str
    parent_session_id: str
    sdk_session_id: Optional[str]
    last_run_at: Optional[str]
    last_message_index: int
    context_files: list[str]
    created_at: str


class CuratorTaskResponse(BaseModel):
    """Curator task info."""
    id: int
    parent_session_id: str
    curator_session_id: Optional[str]
    trigger_type: str
    message_count: int
    queued_at: str
    started_at: Optional[str]
    completed_at: Optional[str]
    status: str
    result: Optional[dict]
    error: Optional[str]


class CuratorStatusResponse(BaseModel):
    """Overall curator status."""
    worker_running: bool
    pending_tasks: int
    running_task: Optional[CuratorTaskResponse]


@router.get("/{session_id}", response_model=dict)
async def get_curator_for_session(request: Request, session_id: str) -> dict:
    """
    Get curator information for a chat session.

    Returns the curator session and recent tasks for visibility into
    what the curator has been doing.
    """
    from parachute.core.curator_service import get_curator_service

    try:
        curator = await get_curator_service()
    except RuntimeError:
        raise HTTPException(status_code=503, detail="Curator service not available")

    # Get curator session
    curator_session = await curator.get_curator_session(session_id)
    if not curator_session:
        return {
            "curator_session": None,
            "recent_tasks": [],
            "message": "No curator session for this chat yet",
        }

    # Get recent tasks
    tasks = await curator.get_tasks_for_session(session_id, limit=10)

    return {
        "curator_session": {
            "id": curator_session.id,
            "parent_session_id": curator_session.parent_session_id,
            "sdk_session_id": curator_session.sdk_session_id,
            "last_run_at": curator_session.last_run_at.isoformat() if curator_session.last_run_at else None,
            "last_message_index": curator_session.last_message_index,
            "context_files": curator_session.context_files,
            "created_at": curator_session.created_at.isoformat(),
        },
        "recent_tasks": [
            {
                "id": t.id,
                "trigger_type": t.trigger_type,
                "status": t.status,
                "queued_at": t.queued_at.isoformat(),
                "started_at": t.started_at.isoformat() if t.started_at else None,
                "completed_at": t.completed_at.isoformat() if t.completed_at else None,
                "result": t.result,
                "error": t.error,
            }
            for t in tasks
        ],
    }


@router.post("/{session_id}/trigger")
async def trigger_curator(request: Request, session_id: str) -> dict:
    """
    Manually trigger a curator task for a session.

    Useful for testing or forcing a curator run.
    """
    from parachute.core.curator_service import get_curator_service

    try:
        curator = await get_curator_service()
    except RuntimeError:
        raise HTTPException(status_code=503, detail="Curator service not available")

    # Check if session exists
    db = request.app.state.database
    session = await db.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")

    # Queue task
    task_id = await curator.queue_task(
        parent_session_id=session_id,
        trigger_type="manual",
        message_count=session.message_count,
    )

    return {
        "task_id": task_id,
        "status": "queued",
        "message": f"Curator task {task_id} queued for session",
    }


@router.get("/task/{task_id}", response_model=CuratorTaskResponse)
async def get_curator_task(request: Request, task_id: int) -> dict:
    """Get details of a specific curator task."""
    from parachute.core.curator_service import get_curator_service

    try:
        curator = await get_curator_service()
    except RuntimeError:
        raise HTTPException(status_code=503, detail="Curator service not available")

    task = await curator.get_task(task_id)
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    return {
        "id": task.id,
        "parent_session_id": task.parent_session_id,
        "curator_session_id": task.curator_session_id,
        "trigger_type": task.trigger_type,
        "message_count": task.message_count,
        "queued_at": task.queued_at.isoformat(),
        "started_at": task.started_at.isoformat() if task.started_at else None,
        "completed_at": task.completed_at.isoformat() if task.completed_at else None,
        "status": task.status,
        "result": task.result,
        "error": task.error,
    }
