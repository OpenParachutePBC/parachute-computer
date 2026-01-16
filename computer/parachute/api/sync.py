"""
Sync API endpoints for file synchronization.

Provides manifest-based sync for efficient push/pull of vault files.
Designed for Daily/ journal sync but works with any vault folder.
"""

import base64
import hashlib
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException, Query, Request, UploadFile, File
from pydantic import BaseModel, Field

from parachute.config import get_settings

router = APIRouter(prefix="/sync", tags=["sync"])
logger = logging.getLogger(__name__)


# --- Models ---


class FileInfo(BaseModel):
    """Metadata for a single file in the manifest."""

    path: str = Field(..., description="Relative path from sync root")
    hash: str = Field(..., description="SHA-256 hash of file content")
    size: int = Field(..., description="File size in bytes")
    modified: float = Field(..., description="Last modified timestamp (Unix)")


class ManifestResponse(BaseModel):
    """Response containing file manifest for a folder."""

    root: str = Field(..., description="Sync root path (relative to vault)")
    files: list[FileInfo] = Field(default_factory=list)
    generated_at: str = Field(..., description="ISO timestamp when manifest was generated")


class PushFileRequest(BaseModel):
    """Single file to push."""

    path: str = Field(..., description="Relative path within sync root")
    content: str = Field(..., description="File content (text or base64 for binary)")
    is_binary: bool = Field(False, description="Whether content is base64-encoded binary")


class PushRequest(BaseModel):
    """Request to push multiple files."""

    root: str = Field(..., description="Sync root (e.g., 'Daily')")
    files: list[PushFileRequest] = Field(..., description="Files to push")


class PushResponse(BaseModel):
    """Response after pushing files."""

    pushed: int = Field(..., description="Number of files successfully pushed")
    errors: list[str] = Field(default_factory=list, description="Any errors encountered")


class PullRequest(BaseModel):
    """Request to pull specific files."""

    root: str = Field(..., description="Sync root (e.g., 'Daily')")
    paths: list[str] = Field(..., description="Relative paths to pull")


class PulledFile(BaseModel):
    """A file returned from pull."""

    path: str
    content: str
    hash: str
    size: int
    modified: float
    is_binary: bool = Field(False, description="Whether content is base64-encoded binary")


class PullResponse(BaseModel):
    """Response containing pulled files."""

    files: list[PulledFile] = Field(default_factory=list)
    errors: list[str] = Field(default_factory=list)


# --- Helpers ---


def get_vault_path() -> Path:
    """Get vault path from settings."""
    return get_settings().vault_path


def validate_sync_path(vault_path: Path, root: str, subpath: str = "") -> Path:
    """
    Validate and resolve a sync path, ensuring it's within the vault.

    Args:
        vault_path: The vault root path
        root: Sync root folder (e.g., "Daily")
        subpath: Optional path within the root

    Returns:
        Resolved absolute path

    Raises:
        HTTPException if path is invalid or outside vault
    """
    if ".." in root or ".." in subpath:
        raise HTTPException(status_code=400, detail="Path traversal not allowed")

    target = vault_path / root
    if subpath:
        target = target / subpath

    try:
        resolved = target.resolve()
        vault_resolved = vault_path.resolve()

        if not str(resolved).startswith(str(vault_resolved)):
            raise HTTPException(status_code=403, detail="Access denied: path outside vault")

        return resolved
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid path: {e}")


