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


@router.get("/{session_id}/messages")
async def get_curator_messages(request: Request, session_id: str) -> dict:
    """
    Get the curator's conversation messages for a chat session.

    The curator is an SDK session, so we can load its messages just like
    a regular chat session. This provides transparency into what the curator
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
        working_directory=None,  # Curator runs without a specific working directory
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


class RecentActivityResponse(BaseModel):
    """Recent curator activity across all sessions."""
    recent_updates: list[dict[str, Any]]
    context_files_modified: list[str]
    last_activity_at: Optional[str]


@router.get("/activity/recent")
async def get_recent_curator_activity(
    request: Request,
    limit: int = 10,
) -> RecentActivityResponse:
    """
    Get recent curator activity across all sessions.

    Returns recent context file updates and title changes
    to show users what the curator has been learning.
    """
    from parachute.core.curator_service import get_curator_service

    try:
        curator = await get_curator_service()
    except RuntimeError:
        raise HTTPException(status_code=503, detail="Curator service not available")

    db = request.app.state.database

    # Query recent completed tasks that made updates
    async with db.connection.execute(
        """
        SELECT * FROM curator_queue
        WHERE status = 'completed' AND result IS NOT NULL
        ORDER BY completed_at DESC
        LIMIT ?
        """,
        (limit * 2,),  # Get more to filter
    ) as cursor:
        rows = await cursor.fetchall()

    recent_updates = []
    context_files_modified = set()
    last_activity_at = None

    for row in rows:
        result = row["result"]
        if not result:
            continue

        try:
            import json
            result_data = json.loads(result)
        except (json.JSONDecodeError, TypeError, ValueError):
            continue

        # Skip tasks that made no updates
        if not result_data.get("title_updated") and not result_data.get("context_updated"):
            continue

        completed_at = row["completed_at"]
        if last_activity_at is None:
            last_activity_at = completed_at

        update_entry = {
            "task_id": row["id"],
            "session_id": row["parent_session_id"],
            "completed_at": completed_at,
            "actions": result_data.get("actions", []),
            "reasoning": result_data.get("reasoning"),
        }

        if result_data.get("new_title"):
            update_entry["new_title"] = result_data["new_title"]

        recent_updates.append(update_entry)

        # Track modified context files
        for action in result_data.get("actions", []):
            if ":" in action and not action.startswith("Updated title"):
                # Extract filename from "update_facts: general-context.md"
                parts = action.split(": ", 1)
                if len(parts) == 2:
                    context_files_modified.add(parts[1])

        if len(recent_updates) >= limit:
            break

    return RecentActivityResponse(
        recent_updates=recent_updates,
        context_files_modified=list(context_files_modified),
        last_activity_at=last_activity_at,
    )
