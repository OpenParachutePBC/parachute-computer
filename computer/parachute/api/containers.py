"""
Container environment management API endpoints.

Named container envs are shared Docker containers that multiple sessions can join.
Private (per-session) containers are managed automatically by the orchestrator.
"""

import logging
import re
import uuid

from fastapi import APIRouter, HTTPException, Request

from parachute.db.database import get_database
from parachute.models.session import ContainerEnvCreate

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/containers", tags=["containers"])


def _slugify(name: str) -> str:
    """Convert a display name to a URL-safe slug."""
    slug = name.lower()
    slug = re.sub(r"[^a-z0-9]+", "-", slug)
    slug = slug.strip("-")
    return slug or str(uuid.uuid4())[:8]


@router.get("")
async def list_container_envs():
    """List all named container environments."""
    db = await get_database()
    envs = await db.list_container_envs()
    return {"containers": [e.model_dump(by_alias=True) for e in envs]}


@router.post("", status_code=201)
async def create_container_env(request: Request, body: ContainerEnvCreate):
    """Create a named container environment.

    The Docker container is not created here — it is lazily created when a session
    first joins the env. This endpoint only creates the DB record.
    """
    db = await get_database()
    slug = body.slug or _slugify(body.display_name)

    # Validate slug
    if not re.match(r"^[a-z0-9][a-z0-9-]*[a-z0-9]$", slug):
        raise HTTPException(
            status_code=400,
            detail="Slug must be lowercase alphanumeric with hyphens, no leading/trailing hyphens",
        )

    # Check for duplicate
    existing = await db.get_container_env(slug)
    if existing:
        raise HTTPException(status_code=409, detail=f"Container env '{slug}' already exists")

    env = await db.create_container_env(slug=slug, display_name=body.display_name)
    return {"container": env.model_dump(by_alias=True)}


@router.delete("/{slug}", status_code=200)
async def delete_container_env(request: Request, slug: str):
    """Delete a named container environment.

    Stops and removes the Docker container, then deletes the DB record.
    Sessions that were in this env revert to private containers on next turn.
    """
    db = await get_database()
    env = await db.get_container_env(slug)
    if not env:
        raise HTTPException(status_code=404, detail=f"Container env '{slug}' not found")

    # Stop, remove the Docker container, and clean up the home dir
    orchestrator = getattr(request.app.state, "orchestrator", None)
    if orchestrator:
        try:
            await orchestrator.delete_container(slug)
        except Exception as e:
            logger.warning(f"Failed to remove container env '{slug}': {e}")

    deleted = await db.delete_container_env(slug)
    return {"deleted": deleted, "slug": slug}
