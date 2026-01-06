"""
API endpoints for folder-based context management.

Provides endpoints for:
- Listing available context folders (folders with AGENTS.md or CLAUDE.md)
- Getting the context chain for selected folders
- Managing session context folder selections
"""

import logging
from typing import Optional

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel, Field

from parachute.config import get_settings
from parachute.core.context_folders import ContextFolderService, get_context_folder_service

router = APIRouter()
logger = logging.getLogger(__name__)


class ContextFolderInfo(BaseModel):
    """Information about a folder with context files."""

    path: str = Field(description="Folder path relative to vault")
    context_file: str = Field(description="Which file exists: AGENTS.md or CLAUDE.md")
    has_agents_md: bool = Field(default=False)
    has_claude_md: bool = Field(default=False)
    display_name: str = Field(description="Human-readable folder name")


class ContextFoldersResponse(BaseModel):
    """Response for listing available context folders."""

    folders: list[ContextFolderInfo]
    count: int


class ContextFileInfo(BaseModel):
    """Information about a context file in the chain."""

    path: str = Field(description="File path relative to vault")
    folder_path: str = Field(description="Folder path")
    level: str = Field(description="'root', 'parent', or 'direct'")
    tokens: int = Field(default=0)
    exists: bool = Field(default=True)


class ContextChainResponse(BaseModel):
    """Response for getting the context chain."""

    files: list[ContextFileInfo]
    total_tokens: int
    truncated: bool = False


class SetSessionContextsRequest(BaseModel):
    """Request to set context folders for a session."""

    folder_paths: list[str] = Field(description="List of folder paths to set as context")


class SessionContextsResponse(BaseModel):
    """Response for session context operations."""

    session_id: str
    folder_paths: list[str]
    chain: Optional[ContextChainResponse] = None


@router.get("/folders", response_model=ContextFoldersResponse)
async def list_context_folders(request: Request):
    """
    List all folders in the vault that have AGENTS.md or CLAUDE.md files.

    These are the folders that can be selected as context for a session.
    """
    settings = get_settings()
    service = get_context_folder_service(settings.vault_path)

    try:
        folders = service.discover_folders()

        return ContextFoldersResponse(
            folders=[
                ContextFolderInfo(
                    path=f.path,
                    context_file=f.context_file,
                    has_agents_md=f.has_agents_md,
                    has_claude_md=f.has_claude_md,
                    display_name=f.display_name,
                )
                for f in folders
            ],
            count=len(folders),
        )
    except Exception as e:
        logger.error(f"Error listing context folders: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/chain", response_model=ContextChainResponse)
async def get_context_chain(
    request: Request,
    folders: str = Query(..., description="Comma-separated list of folder paths"),
    max_tokens: int = Query(50000, description="Maximum tokens to load"),
):
    """
    Get the full context chain for selected folders.

    This includes parent folders' AGENTS.md files up to the vault root.
    """
    settings = get_settings()
    service = get_context_folder_service(settings.vault_path)

    try:
        folder_list = [f.strip() for f in folders.split(",") if f.strip()]
        chain = service.build_chain(folder_list, max_tokens=max_tokens)

        return ContextChainResponse(
            files=[
                ContextFileInfo(
                    path=f.path,
                    folder_path=f.folder_path,
                    level=f.level,
                    tokens=f.tokens,
                    exists=f.exists,
                )
                for f in chain.files
            ],
            total_tokens=chain.total_tokens,
            truncated=chain.truncated,
        )
    except Exception as e:
        logger.error(f"Error getting context chain: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/session/{session_id}", response_model=SessionContextsResponse)
async def get_session_contexts(
    request: Request,
    session_id: str,
    include_chain: bool = Query(False, description="Include full context chain info"),
):
    """
    Get the context folders configured for a session.
    """
    db = request.app.state.database

    try:
        folder_paths = await db.get_session_contexts(session_id)

        result = SessionContextsResponse(
            session_id=session_id,
            folder_paths=folder_paths,
        )

        if include_chain and folder_paths:
            settings = get_settings()
            service = get_context_folder_service(settings.vault_path)
            chain = service.build_chain(folder_paths)

            result.chain = ContextChainResponse(
                files=[
                    ContextFileInfo(
                        path=f.path,
                        folder_path=f.folder_path,
                        level=f.level,
                        tokens=f.tokens,
                        exists=f.exists,
                    )
                    for f in chain.files
                ],
                total_tokens=chain.total_tokens,
                truncated=chain.truncated,
            )

        return result
    except Exception as e:
        logger.error(f"Error getting session contexts: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.put("/session/{session_id}", response_model=SessionContextsResponse)
async def set_session_contexts(
    request: Request,
    session_id: str,
    body: SetSessionContextsRequest,
):
    """
    Set the context folders for a session (replaces existing).
    """
    db = request.app.state.database

    try:
        await db.set_session_contexts(session_id, body.folder_paths)

        return SessionContextsResponse(
            session_id=session_id,
            folder_paths=body.folder_paths,
        )
    except Exception as e:
        logger.error(f"Error setting session contexts: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/session/{session_id}/add")
async def add_session_context(
    request: Request,
    session_id: str,
    folder_path: str = Query(..., description="Folder path to add"),
):
    """
    Add a context folder to a session.
    """
    db = request.app.state.database

    try:
        await db.add_session_context(session_id, folder_path)
        folder_paths = await db.get_session_contexts(session_id)

        return SessionContextsResponse(
            session_id=session_id,
            folder_paths=folder_paths,
        )
    except Exception as e:
        logger.error(f"Error adding session context: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/session/{session_id}/remove")
async def remove_session_context(
    request: Request,
    session_id: str,
    folder_path: str = Query(..., description="Folder path to remove"),
):
    """
    Remove a context folder from a session.
    """
    db = request.app.state.database

    try:
        await db.remove_session_context(session_id, folder_path)
        folder_paths = await db.get_session_contexts(session_id)

        return SessionContextsResponse(
            session_id=session_id,
            folder_paths=folder_paths,
        )
    except Exception as e:
        logger.error(f"Error removing session context: {e}")
        raise HTTPException(status_code=500, detail=str(e))
