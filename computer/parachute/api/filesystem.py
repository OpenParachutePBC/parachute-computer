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


def _check_vault_path(vault_path: Path, target: Path) -> Path:
    """Resolve target and verify it's within vault. Returns resolved path."""
    resolved = target.resolve()
    vault_resolved = vault_path.resolve()
    if not str(resolved).startswith(str(vault_resolved)):
        raise HTTPException(status_code=403, detail="Access denied: path outside vault")
    return resolved


@router.get("/ls")
async def list_directory(
    request: Request,
    path: Optional[str] = Query(None, description="Relative path within vault"),
    includeHidden: bool = Query(False, description="Include hidden files/folders"),
) -> dict[str, Any]:
    """
    List directory contents in the vault.

    Returns entries with metadata including:
    - name: Filename
    - relativePath: Path relative to vault
    - isDirectory: Whether it's a directory
    - size: File size in bytes
    - lastModified: ISO timestamp
    - hasAgentsMd: (directories only) Whether AGENTS.md exists
    - hasClaudeMd: (directories only) Whether CLAUDE.md exists
    """
    vault_path = get_vault_path(request).resolve()
    target_path = vault_path / path if path else vault_path
    target_path = _check_vault_path(vault_path, target_path)

    if not target_path.exists():
        raise HTTPException(status_code=404, detail="Path not found")

    if not target_path.is_dir():
        raise HTTPException(status_code=400, detail="Path is not a directory")

    entries = []
    try:
        for item in sorted(target_path.iterdir()):
            # Skip hidden files unless includeHidden is True
            if item.name.startswith(".") and not includeHidden:
                continue

            relative_path = str(item.relative_to(vault_path))
            is_symlink = item.is_symlink()

            # Check if symlink target exists (for broken symlink detection)
            is_broken_symlink = False
            if is_symlink:
                try:
                    item.resolve(strict=True)
                except (OSError, FileNotFoundError):
                    is_broken_symlink = True

            # Use lstat for symlinks to get info about the link itself,
            # not the target (which may not exist for broken symlinks)
            try:
                stat = item.lstat() if is_symlink else item.stat()
            except (OSError, FileNotFoundError):
                # Skip entries we can't stat at all
                continue

            # For broken symlinks, we can't determine type from target
            if is_broken_symlink:
                is_dir = False
                is_file = False
            else:
                is_dir = item.is_dir()
                is_file = item.is_file()

            entry = {
                "name": item.name,
                "type": "symlink" if is_broken_symlink else ("directory" if is_dir else "file"),
                "path": str(item),  # Full absolute path
                "relativePath": relative_path,
                "isDirectory": is_dir,
                "isFile": is_file,
                "isSymlink": is_symlink,
                "isBrokenSymlink": is_broken_symlink,
                "symlinkTarget": str(os.readlink(item)) if is_symlink else None,
                "hasAgentsMd": False,
                "hasClaudeMd": False,
                "isGitRepo": False,
                "size": stat.st_size if is_file else None,
                "lastModified": datetime.fromtimestamp(stat.st_mtime).isoformat() + "Z",
            }

            # For directories, check if they have AGENTS.md, CLAUDE.md, or .git
            # (skip for broken symlinks since we can't traverse them)
            if is_dir and not is_broken_symlink:
                entry["hasAgentsMd"] = (item / "AGENTS.md").exists()
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
    vault_path = get_vault_path(request).resolve()
    file_path = _check_vault_path(vault_path, vault_path / path)

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
    vault_path = get_vault_path(request).resolve()
    file_path = vault_path / body.path
    _check_vault_path(vault_path, file_path.parent)

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
