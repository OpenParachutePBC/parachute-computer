"""
Import API endpoints for Claude/ChatGPT exports.
"""

import logging
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request, UploadFile, File, Query
from pydantic import BaseModel

from ..core.import_service import ImportService

router = APIRouter()
logger = logging.getLogger(__name__)


def get_import_service(request: Request) -> ImportService:
    """Get import service from app state."""
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Server not ready")
    vault_path = str(orchestrator.vault_path)
    database = request.app.state.database
    return ImportService(vault_path, database)


class ImportResponse(BaseModel):
    """Response from import operation."""
    total_conversations: int
    imported_count: int
    skipped_count: int
    errors: list[str]
    session_ids: list[str]


class ImportJsonRequest(BaseModel):
    """Request body for JSON import."""
    data: Any  # The parsed JSON export data
    archived: bool = True


@router.post("/import")
async def import_from_json(
    request: Request,
    body: ImportJsonRequest,
) -> ImportResponse:
    """
    Import conversations from Claude/ChatGPT JSON export data.

    The request body should contain:
    - data: The parsed JSON from a conversations.json export
    - archived: Whether to mark imported sessions as archived (default: true)

    Supports:
    - Claude.ai exports (conversations.json from data export)
    - ChatGPT exports (conversations.json from data export)

    The service automatically detects the format and converts all conversations
    to SDK JSONL format, storing them in ~/.claude/projects/ and the SQLite database.
    """
    import_service = get_import_service(request)

    try:
        result = await import_service.import_from_json(
            body.data,
            archived=body.archived
        )

        return ImportResponse(
            total_conversations=result.total_conversations,
            imported_count=result.imported_count,
            skipped_count=result.skipped_count,
            errors=result.errors,
            session_ids=result.session_ids
        )
    except Exception as e:
        logger.error(f"Import failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Import failed: {e}")


@router.post("/import/file")
async def import_from_file_upload(
    request: Request,
    file: UploadFile = File(...),
    archived: bool = Query(True, description="Mark imported sessions as archived"),
) -> ImportResponse:
    """
    Import conversations from an uploaded JSON file.

    Upload a conversations.json file from Claude.ai or ChatGPT data export.
    The service automatically detects the format.
    """
    import_service = get_import_service(request)

    try:
        # Read and parse uploaded file
        content = await file.read()
        import json
        data = json.loads(content.decode("utf-8"))

        result = await import_service.import_from_json(data, archived=archived)

        return ImportResponse(
            total_conversations=result.total_conversations,
            imported_count=result.imported_count,
            skipped_count=result.skipped_count,
            errors=result.errors,
            session_ids=result.session_ids
        )
    except json.JSONDecodeError as e:
        raise HTTPException(status_code=400, detail=f"Invalid JSON: {e}")
    except Exception as e:
        logger.error(f"Import failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Import failed: {e}")


@router.post("/import/path")
async def import_from_path(
    request: Request,
    path: str = Query(..., description="Path to conversations.json file"),
    archived: bool = Query(True, description="Mark imported sessions as archived"),
) -> ImportResponse:
    """
    Import conversations from a file path on the server.

    Useful for importing from ~/Parachute/imports/ or similar directories.
    """
    import_service = get_import_service(request)

    import os
    if not os.path.exists(path):
        raise HTTPException(status_code=404, detail=f"File not found: {path}")

    try:
        result = await import_service.import_from_file(path, archived=archived)

        return ImportResponse(
            total_conversations=result.total_conversations,
            imported_count=result.imported_count,
            skipped_count=result.skipped_count,
            errors=result.errors,
            session_ids=result.session_ids
        )
    except Exception as e:
        logger.error(f"Import failed: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=f"Import failed: {e}")
