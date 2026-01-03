"""
Filesystem API endpoints for vault browsing.
"""

import logging
import os
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel

router = APIRouter()
logger = logging.getLogger(__name__)


class WriteFileRequest(BaseModel):
    """Request body for writing files."""

    path: str
    content: str


def get_vault_path(request: Request) -> Path:
    """Get vault path from app state."""
    from parachute.config import get_settings

    settings = get_settings()
    return settings.vault_path


@router.get("/ls")
async def list_directory(
    request: Request,
    path: Optional[str] = Query(None, description="Relative path within vault"),
) -> dict[str, Any]:
    """
    List directory contents in the vault.

    Returns entries with metadata including:
    - name: Filename
    - relativePath: Path relative to vault
    - isDirectory: Whether it's a directory
    - size: File size in bytes
    - lastModified: ISO timestamp
    - hasClaudeMd: (directories only) Whether CLAUDE.md exists
    """
    vault_path = get_vault_path(request)
    target_path = vault_path / path if path else vault_path

    # Security: ensure path is within vault
    try:
        target_path = target_path.resolve()
        vault_resolved = vault_path.resolve()
        if not str(target_path).startswith(str(vault_resolved)):
            raise HTTPException(status_code=403, detail="Access denied: path outside vault")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid path: {e}")

    if not target_path.exists():
        raise HTTPException(status_code=404, detail="Path not found")

    if not target_path.is_dir():
        raise HTTPException(status_code=400, detail="Path is not a directory")

    entries = []
    try:
        for item in sorted(target_path.iterdir()):
            # Skip hidden files except CLAUDE.md
            if item.name.startswith(".") and item.name != ".parachute":
                continue

            relative_path = str(item.relative_to(vault_path))
            stat = item.stat()
            is_symlink = item.is_symlink()

            entry = {
                "name": item.name,
                "type": "directory" if item.is_dir() else "file",
                "path": str(item),  # Full absolute path
                "relativePath": relative_path,
                "isDirectory": item.is_dir(),
                "isFile": item.is_file(),
                "isSymlink": is_symlink,
                "symlinkTarget": str(os.readlink(item)) if is_symlink else None,
                "hasClaudeMd": False,
                "isGitRepo": False,
                "size": stat.st_size if item.is_file() else None,
                "lastModified": datetime.fromtimestamp(stat.st_mtime).isoformat() + "Z",
            }

            # For directories, check if they have CLAUDE.md or .git
            if item.is_dir():
                entry["hasClaudeMd"] = (item / "CLAUDE.md").exists()
                entry["isGitRepo"] = (item / ".git").exists()

            entries.append(entry)

    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")

    return {
        "path": path or "",
        "fullPath": str(target_path),
        "entries": entries,
    }


@router.get("/read")
async def read_file(
    request: Request,
    path: str = Query(..., description="Relative path to file"),
) -> dict[str, Any]:
    """
    Read a file from the vault.

    Returns:
    - path: The file path
    - content: File content (text)
    - size: File size in bytes
    - lastModified: ISO timestamp
    """
    vault_path = get_vault_path(request)
    file_path = vault_path / path

    # Security: ensure path is within vault
    try:
        file_path = file_path.resolve()
        vault_resolved = vault_path.resolve()
        if not str(file_path).startswith(str(vault_resolved)):
            raise HTTPException(status_code=403, detail="Access denied: path outside vault")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid path: {e}")

    if not file_path.exists():
        raise HTTPException(status_code=404, detail="File not found")

    if not file_path.is_file():
        raise HTTPException(status_code=400, detail="Path is not a file")

    try:
        content = file_path.read_text(encoding="utf-8")
        stat = file_path.stat()

        return {
            "path": path,
            "content": content,
            "size": stat.st_size,
            "lastModified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
        }
    except UnicodeDecodeError:
        raise HTTPException(status_code=400, detail="File is not text")
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")


@router.put("/write")
async def write_file(
    request: Request,
    body: WriteFileRequest,
) -> dict[str, Any]:
    """
    Write a file to the vault.

    Creates parent directories if needed.
    """
    vault_path = get_vault_path(request)
    file_path = vault_path / body.path

    # Security: ensure path is within vault
    try:
        # Use parent to check since file might not exist yet
        parent_path = file_path.parent.resolve()
        vault_resolved = vault_path.resolve()
        if not str(parent_path).startswith(str(vault_resolved)):
            raise HTTPException(status_code=403, detail="Access denied: path outside vault")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Invalid path: {e}")

    try:
        # Create parent directories if needed
        file_path.parent.mkdir(parents=True, exist_ok=True)

        # Write the file
        file_path.write_text(body.content, encoding="utf-8")
        stat = file_path.stat()

        logger.info(f"Wrote file: {body.path} ({stat.st_size} bytes)")

        return {
            "success": True,
            "path": body.path,
            "size": stat.st_size,
            "lastModified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
        }
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")
    except Exception as e:
        logger.error(f"Error writing file {body.path}: {e}")
        raise HTTPException(status_code=500, detail=f"Write failed: {e}")
