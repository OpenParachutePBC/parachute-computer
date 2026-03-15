"""
Container file browser API endpoints.

Provides file system navigation for container env home directories:
listing, downloading, uploading, creating directories, and deleting files.
"""

import asyncio
import logging
import shutil
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.core.sandbox import SANDBOX_DATA_DIR

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/containers", tags=["container-files"])

# 50 MB upload limit
MAX_UPLOAD_SIZE = 50 * 1024 * 1024


# ---------------------------------------------------------------------------
# Response models
# ---------------------------------------------------------------------------


class FileEntry(BaseModel):
    name: str
    path: str
    type: str  # "file" or "directory"
    size: int | None = None
    lastModified: str | None = None
    isDirectory: bool
    isFile: bool


class DirectoryListing(BaseModel):
    slug: str
    path: str
    entries: list[FileEntry]


class FileOperationResult(BaseModel):
    success: bool
    path: str
    message: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_home_dir(slug: str) -> Path:
    """Return the host-side home directory for a container env."""
    settings = get_settings()
    return settings.parachute_dir / SANDBOX_DATA_DIR / "envs" / slug / "home"


async def _validate_slug(request: Request, slug: str) -> Path:
    """Validate that the container env exists in the DB. Returns its home dir."""
    db = request.app.state.session_store
    env = await db.get_container(slug)
    if not env:
        raise HTTPException(status_code=404, detail=f"Container env '{slug}' not found")
    return _get_home_dir(slug)


def _resolve_safe_path(home_dir: Path, relative_path: str) -> Path:
    """Resolve a relative path within home_dir, preventing traversal."""
    # Strip leading slashes so it's always relative
    cleaned = relative_path.lstrip("/")
    target = (home_dir / cleaned).resolve()
    home_resolved = home_dir.resolve()
    if not target.is_relative_to(home_resolved):
        raise HTTPException(status_code=403, detail="Access denied: path outside container home")
    return target


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.get("/{slug}/files", response_model=DirectoryListing)
async def list_files(
    request: Request,
    slug: str,
    path: str | None = Query(None, description="Relative path within container home"),
    includeHidden: bool = Query(False, description="Include hidden files/folders"),
):
    """List directory contents in a container env's home directory."""
    home_dir = await _validate_slug(request, slug)

    if path:
        target = _resolve_safe_path(home_dir, path)
    else:
        target = home_dir

    if not target.exists():
        raise HTTPException(status_code=404, detail="Path not found")
    if not target.is_dir():
        raise HTTPException(status_code=400, detail="Path is not a directory")

    entries: list[FileEntry] = []
    try:
        for item in sorted(target.iterdir()):
            if item.name.startswith(".") and not includeHidden:
                continue

            try:
                stat = item.stat()
            except (OSError, FileNotFoundError):
                continue

            is_dir = item.is_dir()
            entries.append(FileEntry(
                name=item.name,
                path=str(item.relative_to(home_dir)),
                type="directory" if is_dir else "file",
                size=stat.st_size if not is_dir else None,
                lastModified=datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat(),
                isDirectory=is_dir,
                isFile=item.is_file(),
            ))
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")

    rel_path = str(target.relative_to(home_dir)) if target != home_dir else ""
    return DirectoryListing(slug=slug, path=rel_path, entries=entries)


@router.get("/{slug}/files/download")
async def download_file(
    request: Request,
    slug: str,
    path: str = Query(..., description="Relative path to file within container home"),
):
    """Download a file from a container env's home directory."""
    home_dir = await _validate_slug(request, slug)
    target = _resolve_safe_path(home_dir, path)

    if not target.exists():
        raise HTTPException(status_code=404, detail="File not found")
    if not target.is_file():
        raise HTTPException(status_code=400, detail="Path is not a file")

    return FileResponse(
        path=str(target),
        filename=target.name,
        media_type="application/octet-stream",
    )


@router.post("/{slug}/files/upload", response_model=list[FileOperationResult])
async def upload_files(
    request: Request,
    slug: str,
    files: list[UploadFile],
    path: str | None = Query(None, description="Relative directory to upload into"),
):
    """Upload file(s) to a container env's home directory (50MB limit per file)."""
    home_dir = await _validate_slug(request, slug)

    if path:
        upload_dir = _resolve_safe_path(home_dir, path)
    else:
        upload_dir = home_dir

    upload_dir.mkdir(parents=True, exist_ok=True)

    results: list[FileOperationResult] = []
    for file in files:
        content = await file.read()
        if len(content) > MAX_UPLOAD_SIZE:
            results.append(FileOperationResult(
                success=False,
                path=file.filename or "",
                message=f"File exceeds {MAX_UPLOAD_SIZE // (1024 * 1024)}MB limit",
            ))
            continue

        safe_name = Path(file.filename or "unnamed").name
        dest = upload_dir / safe_name
        try:
            await asyncio.to_thread(dest.write_bytes, content)
            rel = str(dest.relative_to(home_dir))
            results.append(FileOperationResult(success=True, path=rel, message="Uploaded"))
        except Exception as e:
            results.append(FileOperationResult(
                success=False,
                path=file.filename or "",
                message=str(e),
            ))

    return results


@router.post("/{slug}/files/mkdir", response_model=FileOperationResult)
async def make_directory(
    request: Request,
    slug: str,
    path: str = Query(..., description="Relative path for the new directory"),
):
    """Create a directory in a container env's home directory."""
    home_dir = await _validate_slug(request, slug)
    target = _resolve_safe_path(home_dir, path)

    try:
        target.mkdir(parents=True, exist_ok=True)
        rel = str(target.relative_to(home_dir))
        return FileOperationResult(success=True, path=rel, message="Directory created")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/{slug}/files", response_model=FileOperationResult)
async def delete_file(
    request: Request,
    slug: str,
    path: str = Query(..., description="Relative path to delete"),
):
    """Delete a file or directory from a container env's home directory."""
    home_dir = await _validate_slug(request, slug)
    target = _resolve_safe_path(home_dir, path)

    # Cannot delete the home dir itself
    if target.resolve() == home_dir.resolve():
        raise HTTPException(status_code=400, detail="Cannot delete the home directory itself")

    if not target.exists():
        raise HTTPException(status_code=404, detail="Path not found")

    try:
        if target.is_dir():
            await asyncio.to_thread(shutil.rmtree, target)
        else:
            target.unlink()
        rel = str(target.relative_to(home_dir))
        return FileOperationResult(success=True, path=rel, message="Deleted")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
