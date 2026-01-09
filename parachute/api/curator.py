"""
Curator API endpoints.

Provides visibility into the background curator system:
- View curator session for a chat
- View curator's conversation messages (it's a persistent SDK session!)
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


@router.get("/{session_id}/messages")
async def get_curator_messages(request: Request, session_id: str) -> dict:
    """
    Get the curator's conversation messages for a chat session.

    The curator is a PERSISTENT SDK session, so we can load its messages
    just like a regular chat. This provides transparency into what the curator
    has been "thinking" and what context it was fed.

    Returns messages in chat format: [{role, content, timestamp}, ...]
    """
    from parachute.core.curator_service import get_curator_service
    from parachute.core.session_manager import SessionManager

    try:
        curator = await get_curator_service()
    except RuntimeError:
        raise HTTPException(status_code=503, detail="Curator service not available")

    # Get curator session
    curator_session = await curator.get_curator_session(session_id)
    if not curator_session:
        return {
            "messages": [],
            "sdk_session_id": None,
            "message": "No curator session for this chat yet",
        }

    # If no SDK session yet, no messages
    if not curator_session.sdk_session_id:
        return {
            "messages": [],
            "sdk_session_id": None,
            "message": "Curator has not run yet",
        }

    # Load messages from the curator's SDK session
    from parachute.config import get_settings

    db = request.app.state.database
    settings = get_settings()
    session_manager = SessionManager(settings.vault_path, db)

    messages = await session_manager.load_sdk_messages_by_id(
        curator_session.sdk_session_id,
        working_directory=None,
    )

    return {
        "messages": messages,
        "sdk_session_id": curator_session.sdk_session_id,
        "message_count": len(messages),
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
        "parent_session_id": task.session_id,
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
        if not result_data.get("title_updated") and not result_data.get("logged"):
            continue

        completed_at = row["completed_at"]
        if last_activity_at is None:
            last_activity_at = completed_at

        recent_updates.append({
            "task_id": row["id"],
            "session_id": row["parent_session_id"],
            "completed_at": completed_at,
            "title_updated": result_data.get("title_updated", False),
            "new_title": result_data.get("new_title"),
            "logged": result_data.get("logged", False),
        })

        if len(recent_updates) >= limit:
            break

    return {
        "recent_updates": recent_updates,
        "last_activity_at": last_activity_at,
    }
