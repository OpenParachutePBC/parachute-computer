"""
Container management API endpoints.

Containers are Docker execution environments that sessions run in.
Named containers can be shared across multiple sessions. Private (per-session)
containers are managed automatically by the orchestrator.
"""

import logging
import re
import uuid

from fastapi import APIRouter, HTTPException, Query, Request

from parachute.models.session import ContainerCreate, ContainerUpdate

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/containers", tags=["containers"])


def _slugify(name: str) -> str:
    """Convert a display name to a URL-safe slug."""
    slug = name.lower()
    slug = re.sub(r"[^a-z0-9]+", "-", slug)
    slug = slug.strip("-")
    return slug or str(uuid.uuid4())[:8]


@router.get("")
async def list_containers(
    request: Request,
    workspace: bool | None = Query(None, description="Filter: true=workspaces only, false=non-workspaces only, omit=all"),
):
    """List containers, optionally filtering to workspaces only."""
    db = request.app.state.session_store
    containers = await db.list_containers(workspace_only=bool(workspace))
    return {"containers": [c.model_dump(by_alias=True) for c in containers]}


@router.post("", status_code=201)
async def create_container(request: Request, body: ContainerCreate):
    """Create a named container.

    The Docker container is not created here — it is lazily created when a session
    first joins the container. This endpoint only creates the DB record.
    """
    db = request.app.state.session_store
    slug = body.slug or _slugify(body.display_name)

    # Validate slug
    if not re.match(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$", slug):
        raise HTTPException(
            status_code=400,
            detail="Slug must be lowercase alphanumeric with hyphens, no leading/trailing hyphens",
        )

    # Check for duplicate
    existing = await db.get_container(slug)
    if existing:
        raise HTTPException(status_code=409, detail=f"Container '{slug}' already exists")

    container = await db.create_container(
        slug=slug,
        display_name=body.display_name,
        core_memory=body.core_memory,
        is_workspace=True,  # Explicit creation = workspace
    )
    return {"container": container.model_dump(by_alias=True)}


@router.patch("/{slug}")
async def update_container(request: Request, slug: str, body: ContainerUpdate):
    """Update a container's display name or core memory.

    This is the promotion/rename endpoint — setting a meaningful display name
    on a previously unnamed container makes it findable and reusable.
    """
    db = request.app.state.session_store
    existing = await db.get_container(slug)
    if not existing:
        raise HTTPException(status_code=404, detail=f"Container '{slug}' not found")

    # Auto-promote to workspace when display_name is set on a non-workspace
    is_workspace = body.is_workspace
    if body.display_name is not None and not existing.is_workspace and is_workspace is None:
        is_workspace = True

    updated = await db.update_container(
        slug=slug,
        display_name=body.display_name,
        core_memory=body.core_memory,
        is_workspace=is_workspace,
    )
    if not updated:
        raise HTTPException(
            status_code=500, detail=f"Failed to update container '{slug}'"
        )
    return {"container": updated.model_dump(by_alias=True)}


@router.delete("/{slug}", status_code=200)
async def delete_container(request: Request, slug: str):
    """Delete a named container.

    Stops and removes the Docker container, then deletes the DB record.
    Sessions that were in this container revert to private containers on next turn.
    """
    db = request.app.state.session_store
    container = await db.get_container(slug)
    if not container:
        raise HTTPException(status_code=404, detail=f"Container '{slug}' not found")

    # Stop, remove the Docker container, and clean up the home dir
    orchestrator = getattr(request.app.state, "orchestrator", None)
    if orchestrator:
        try:
            await orchestrator.delete_container(slug)
        except Exception as e:
            logger.warning(f"Failed to remove container '{slug}': {e}")

    deleted = await db.delete_container(slug)
    return {"deleted": deleted, "slug": slug}
