"""
Claude Code session import API endpoints.

Allows importing Claude Code sessions from ~/.claude/projects/
"""

import json
import logging
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel

router = APIRouter()
logger = logging.getLogger(__name__)


def get_claude_projects_dir() -> Path:
    """Get the Claude Code projects directory."""
    return Path.home() / ".claude" / "projects"


def decode_project_path(encoded_name: str) -> str:
    """Decode a project directory name to a path."""
    # Claude encodes paths by replacing / with -
    # Handle leading - which represents root /
    if encoded_name.startswith("-"):
        return "/" + encoded_name[1:].replace("-", "/")
    return encoded_name.replace("-", "/")


def get_session_info(session_file: Path, project_path: str) -> Optional[dict[str, Any]]:
    """Extract session info from a JSONL file."""
    try:
        messages = []
        model = None
        cwd = None
        first_message = None
        title = None
        first_timestamp = None
        last_timestamp = None

        with open(session_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                    event_type = event.get("type")

                    # Track timestamps
                    timestamp = event.get("timestamp")
                    if timestamp:
                        ts = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
                        if first_timestamp is None:
                            first_timestamp = ts
                        last_timestamp = ts

                    # Extract model
                    if not model and event.get("model"):
                        model = event["model"]

                    # Extract cwd
                    if not cwd and event.get("cwd"):
                        cwd = event["cwd"]

                    # Track messages
                    if event_type == "user":
                        messages.append({"type": "user", "content": _extract_content(event)})
                        if first_message is None:
                            first_message = _extract_content(event)
                    elif event_type == "assistant":
                        messages.append({"type": "assistant", "content": _extract_content(event)})
                    elif event_type == "result":
                        if event.get("result"):
                            messages.append({"type": "assistant", "content": event["result"]})

                    # Check for title in summary
                    if event.get("summary"):
                        title = event["summary"]

                except json.JSONDecodeError:
                    continue

        if not messages:
            return None

        # Generate title from first message if not found
        if not title and first_message:
            title = first_message[:60] + "..." if len(first_message) > 60 else first_message

        return {
            "sessionId": session_file.stem,
            "title": title,
            "firstMessage": first_message,
            "messageCount": len(messages),
            "model": model,
            "cwd": cwd,
            "projectPath": project_path,
            "projectDisplayName": _get_project_display_name(project_path),
            "createdAt": first_timestamp.isoformat() if first_timestamp else None,
            "lastTimestamp": last_timestamp.isoformat() if last_timestamp else None,
        }

    except Exception as e:
        logger.debug(f"Error reading session {session_file}: {e}")
        return None


def _extract_content(event: dict) -> Optional[str]:
    """Extract text content from an event."""
    message = event.get("message", {})
    content = message.get("content", [])

    if isinstance(content, str):
        return content

    if isinstance(content, list):
        text_parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text_parts.append(block.get("text", ""))
        if text_parts:
            return "\n".join(text_parts)

    return None


def _get_project_display_name(path: str) -> str:
    """Get a short display name for a project path."""
    parts = [p for p in path.split("/") if p]
    if len(parts) <= 3:
        return "/".join(parts)
    return ".../" + "/".join(parts[-3:])


@router.get("/claude-code/recent")
async def get_recent_sessions(
    request: Request,
    limit: int = Query(100, ge=1, le=500),
) -> dict[str, Any]:
    """
    Get recent Claude Code sessions across all projects.

    Returns sessions sorted by last activity (newest first).
    """
    projects_dir = get_claude_projects_dir()

    if not projects_dir.exists():
        return {"sessions": []}

    all_sessions = []

    try:
        for project_dir in projects_dir.iterdir():
            if not project_dir.is_dir():
                continue

            project_path = decode_project_path(project_dir.name)

            # Find all session files
            for session_file in project_dir.glob("*.jsonl"):
                session_info = get_session_info(session_file, project_path)
                if session_info:
                    all_sessions.append(session_info)

    except Exception as e:
        logger.error(f"Error scanning Claude projects: {e}")
        return {"sessions": []}

    # Sort by last activity (newest first)
    all_sessions.sort(
        key=lambda s: s.get("lastTimestamp") or s.get("createdAt") or "",
        reverse=True,
    )

    return {"sessions": all_sessions[:limit]}


@router.get("/claude-code/projects")
async def get_projects(request: Request) -> dict[str, Any]:
    """
    Get list of Claude Code projects (working directories).
    """
    projects_dir = get_claude_projects_dir()

    if not projects_dir.exists():
        return {"projects": []}

    projects = []

    try:
        for project_dir in projects_dir.iterdir():
            if not project_dir.is_dir():
                continue

            # Count session files
            session_count = len(list(project_dir.glob("*.jsonl")))

            if session_count > 0:
                project_path = decode_project_path(project_dir.name)
                projects.append({
                    "encodedName": project_dir.name,
                    "path": project_path,
                    "sessionCount": session_count,
                })

    except Exception as e:
        logger.error(f"Error listing Claude projects: {e}")

    # Sort by path
    projects.sort(key=lambda p: p["path"])

    return {"projects": projects}


@router.get("/claude-code/sessions")
async def get_project_sessions(
    request: Request,
    path: str = Query(..., description="Project path"),
) -> dict[str, Any]:
    """
    Get sessions for a specific Claude Code project.
    """
    projects_dir = get_claude_projects_dir()

    # Encode the path to find the directory
    encoded = path.replace("/", "-")
    if path.startswith("/"):
        encoded = "-" + path[1:].replace("/", "-")

    project_dir = projects_dir / encoded

    if not project_dir.exists():
        return {"sessions": []}

    sessions = []

    try:
        for session_file in project_dir.glob("*.jsonl"):
            session_info = get_session_info(session_file, path)
            if session_info:
                sessions.append(session_info)

    except Exception as e:
        logger.error(f"Error getting sessions for {path}: {e}")

    # Sort by last activity
    sessions.sort(
        key=lambda s: s.get("lastTimestamp") or s.get("createdAt") or "",
        reverse=True,
    )

    return {"sessions": sessions}


@router.get("/claude-code/sessions/{session_id}")
async def get_session_details(
    request: Request,
    session_id: str,
    path: Optional[str] = Query(None, description="Project path"),
) -> dict[str, Any]:
    """
    Get full details for a Claude Code session including messages.
    """
    projects_dir = get_claude_projects_dir()
    session_file = None

    if path:
        # Look in specific project
        encoded = path.replace("/", "-")
        if path.startswith("/"):
            encoded = "-" + path[1:].replace("/", "-")
        session_file = projects_dir / encoded / f"{session_id}.jsonl"
    else:
        # Search all projects
        for project_dir in projects_dir.iterdir():
            if project_dir.is_dir():
                candidate = project_dir / f"{session_id}.jsonl"
                if candidate.exists():
                    session_file = candidate
                    path = decode_project_path(project_dir.name)
                    break

    if not session_file or not session_file.exists():
        raise HTTPException(status_code=404, detail="Session not found")

    # Parse the full session
    messages = []
    model = None
    cwd = None
    title = None
    created_at = None

    try:
        with open(session_file, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                    event_type = event.get("type")

                    if not model and event.get("model"):
                        model = event["model"]
                    if not cwd and event.get("cwd"):
                        cwd = event["cwd"]
                    if event.get("summary"):
                        title = event["summary"]

                    timestamp = event.get("timestamp")
                    if timestamp and not created_at:
                        created_at = timestamp

                    if event_type == "user":
                        content = _extract_content(event)
                        if content:
                            messages.append({
                                "type": "user",
                                "content": content,
                                "timestamp": timestamp,
                            })
                    elif event_type == "assistant":
                        content = _extract_content(event)
                        if content:
                            messages.append({
                                "type": "assistant",
                                "content": content,
                                "timestamp": timestamp,
                            })
                    elif event_type == "result" and event.get("result"):
                        messages.append({
                            "type": "assistant",
                            "content": event["result"],
                            "timestamp": timestamp,
                        })

                except json.JSONDecodeError:
                    continue

    except Exception as e:
        logger.error(f"Error reading session {session_id}: {e}")
        raise HTTPException(status_code=500, detail=f"Error reading session: {e}")

    return {
        "sessionId": session_id,
        "title": title,
        "cwd": cwd,
        "model": model,
        "createdAt": created_at,
        "messages": messages,
    }


class AdoptRequest(BaseModel):
    """Request for adopting a session."""

    workingDirectory: Optional[str] = None


@router.post("/claude-code/adopt/{session_id}")
async def adopt_session(
    request: Request,
    session_id: str,
    body: Optional[AdoptRequest] = None,
    path: Optional[str] = Query(None, description="Project path"),
) -> dict[str, Any]:
    """
    Adopt a Claude Code session into Parachute.

    Creates a session record that points to the existing SDK JSONL file.
    """
    orchestrator = request.app.state.orchestrator
    if not orchestrator:
        raise HTTPException(status_code=503, detail="Server not ready")

    projects_dir = get_claude_projects_dir()
    session_file = None
    project_path = path

    if project_path:
        encoded = project_path.replace("/", "-")
        if project_path.startswith("/"):
            encoded = "-" + project_path[1:].replace("/", "-")
        session_file = projects_dir / encoded / f"{session_id}.jsonl"
    else:
        # Search all projects
        for project_dir in projects_dir.iterdir():
            if project_dir.is_dir():
                candidate = project_dir / f"{session_id}.jsonl"
                if candidate.exists():
                    session_file = candidate
                    project_path = decode_project_path(project_dir.name)
                    break

    if not session_file or not session_file.exists():
        raise HTTPException(status_code=404, detail="Session not found")

    # Get session info
    session_info = get_session_info(session_file, project_path or "")

    if not session_info:
        raise HTTPException(status_code=400, detail="Could not parse session")

    # Check if already adopted
    existing = await orchestrator.get_session(session_id)
    if existing:
        return {
            "success": True,
            "alreadyAdopted": True,
            "parachuteSessionId": session_id,
            "message": "Session was already imported",
        }

    # Create session in our database
    from parachute.models.session import SessionCreate, SessionSource

    working_dir = body.workingDirectory if body else None
    if not working_dir:
        working_dir = session_info.get("cwd") or project_path

    session = await orchestrator.session_manager.db.create_session(
        SessionCreate(
            id=session_id,
            title=session_info.get("title"),
            module="chat",
            source=SessionSource.CLAUDE_CODE,
            working_directory=working_dir,
            model=session_info.get("model"),
            message_count=session_info.get("messageCount", 0),
        )
    )

    logger.info(f"Adopted Claude Code session: {session_id}")

    return {
        "success": True,
        "alreadyAdopted": False,
        "parachuteSessionId": session_id,
        "messageCount": session_info.get("messageCount"),
        "message": f"Imported session with {session_info.get('messageCount', 0)} messages",
    }