def hash_content(content: str) -> str:
    """Compute SHA-256 hash of string content."""
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def hash_file(path: Path) -> str:
    """Compute SHA-256 hash of file content."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# --- Endpoints ---


BINARY_EXTENSIONS = {'.wav', '.mp3', '.m4a', '.ogg', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.pdf'}


@router.get("/manifest", response_model=ManifestResponse)
async def get_manifest(
    request: Request,
    root: str = Query(..., description="Sync root folder (e.g., 'Daily')"),
    pattern: str = Query("*.md", description="Glob pattern to match files"),
    include_binary: bool = Query(False, description="Include binary files (audio, images)"),
) -> ManifestResponse:
    """
    Get file manifest for a sync root.

    Returns hashes and metadata for all matching files, allowing clients
    to determine which files need to be pushed or pulled.
    """
    vault_path = get_vault_path()
    sync_root = validate_sync_path(vault_path, root)

    if not sync_root.exists():
        # Return empty manifest for non-existent folder
        return ManifestResponse(
            root=root,
            files=[],
            generated_at=datetime.utcnow().isoformat() + "Z",
        )

    if not sync_root.is_dir():
        raise HTTPException(status_code=400, detail=f"{root} is not a directory")

    files: list[FileInfo] = []

    # Walk the directory and collect matching files
    for file_path in sync_root.rglob(pattern):
        if not file_path.is_file():
            continue

        # Skip hidden files and directories, EXCEPT .agents/ which we need to sync
        relative = file_path.relative_to(sync_root)
        parts = relative.parts
        if any(part.startswith(".") and part != ".agents" for part in parts):
            continue

        # Skip binary files unless include_binary is True
        if not include_binary and file_path.suffix.lower() in BINARY_EXTENSIONS:
            continue

        try:
            stat = file_path.stat()
            files.append(
                FileInfo(
                    path=str(relative),
                    hash=hash_file(file_path),
                    size=stat.st_size,
                    modified=stat.st_mtime,
                )
            )
        except (PermissionError, OSError) as e:
            logger.warning(f"Could not read {file_path}: {e}")
            continue

    logger.info(f"Generated manifest for {root}: {len(files)} files")

    return ManifestResponse(
        root=root,
        files=files,
        generated_at=datetime.utcnow().isoformat() + "Z",
    )


@router.post("/push", response_model=PushResponse)
async def push_files(request: Request, body: PushRequest) -> PushResponse:
    """
    Push files to the server.

    Overwrites existing files or creates new ones.
    Parent directories are created automatically.
    Binary files should have is_binary=True and content as base64.
    """
    vault_path = get_vault_path()
    sync_root = validate_sync_path(vault_path, body.root)

    pushed = 0
    errors: list[str] = []

    for file in body.files:
        try:
            file_path = validate_sync_path(vault_path, body.root, file.path)

            # Create parent directories
            file_path.parent.mkdir(parents=True, exist_ok=True)

            # Write file - decode base64 for binary, text for others
            if file.is_binary:
                file_path.write_bytes(base64.b64decode(file.content))
            else:
                file_path.write_text(file.content, encoding="utf-8")
            pushed += 1

            logger.debug(f"Pushed: {body.root}/{file.path} (binary={file.is_binary})")

        except HTTPException as e:
            errors.append(f"{file.path}: {e.detail}")
        except Exception as e:
            errors.append(f"{file.path}: {str(e)}")
            logger.error(f"Error pushing {file.path}: {e}")

    logger.info(f"Push to {body.root}: {pushed} files, {len(errors)} errors")

    return PushResponse(pushed=pushed, errors=errors)


@router.post("/pull", response_model=PullResponse)
async def pull_files(request: Request, body: PullRequest) -> PullResponse:
    """
    Pull specific files from the server.

    Returns file content along with metadata for each requested path.
    Binary files are returned with base64-encoded content and is_binary=True.
    """
    vault_path = get_vault_path()
    sync_root = validate_sync_path(vault_path, body.root)

    files: list[PulledFile] = []
    errors: list[str] = []

    for path in body.paths:
        try:
            file_path = validate_sync_path(vault_path, body.root, path)

            if not file_path.exists():
                errors.append(f"{path}: File not found")
                continue

            if not file_path.is_file():
                errors.append(f"{path}: Not a file")
                continue

            stat = file_path.stat()
            is_binary = file_path.suffix.lower() in BINARY_EXTENSIONS

            if is_binary:
                # Read as bytes and base64 encode
                content_bytes = file_path.read_bytes()
                content = base64.b64encode(content_bytes).decode("ascii")
                file_hash = hashlib.sha256(content_bytes).hexdigest()
            else:
                # Read as text
                content = file_path.read_text(encoding="utf-8")
                file_hash = hash_content(content)

            files.append(
                PulledFile(
                    path=path,
                    content=content,
                    hash=file_hash,
                    size=stat.st_size,
                    modified=stat.st_mtime,
                    is_binary=is_binary,
                )
            )

        except UnicodeDecodeError:
            # Try reading as binary if text decode fails
            try:
                content_bytes = file_path.read_bytes()
                content = base64.b64encode(content_bytes).decode("ascii")
                file_hash = hashlib.sha256(content_bytes).hexdigest()
                stat = file_path.stat()
                files.append(
                    PulledFile(
                        path=path,
                        content=content,
                        hash=file_hash,
                        size=stat.st_size,
                        modified=stat.st_mtime,
                        is_binary=True,
                    )
                )
            except Exception as e:
                errors.append(f"{path}: Failed to read file: {str(e)}")
        except HTTPException as e:
            errors.append(f"{path}: {e.detail}")
        except Exception as e:
            errors.append(f"{path}: {str(e)}")
            logger.error(f"Error pulling {path}: {e}")

    logger.info(f"Pull from {body.root}: {len(files)} files, {len(errors)} errors")

    return PullResponse(files=files, errors=errors)


@router.delete("/files")
async def delete_files(
    request: Request,
    root: str = Query(..., description="Sync root folder"),
    paths: list[str] = Query(..., description="Paths to delete"),
) -> dict:
    """
    Delete files from the server.

    Used when client detects files that should be removed.
    """
    vault_path = get_vault_path()

    deleted = 0
    errors: list[str] = []

    for path in paths:
        try:
            file_path = validate_sync_path(vault_path, root, path)

            if not file_path.exists():
                # Already gone, count as success
                deleted += 1
                continue

            if not file_path.is_file():
                errors.append(f"{path}: Not a file")
                continue

            file_path.unlink()
            deleted += 1
            logger.debug(f"Deleted: {root}/{path}")

        except HTTPException as e:
            errors.append(f"{path}: {e.detail}")
        except Exception as e:
            errors.append(f"{path}: {str(e)}")

    logger.info(f"Delete from {root}: {deleted} files, {len(errors)} errors")

    return {"deleted": deleted, "errors": errors}
