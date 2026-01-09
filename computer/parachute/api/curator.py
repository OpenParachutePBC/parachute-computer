"""
Curator API endpoints.

Provides visibility into the background title generation service:
- View recent curator tasks for a session
- Manually trigger curator tasks
"""

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel
from typing import Any, Optional

router = APIRouter(prefix="/curator")


class CuratorTaskResponse(BaseModel):
    """Curator task info."""
    id: int
    session_id: str
    trigger_type: str
    message_count: int
    queued_at: str
    started_at: Optional[str]
    completed_at: Optional[str]
    status: str
    result: Optional[dict]
    error: Optional[str]


@router.get("/{session_id}", response_model=dict)
async def get_curator_for_session(request: Request, session_id: str) -> dict:
    """
    Get curator task history for a chat session.

    Returns recent tasks for visibility into title generation.
    """
    from parachute.core.curator_service import get_curator_service

    try:
        curator = await get_curator_service()
    except RuntimeError:
        raise HTTPException(status_code=503, detail="Curator service not available")

    # Get recent tasks
    tasks = await curator.get_tasks_for_session(session_id, limit=10)

    return {
        "session_id": session_id,
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

    Useful for testing or forcing title regeneration.
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
        "session_id": task.session_id,
        "trigger_type": task.trigger_type,
        "message_count": task.message_count,
        "queued_at": task.queued_at.isoformat(),
        "started_at": task.started_at.isoformat() if task.started_at else None,
        "completed_at": task.completed_at.isoformat() if task.completed_at else None,
        "status": task.status,
        "result": task.result,
        "error": task.error,
    }


@router.get("/activity/recent")
async def get_recent_curator_activity(
    request: Request,
    limit: int = 10,
) -> dict:
    """
    Get recent curator activity across all sessions.

    Returns recent title updates to show what the curator has been doing.
    """
    from parachute.core.curator_service import get_curator_service
    import json

    try:
        curator = await get_curator_service()
    except RuntimeError:
        raise HTTPException(status_code=503, detail="Curator service not available")

    db = request.app.state.database

    # Query recent completed tasks
    async with db.connection.execute(
        """
        SELECT * FROM curator_queue
        WHERE status = 'completed' AND result IS NOT NULL
        ORDER BY completed_at DESC
        LIMIT ?
        """,
        (limit * 2,),
    ) as cursor:
        rows = await cursor.fetchall()

    recent_updates = []
    last_activity_at = None

    for row in rows:
        result = row["result"]
        if not result:
            continue

        try:
            result_data = json.loads(result)
        except (json.JSONDecodeError, TypeError, ValueError):
            continue

        # Skip tasks that made no updates
        if not result_data.get("title_updated"):
            continue

        completed_at = row["completed_at"]
        if last_activity_at is None:
            last_activity_at = completed_at

        recent_updates.append({
            "task_id": row["id"],
            "session_id": row["parent_session_id"],
            "completed_at": completed_at,
            "new_title": result_data.get("new_title"),
        })

        if len(recent_updates) >= limit:
            break

    return {
        "recent_updates": recent_updates,
        "last_activity_at": last_activity_at,
    }
