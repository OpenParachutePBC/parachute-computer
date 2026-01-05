"""
Import API endpoints for Claude/ChatGPT exports.
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request, UploadFile, File, Query
from pydantic import BaseModel

from ..core.import_service import ImportService
from ..core.import_curator import ImportCurator
from ..models.session import Session, SessionSource

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


class SyncResponse(BaseModel):
    """Response from sync operation."""
    discovered: int
    synced: int
    updated: int = 0
    skipped: int
    errors: list[str]


@router.post("/import/sync")
async def sync_sdk_sessions(
    request: Request,
    archived: bool = Query(True, description="Mark discovered sessions as archived"),
    force: bool = Query(False, description="Force update timestamps for existing sessions"),
) -> SyncResponse:
    """
    Discover and sync existing SDK JSONL sessions to the database.

    This scans ~/.claude/projects/{encoded-working-dir}/ for JSONL files
    that exist but don't have database records, and creates records for them.

    With force=true, also updates existing sessions with correct timestamps
    parsed from the JSONL files (useful for fixing imported sessions).

    Useful when JSONL files were created but database insertion failed,
    or when importing sessions from another machine.
    """
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Server not ready")

    database = request.app.state.database
    vault_path = str(orchestrator.vault_path)

    # Compute the SDK projects directory for this vault's Chat module
    working_directory = str(Path(vault_path) / "Chat")
    encoded_dir = working_directory.replace("/", "-")
    sdk_dir = Path.home() / ".claude" / "projects" / encoded_dir

    if not sdk_dir.exists():
        return SyncResponse(discovered=0, synced=0, skipped=0, errors=[])

    # Get existing session IDs from database (use high limit to get all)
    existing_sessions = await database.list_sessions(module="chat", limit=10000)
    existing_ids = {s.id for s in existing_sessions}

    discovered = 0
    synced = 0
    updated = 0
    skipped = 0
    errors = []

    # Scan JSONL files
    for jsonl_file in sdk_dir.glob("*.jsonl"):
        discovered += 1
        session_id = jsonl_file.stem

        already_exists = session_id in existing_ids
        if already_exists and not force:
            skipped += 1
            continue

        try:
            # Parse JSONL to extract metadata
            title = "Imported Conversation"
            message_count = 0
            created_at = None
            last_accessed = None
            source = SessionSource.PARACHUTE

            with open(jsonl_file, "r") as f:
                for line in f:
                    try:
                        event = json.loads(line.strip())
                    except json.JSONDecodeError:
                        continue

                    event_type = event.get("type")

                    # Count messages
                    if event_type in ("user", "assistant"):
                        message_count += 1

                    # Get timestamps
                    timestamp_str = event.get("timestamp")
                    if timestamp_str:
                        try:
                            ts = datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
                            if created_at is None or ts < created_at:
                                created_at = ts
                            if last_accessed is None or ts > last_accessed:
                                last_accessed = ts
                        except Exception:
                            pass

                    # Try to extract title from first user message
                    if event_type == "user" and title == "Imported Conversation":
                        msg = event.get("message", {})
                        content = msg.get("content", [])
                        if content and isinstance(content, list):
                            for block in content:
                                if isinstance(block, dict) and block.get("type") == "text":
                                    text = block.get("text", "")
                                    # Use first 50 chars as title
                                    title = text[:50].strip()
                                    if len(text) > 50:
                                        title += "..."
                                    break

                    # Check for import metadata
                    metadata = event.get("metadata", {})
                    if metadata.get("source") == "claude_web":
                        source = SessionSource.CLAUDE_WEB
                    elif metadata.get("source") == "chatgpt":
                        source = SessionSource.CHATGPT

            now = datetime.now(timezone.utc)

            if already_exists and force:
                # Update existing session with correct timestamps
                await database.connection.execute(
                    """
                    UPDATE sessions
                    SET created_at = ?, last_accessed = ?, message_count = ?
                    WHERE id = ?
                    """,
                    (
                        (created_at or now).isoformat(),
                        (last_accessed or now).isoformat(),
                        message_count,
                        session_id,
                    ),
                )
                await database.connection.commit()
                logger.info(f"[Sync] Updated timestamps for session: {session_id}")
                updated += 1
            else:
                # Create new session record
                session = Session(
                    id=session_id,
                    title=title,
                    module="chat",
                    source=source,
                    working_directory=working_directory,
                    created_at=created_at or now,
                    last_accessed=last_accessed or now,
                    message_count=message_count,
                    archived=archived,
                    metadata={"synced_at": now.isoformat()}
                )

                await database.create_session(session)
                logger.info(f"[Sync] Created session: {session_id} - {title}")
                synced += 1

        except Exception as e:
            logger.error(f"[Sync] Error processing {jsonl_file}: {e}")
            errors.append(f"Failed to sync {session_id}: {e}")

    return SyncResponse(
        discovered=discovered,
        synced=synced,
        updated=updated,
        skipped=skipped,
        errors=errors
    )


class CurateExportRequest(BaseModel):
    """Request to curate a Claude export."""
    export_path: str  # Path to extracted export directory


class CurateExportResponse(BaseModel):
    """Response from export curation."""
    success: bool
    context_files_created: list[str]
    context_files_updated: list[str]
    general_context_summary: Optional[str] = None
    project_contexts: list[dict[str, Any]] = []
    error: Optional[str] = None


@router.post("/import/curate")
async def curate_claude_export(
    request: Request,
    body: CurateExportRequest,
) -> CurateExportResponse:
    """
    Process a Claude export with the Import Curator.

    This intelligently parses memories.json and projects.json to create
    structured context files in the Parachute-native format:
    - general-context.md for personal info
    - Project-specific files for each Claude project with memories

    The curator extracts:
    - Facts (updateable)
    - Current Focus
    - History (from original export content)

    Call this AFTER extracting the export zip, passing the path to the
    extracted directory containing memories.json.
    """
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Server not ready")

    vault_path = Path(orchestrator.vault_path)
    export_path = Path(body.export_path).expanduser()

    if not export_path.exists():
        raise HTTPException(status_code=404, detail=f"Export path not found: {body.export_path}")

    # Check for memories.json
    memories_file = export_path / "memories.json"
    if not memories_file.exists():
        raise HTTPException(
            status_code=400,
            detail="memories.json not found in export. This endpoint requires a Claude export."
        )

    try:
        curator = ImportCurator(vault_path)
        result = curator.process_export(export_path)

        return CurateExportResponse(
            success=True,
            context_files_created=result.get("created", []),
            context_files_updated=result.get("updated", []),
            general_context_summary=result.get("general_summary"),
            project_contexts=result.get("projects", []),
        )
    except Exception as e:
        logger.error(f"Export curation failed: {e}", exc_info=True)
        return CurateExportResponse(
            success=False,
            context_files_created=[],
            context_files_updated=[],
            error=str(e)
        )


class ContextFilesResponse(BaseModel):
    """Response listing context files."""
    files: list[dict[str, Any]]
    total_facts: int
    total_history_entries: int


@router.get("/import/contexts")
async def list_context_files(request: Request) -> ContextFilesResponse:
    """
    List all context files with their metadata.

    Returns structured info about each context file including:
    - Name and description
    - Number of facts
    - Number of history entries
    - Last modified time
    - Whether it's in Parachute-native format
    """
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Server not ready")

    vault_path = Path(orchestrator.vault_path)

    from ..core.context_parser import ContextParser
    parser = ContextParser(vault_path)

    files = parser.list_context_files()

    total_facts = 0
    total_history = 0

    file_list = []
    for ctx in files:
        total_facts += len(ctx.facts)
        total_history += len(ctx.history)

        file_list.append({
            "path": str(ctx.path.relative_to(vault_path)),
            "name": ctx.name,
            "description": ctx.description,
            "facts_count": len(ctx.facts),
            "focus_count": len(ctx.current_focus),
            "history_count": len(ctx.history),
            "is_native_format": ctx.is_parachute_native,
            "last_modified": ctx.last_modified.isoformat() if ctx.last_modified else None,
        })

    return ContextFilesResponse(
        files=file_list,
        total_facts=total_facts,
        total_history_entries=total_history,
    )
