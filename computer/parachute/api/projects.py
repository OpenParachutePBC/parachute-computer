"""
Project management API endpoints.

Named projects are shared Docker containers that multiple sessions can join.
Private (per-session) containers are managed automatically by the orchestrator.
"""

import logging
import re
import uuid

from fastapi import APIRouter, HTTPException, Request

from parachute.models.session import ProjectCreate

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/projects", tags=["projects"])


def _slugify(name: str) -> str:
    """Convert a display name to a URL-safe slug."""
    slug = name.lower()
    slug = re.sub(r"[^a-z0-9]+", "-", slug)
    slug = slug.strip("-")
    return slug or str(uuid.uuid4())[:8]


@router.get("")
async def list_projects(request: Request):
    """List all named projects."""
    db = request.app.state.session_store
    projects = await db.list_projects()
    return {"projects": [p.model_dump(by_alias=True) for p in projects]}


@router.post("", status_code=201)
async def create_project(request: Request, body: ProjectCreate):
    """Create a named project.

    The Docker container is not created here — it is lazily created when a session
    first joins the project. This endpoint only creates the DB record.
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
    existing = await db.get_project(slug)
    if existing:
        raise HTTPException(status_code=409, detail=f"Project '{slug}' already exists")

    project = await db.create_project(
        slug=slug,
        display_name=body.display_name,
        core_memory=body.core_memory,
    )
    return {"project": project.model_dump(by_alias=True)}


@router.delete("/{slug}", status_code=200)
async def delete_project(request: Request, slug: str):
    """Delete a named project.

    Stops and removes the Docker container, then deletes the DB record.
    Sessions that were in this project revert to private containers on next turn.
    """
    db = request.app.state.session_store
    project = await db.get_project(slug)
    if not project:
        raise HTTPException(status_code=404, detail=f"Project '{slug}' not found")

    # Stop, remove the Docker container, and clean up the home dir
    orchestrator = getattr(request.app.state, "orchestrator", None)
    if orchestrator:
        try:
            await orchestrator.delete_container(slug)
        except Exception as e:
            logger.warning(f"Failed to remove project container '{slug}': {e}")

    deleted = await db.delete_project(slug)
    return {"deleted": deleted, "slug": slug}
