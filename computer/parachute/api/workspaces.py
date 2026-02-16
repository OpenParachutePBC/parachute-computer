"""
Workspace management API endpoints.
"""

import logging
from typing import Optional

from fastapi import APIRouter, HTTPException, Query, Request

from parachute.config import get_settings
from parachute.core import workspaces
from parachute.db.database import get_database
from parachute.models.workspace import WorkspaceCreate, WorkspaceUpdate

router = APIRouter(prefix="/workspaces")
logger = logging.getLogger(__name__)


def _get_vault_path(request: Request):
    """Get vault path from settings."""
    return get_settings().vault_path


@router.get("")
async def list_workspaces(request: Request):
    """List all workspaces."""
    vault_path = _get_vault_path(request)
    ws_list = workspaces.list_workspaces(vault_path)
    return {"workspaces": [w.to_api_dict() for w in ws_list]}


@router.post("", status_code=201)
async def create_workspace(request: Request, body: WorkspaceCreate):
    """Create a new workspace."""
    vault_path = _get_vault_path(request)
    workspace = workspaces.create_workspace(vault_path, body)
    return {"workspace": workspace.to_api_dict()}


@router.get("/{slug}")
async def get_workspace(request: Request, slug: str):
    """Get a workspace by slug."""
    vault_path = _get_vault_path(request)
    try:
        workspace = workspaces.get_workspace(vault_path, slug)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    if workspace is None:
        raise HTTPException(status_code=404, detail=f"Workspace not found: {slug}")
    return {"workspace": workspace.to_api_dict()}


@router.put("/{slug}")
async def update_workspace(request: Request, slug: str, body: WorkspaceUpdate):
    """Update a workspace."""
    vault_path = _get_vault_path(request)
    try:
        workspace = workspaces.update_workspace(vault_path, slug, body)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    if workspace is None:
        raise HTTPException(status_code=404, detail=f"Workspace not found: {slug}")
    return {"workspace": workspace.to_api_dict()}


@router.delete("/{slug}")
async def delete_workspace(request: Request, slug: str):
    """Delete a workspace.

    Sessions linked to this workspace will have their workspace_id set to NULL.
    Persistent Docker container for this workspace will be stopped and removed.
    """
    vault_path = _get_vault_path(request)

    # Check workspace exists
    try:
        workspace = workspaces.get_workspace(vault_path, slug)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    if workspace is None:
        raise HTTPException(status_code=404, detail=f"Workspace not found: {slug}")

    # Stop persistent container before deleting workspace files
    orchestrator = getattr(request.app.state, "orchestrator", None)
    if orchestrator:
        try:
            await orchestrator.stop_workspace_container(slug)
        except (RuntimeError, OSError) as e:
            logger.warning(f"Failed to stop container for workspace {slug}: {e}")

        # Clean up persistent sandbox data (SDK transcripts on host mount)
        try:
            sandbox = getattr(orchestrator, "_sandbox", None)
            if sandbox:
                sandbox.cleanup_workspace_data(slug)
        except (ValueError, OSError) as e:
            logger.warning(f"Failed to clean sandbox data for workspace {slug}: {e}")

    # Unlink sessions from this workspace
    db = await get_database()
    await db.connection.execute(
        "UPDATE sessions SET workspace_id = NULL WHERE workspace_id = ?",
        (slug,),
    )
    await db.connection.commit()

    # Delete workspace directory
    workspaces.delete_workspace(vault_path, slug)

    return {"deleted": slug}


@router.get("/{slug}/sessions")
async def list_workspace_sessions(
    request: Request,
    slug: str,
    archived: Optional[bool] = Query(None),
    limit: int = Query(100, le=500),
    offset: int = Query(0, ge=0),
):
    """List sessions belonging to a workspace."""
    vault_path = _get_vault_path(request)

    # Verify workspace exists
    try:
        workspace = workspaces.get_workspace(vault_path, slug)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    if workspace is None:
        raise HTTPException(status_code=404, detail=f"Workspace not found: {slug}")

    db = await get_database()
    sessions = await db.list_sessions(
        workspace_id=slug,
        archived=archived,
        limit=limit,
        offset=offset,
    )

    return {
        "workspace": workspace.to_api_dict(),
        "sessions": [s.model_dump(by_alias=True) for s in sessions],
    }
