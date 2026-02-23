#!/usr/bin/env python3
"""
Parachute MCP Server

Provides search access to Parachute data via Model Context Protocol.
Covers both Chat sessions and Daily journals.

Chat Session Tools:
- search_sessions: Search chat sessions by keyword
- list_recent_sessions: List recent sessions
- get_session: Get a specific session with messages
- search_by_tag: Search sessions with specific tags
- list_tags / add_session_tag / remove_session_tag

Daily Journal Tools:
- search_journals: Search journal entries by keyword
- list_recent_journals: List recent journal dates
- get_journal: Get a specific day's journal entries

Run with:
    python -m parachute.mcp_server /path/to/vault
"""

import argparse
import asyncio
import json
import logging
import os
import re
import sys
import urllib.parse
import uuid

import httpx
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional, Self

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

# Configure logging to stderr (stdout is for MCP protocol)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("ParachuteMCP")

# Global database connection
_db = None
_vault_path = None
_brain_base_url: str = ""


@dataclass(frozen=True, slots=True)
class SessionContext:
    """Immutable session context injected by orchestrator via env vars."""
    session_id: str | None
    workspace_id: str | None
    trust_level: str | None  # Will be normalized to TrustLevelStr

    @classmethod
    def from_env(cls) -> Self:
        """Read session context from environment variables.

        Normalizes trust level to canonical TrustLevelStr values.
        Validates session_id and workspace_id formats.
        """
        from parachute.core.trust import normalize_trust_level

        # Session ID validation (sess_{hex16} or full UUID)
        session_id = os.getenv("PARACHUTE_SESSION_ID")
        if session_id:
            session_pattern = re.compile(
                r'^sess_[a-f0-9]{16}$|^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
            )
            if not session_pattern.match(session_id):
                logger.warning(f"Invalid session_id format from env: {session_id!r}")
                session_id = None

        # Workspace ID validation (alphanumeric + hyphens, lowercase)
        workspace_id = os.getenv("PARACHUTE_WORKSPACE_ID")
        if workspace_id:
            workspace_pattern = re.compile(r'^[a-z0-9-]+$')
            if not workspace_pattern.match(workspace_id):
                logger.warning(f"Invalid workspace_id format from env: {workspace_id!r}")
                workspace_id = None

        raw_trust = os.getenv("PARACHUTE_TRUST_LEVEL")
        return cls(
            session_id=session_id,
            workspace_id=workspace_id,
            trust_level=normalize_trust_level(raw_trust) if raw_trust else None,
        )

    @property
    def is_available(self) -> bool:
        """Check if session context is fully populated."""
        return all([self.session_id, self.workspace_id, self.trust_level])


# Module-level session context singleton
_session_context: SessionContext | None = None


async def get_db():
    """Get or create database connection."""
    global _db, _vault_path
    if _db is None:
        from parachute.db.database import Database
        db_path = Path(_vault_path) / "Chat" / "sessions.db"
        _db = Database(db_path)
        await _db.connect()
        logger.info(f"Connected to database: {db_path}")
    return _db


def _validate_message_content(
    content: str,
    field_name: str = "message",
    max_length: int = 50_000
) -> Optional[str]:
    """Validate message content.

    Returns:
        Error message if invalid, None if valid.
    """
    if len(content) > max_length:
        return f"{field_name.capitalize()} too long (max {max_length:,} characters)"

    control_chars = [c for c in content if ord(c) < 32 and c not in '\n\r\t']
    if control_chars:
        return f"{field_name.capitalize()} contains invalid control characters"

    return None


# Tool definitions
TOOLS = [
    Tool(
        name="search_sessions",
        description="Search chat sessions by keyword. Returns matching sessions with titles and snippets.",
        inputSchema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query - keywords to find in session titles and content",
                },
                "limit": {
                    "type": "number",
                    "description": "Maximum number of results (default: 10)",
                    "default": 10,
                },
                "tags": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional: filter by tags",
                },
                "source": {
                    "type": "string",
                    "description": "Optional: filter by source (parachute, claude, chatgpt, claude-code)",
                },
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="list_recent_sessions",
        description="List recent chat sessions, optionally filtered by module or archived status.",
        inputSchema={
            "type": "object",
            "properties": {
                "limit": {
                    "type": "number",
                    "description": "Maximum number of sessions to return (default: 20)",
                    "default": 20,
                },
                "archived": {
                    "type": "boolean",
                    "description": "Include archived sessions (default: false)",
                    "default": False,
                },
                "module": {
                    "type": "string",
                    "description": "Filter by module (chat, daily, build)",
                },
            },
        },
    ),
    Tool(
        name="get_session",
        description="Get a specific session by ID, including its messages.",
        inputSchema={
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "The session ID to retrieve",
                },
                "include_messages": {
                    "type": "boolean",
                    "description": "Include full message history (default: true)",
                    "default": True,
                },
            },
            "required": ["session_id"],
        },
    ),
    Tool(
        name="search_by_tag",
        description="Find all sessions with a specific tag.",
        inputSchema={
            "type": "object",
            "properties": {
                "tag": {
                    "type": "string",
                    "description": "Tag to search for",
                },
                "limit": {
                    "type": "number",
                    "description": "Maximum number of results (default: 20)",
                    "default": 20,
                },
            },
            "required": ["tag"],
        },
    ),
    Tool(
        name="list_tags",
        description="List all tags with their usage counts.",
        inputSchema={
            "type": "object",
            "properties": {},
        },
    ),
    Tool(
        name="add_session_tag",
        description="Add a tag to a session.",
        inputSchema={
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "Session ID to tag",
                },
                "tag": {
                    "type": "string",
                    "description": "Tag to add",
                },
            },
            "required": ["session_id", "tag"],
        },
    ),
    Tool(
        name="remove_session_tag",
        description="Remove a tag from a session.",
        inputSchema={
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "Session ID",
                },
                "tag": {
                    "type": "string",
                    "description": "Tag to remove",
                },
            },
            "required": ["session_id", "tag"],
        },
    ),
    # Multi-Agent Session Tools
    Tool(
        name="create_session",
        description="Create a child session in the caller's workspace. Workspace and trust level are inherited from session context. Enforces spawn limits (max 10 children) and rate limiting (1/second).",
        inputSchema={
            "type": "object",
            "properties": {
                "title": {
                    "type": "string",
                    "description": "Title for the new session",
                },
                "agent_type": {
                    "type": "string",
                    "description": "Agent type/name (alphanumeric, hyphens, underscores only)",
                },
                "initial_message": {
                    "type": "string",
                    "description": "Initial message to send to the new session (max 50k chars)",
                },
            },
            "required": ["title", "agent_type", "initial_message"],
        },
    ),
    Tool(
        name="send_message",
        description="Send a message to another session in the same workspace. Enforces workspace boundary and trust level restrictions (sandboxed can only message sandboxed).",
        inputSchema={
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "Recipient session ID",
                },
                "message": {
                    "type": "string",
                    "description": "Message to send (max 50k chars)",
                },
            },
            "required": ["session_id", "message"],
        },
    ),
    Tool(
        name="list_workspace_sessions",
        description="List all sessions in the caller's workspace. Respects trust level restrictions (sandboxed only sees sandboxed sessions). Returns session metadata including parent-child relationships.",
        inputSchema={
            "type": "object",
            "properties": {},
        },
    ),
    # Daily Journal Tools
    Tool(
        name="search_journals",
        description="Search Daily journal entries by keyword. Returns matching entries with snippets.",
        inputSchema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query - keywords to find in journal entries",
                },
                "limit": {
                    "type": "number",
                    "description": "Maximum number of results (default: 10)",
                    "default": 10,
                },
                "date_from": {
                    "type": "string",
                    "description": "Start date (YYYY-MM-DD format)",
                },
                "date_to": {
                    "type": "string",
                    "description": "End date (YYYY-MM-DD format)",
                },
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="list_recent_journals",
        description="List recent journal dates.",
        inputSchema={
            "type": "object",
            "properties": {
                "limit": {
                    "type": "number",
                    "description": "Maximum number of dates to return (default: 14)",
                    "default": 14,
                },
            },
        },
    ),
    Tool(
        name="get_journal",
        description="Get a specific day's journal entries.",
        inputSchema={
            "type": "object",
            "properties": {
                "date": {
                    "type": "string",
                    "description": "Date in YYYY-MM-DD format",
                },
            },
            "required": ["date"],
        },
    ),
    # Brain Knowledge Graph Tools
    Tool(
        name="brain_list_types",
        description="List all Brain schema types with field definitions and entity counts.",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="brain_create_type",
        description="Create a new Brain schema type (class) with field definitions.",
        inputSchema={
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "PascalCase type name (e.g. 'Project', 'Person')"},
                "fields": {
                    "type": "object",
                    "description": "Field definitions keyed by snake_case field name",
                    "additionalProperties": {
                        "type": "object",
                        "properties": {
                            "type": {"type": "string", "enum": ["string", "integer", "boolean", "datetime", "enum", "link"]},
                            "required": {"type": "boolean"},
                            "values": {"type": "array", "items": {"type": "string"}},
                            "link_type": {"type": "string"},
                            "description": {"type": "string"},
                        },
                        "required": ["type"],
                    },
                },
                "key_strategy": {"type": "string", "enum": ["Random", "Lexical", "Hash", "ValueHash"]},
                "description": {"type": "string"},
            },
            "required": ["name", "fields"],
        },
    ),
    Tool(
        name="brain_update_type",
        description="Update an existing Brain schema type's fields (full field replacement).",
        inputSchema={
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Type name to update"},
                "fields": {
                    "type": "object",
                    "additionalProperties": {
                        "type": "object",
                        "properties": {
                            "type": {"type": "string", "enum": ["string", "integer", "boolean", "datetime", "enum", "link"]},
                            "required": {"type": "boolean"},
                            "values": {"type": "array", "items": {"type": "string"}},
                            "link_type": {"type": "string"},
                            "description": {"type": "string"},
                        },
                        "required": ["type"],
                    },
                },
            },
            "required": ["name", "fields"],
        },
    ),
    Tool(
        name="brain_delete_type",
        description="Delete a Brain schema type. Blocked if entities of this type exist.",
        inputSchema={
            "type": "object",
            "properties": {"name": {"type": "string", "description": "Type name to delete"}},
            "required": ["name"],
        },
    ),
    Tool(
        name="brain_create_entity",
        description="Create a new entity in the Brain knowledge graph with schema validation.",
        inputSchema={
            "type": "object",
            "properties": {
                "entity_type": {"type": "string", "description": "Type name (e.g. 'Person', 'Project')"},
                "data": {"type": "object", "description": "Entity fields as key-value pairs"},
                "commit_msg": {"type": "string"},
            },
            "required": ["entity_type", "data"],
        },
    ),
    Tool(
        name="brain_query_entities",
        description="Query Brain entities by type with optional pagination.",
        inputSchema={
            "type": "object",
            "properties": {
                "entity_type": {"type": "string"},
                "limit": {"type": "integer", "default": 100},
                "offset": {"type": "integer", "default": 0},
            },
            "required": ["entity_type"],
        },
    ),
    Tool(
        name="brain_get_entity",
        description="Retrieve a specific Brain entity by its IRI.",
        inputSchema={
            "type": "object",
            "properties": {"entity_id": {"type": "string", "description": "Entity IRI (e.g., 'Person/john_doe')"}},
            "required": ["entity_id"],
        },
    ),
    Tool(
        name="brain_update_entity",
        description="Update an existing Brain entity's fields (partial update).",
        inputSchema={
            "type": "object",
            "properties": {
                "entity_id": {"type": "string"},
                "data": {"type": "object"},
                "commit_msg": {"type": "string"},
            },
            "required": ["entity_id", "data"],
        },
    ),
    Tool(
        name="brain_delete_entity",
        description="Delete a Brain entity and all its relationships.",
        inputSchema={
            "type": "object",
            "properties": {
                "entity_id": {"type": "string"},
                "commit_msg": {"type": "string"},
            },
            "required": ["entity_id"],
        },
    ),
    Tool(
        name="brain_create_relationship",
        description="Create a relationship between two Brain entities.",
        inputSchema={
            "type": "object",
            "properties": {
                "from_id": {"type": "string"},
                "relationship": {"type": "string"},
                "to_id": {"type": "string"},
            },
            "required": ["from_id", "relationship", "to_id"],
        },
    ),
    Tool(
        name="brain_traverse_graph",
        description="Traverse the Brain knowledge graph from a starting entity following relationships.",
        inputSchema={
            "type": "object",
            "properties": {
                "start_id": {"type": "string"},
                "relationship": {"type": "string"},
                "max_depth": {"type": "integer", "default": 2},
            },
            "required": ["start_id", "relationship"],
        },
    ),
    Tool(
        name="brain_list_saved_queries",
        description="List all saved filter queries for Brain.",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="brain_save_query",
        description="Save a named filter query for Brain for later reuse.",
        inputSchema={
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "entity_type": {"type": "string"},
                "filters": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "field_name": {"type": "string"},
                            "operator": {"type": "string", "enum": ["eq", "neq", "contains"]},
                            "value": {},
                        },
                        "required": ["field_name", "operator", "value"],
                    },
                },
            },
            "required": ["name", "entity_type", "filters"],
        },
    ),
    Tool(
        name="brain_delete_saved_query",
        description="Delete a Brain saved query by its ID.",
        inputSchema={
            "type": "object",
            "properties": {"query_id": {"type": "string"}},
            "required": ["query_id"],
        },
    ),
]


async def search_sessions(
    query: str,
    limit: int = 10,
    tags: Optional[list[str]] = None,
    source: Optional[str] = None,
) -> list[dict[str, Any]]:
    """Search sessions by keyword in title."""
    db = await get_db()

    # Build query - search in title for now
    # TODO: Add full-text search in chunks when indexed
    sql = "SELECT * FROM sessions WHERE title LIKE ?"
    params: list[Any] = [f"%{query}%"]

    if source:
        sql += " AND source = ?"
        params.append(source)

    if tags:
        # Join with session_tags
        tag_placeholders = ",".join("?" * len(tags))
        sql = f"""
            SELECT DISTINCT s.* FROM sessions s
            JOIN session_tags t ON s.id = t.session_id
            WHERE s.title LIKE ? AND t.tag IN ({tag_placeholders})
        """
        params = [f"%{query}%"] + [tag.lower() for tag in tags]
        if source:
            sql += " AND s.source = ?"
            params.append(source)

    sql += " ORDER BY last_accessed DESC LIMIT ?"
    params.append(limit)

    async with db.connection.execute(sql, params) as cursor:
        rows = await cursor.fetchall()
        return [
            {
                "id": row["id"],
                "title": row["title"],
                "source": row["source"],
                "module": row["module"],
                "message_count": row["message_count"],
                "created_at": row["created_at"],
                "last_accessed": row["last_accessed"],
                "archived": bool(row["archived"]),
            }
            for row in rows
        ]


async def list_recent_sessions(
    limit: int = 20,
    archived: bool = False,
    module: Optional[str] = None,
) -> list[dict[str, Any]]:
    """List recent sessions."""
    db = await get_db()
    sessions = await db.list_sessions(
        module=module,
        archived=archived,
        limit=limit,
    )
    return [
        {
            "id": s.id,
            "title": s.title,
            "source": s.source.value,
            "module": s.module,
            "message_count": s.message_count,
            "created_at": s.created_at.isoformat(),
            "last_accessed": s.last_accessed.isoformat(),
            "archived": s.archived,
        }
        for s in sessions
    ]


async def get_session(
    session_id: str,
    include_messages: bool = True,
) -> Optional[dict[str, Any]]:
    """Get a session by ID with optional messages."""
    db = await get_db()
    session = await db.get_session(session_id)

    if not session:
        return None

    result = {
        "id": session.id,
        "title": session.title,
        "source": session.source.value,
        "module": session.module,
        "message_count": session.message_count,
        "created_at": session.created_at.isoformat(),
        "last_accessed": session.last_accessed.isoformat(),
        "archived": session.archived,
        "working_directory": session.working_directory,
        "model": session.model,
    }

    # Get tags
    tags = await db.get_session_tags(session_id)
    result["tags"] = tags

    if include_messages:
        # Load messages from SDK JSONL file
        from parachute.core.session_manager import SessionManager
        sm = SessionManager(Path(_vault_path), db)
        session_with_messages = await sm.get_session_with_messages(session_id)
        if session_with_messages:
            result["messages"] = session_with_messages.messages
        else:
            result["messages"] = []

    return result


async def search_by_tag(tag: str, limit: int = 20) -> list[dict[str, Any]]:
    """Find sessions with a specific tag."""
    db = await get_db()
    sessions = await db.get_sessions_by_tag(tag, limit=limit)
    return [
        {
            "id": s.id,
            "title": s.title,
            "source": s.source.value,
            "module": s.module,
            "message_count": s.message_count,
            "last_accessed": s.last_accessed.isoformat(),
        }
        for s in sessions
    ]


async def list_tags() -> list[dict[str, Any]]:
    """List all tags with counts."""
    db = await get_db()
    tags = await db.list_all_tags()
    return [{"tag": tag, "count": count} for tag, count in tags]


async def add_session_tag(session_id: str, tag: str) -> dict[str, Any]:
    """Add a tag to a session."""
    db = await get_db()
    await db.add_tag(session_id, tag)
    return {"success": True, "session_id": session_id, "tag": tag}


async def remove_session_tag(session_id: str, tag: str) -> dict[str, Any]:
    """Remove a tag from a session."""
    db = await get_db()
    await db.remove_tag(session_id, tag)
    return {"success": True, "session_id": session_id, "tag": tag, "removed": True}


# =============================================================================
# Multi-Agent Session Functions
# =============================================================================


async def create_session(
    title: str,
    agent_type: str,
    initial_message: str,
) -> dict[str, Any]:
    """
    Create a child session in the caller's workspace.

    Workspace and trust level are inherited from session context env vars.
    Enforces spawn limits (max 10 children) and rate limiting (1/second).
    """
    # Validate session context is available
    if not _session_context or not _session_context.is_available:
        return {
            "error": "Session context not available. This tool can only be called from an active session."
        }

    # Validate inputs
    if not title or not title.strip():
        return {"error": "Title cannot be empty"}

    if not agent_type or not agent_type.strip():
        return {"error": "Agent type cannot be empty"}

    if not initial_message or not initial_message.strip():
        return {"error": "Initial message cannot be empty"}

    # Sanitize agent_type (alphanumeric, hyphens, underscores only)
    if not re.match(r'^[a-zA-Z0-9_-]+$', agent_type):
        return {
            "error": f"Invalid agent_type: must contain only letters, numbers, hyphens, and underscores"
        }

    # Content validation (max 50k chars, no control chars except newlines/tabs)
    if error := _validate_message_content(initial_message, "initial message"):
        return {"error": error}

    db = await get_db()
    parent_session_id = _session_context.session_id
    workspace_id = _session_context.workspace_id
    trust_level = _session_context.trust_level

    # Enforce spawn limit (max 10 children)
    child_count = await db.count_children(parent_session_id)
    if child_count >= 10:
        return {
            "error": f"Spawn limit reached: {child_count}/10 children. Archive or delete child sessions to spawn more."
        }

    # Enforce rate limiting (1 session per second)
    last_created = await db.get_last_child_created(parent_session_id)
    if last_created:
        time_since_last = datetime.now(timezone.utc) - last_created
        if time_since_last < timedelta(seconds=1):
            return {
                "error": f"Rate limit: can only create 1 session per second. Wait {1 - time_since_last.total_seconds():.1f}s."
            }

    # Create SDK session
    from parachute.core.session_manager import SessionManager
    from parachute.models.session import SessionCreate, SessionSource

    session_id = f"sess_{uuid.uuid4().hex[:16]}"

    session_create = SessionCreate(
        id=session_id,
        title=title.strip(),
        module="chat",
        source=SessionSource.PARACHUTE,
        working_directory=None,  # Inherit from workspace
        agent_type=agent_type,
        trust_level=trust_level,
        workspace_id=workspace_id,
        parent_session_id=parent_session_id,
        created_by=f"agent:{parent_session_id}",
    )

    # Create session in database
    session = await db.create_session(session_create)

    # Initialize SDK session with initial message
    sm = SessionManager(Path(_vault_path), db)
    try:
        # Start the session with initial message
        await sm.init_session(
            session_id=session_id,
            workspace_id=workspace_id,
            trust_level=trust_level,
        )

        # The initial message will be sent via the orchestrator
        # For now, we just create the session
        logger.info(f"Created child session {session_id} (parent: {parent_session_id}, workspace: {workspace_id})")

        return {
            "success": True,
            "session_id": session_id,
            "title": title,
            "agent_type": agent_type,
            "workspace_id": workspace_id,
            "trust_level": trust_level,
            "parent_session_id": parent_session_id,
            "initial_message_queued": True,
            "note": "Session created. Use send_message to deliver the initial message.",
        }
    except Exception as e:
        # Rollback: delete the session if SDK init fails
        await db.delete_session(session_id)
        logger.error(f"Failed to initialize child session {session_id}: {e}")
        return {"error": f"Failed to initialize session: {str(e)}"}


async def send_message(
    session_id: str,
    message: str,
) -> dict[str, Any]:
    """
    Send a message to another session in the same workspace.

    Enforces workspace boundary and trust level restrictions.
    """
    # Validate session context is available
    if not _session_context or not _session_context.is_available:
        return {
            "error": "Session context not available. This tool can only be called from an active session."
        }

    # Validate inputs
    if not session_id or not session_id.strip():
        return {"error": "Session ID cannot be empty"}

    if not message or not message.strip():
        return {"error": "Message cannot be empty"}

    # Content validation (max 50k chars, no control chars except newlines/tabs)
    if error := _validate_message_content(message):
        return {"error": error}

    db = await get_db()
    sender_session_id = _session_context.session_id
    sender_workspace_id = _session_context.workspace_id
    sender_trust_level = _session_context.trust_level

    # Get recipient session
    recipient_session = await db.get_session(session_id.strip())
    if not recipient_session:
        return {"error": f"Recipient session not found: {session_id}"}

    # Enforce workspace boundary
    recipient_workspace_id = recipient_session.workspace_id
    if recipient_workspace_id != sender_workspace_id:
        return {
            "error": f"Cannot send message across workspace boundaries (sender: {sender_workspace_id}, recipient: {recipient_workspace_id})"
        }

    # Enforce trust level restrictions (sandboxed can only message sandboxed)
    recipient_trust_level = recipient_session.get_trust_level().value
    if sender_trust_level == "sandboxed" and recipient_trust_level != "sandboxed":
        return {
            "error": f"Sandboxed sessions can only message other sandboxed sessions (recipient trust: {recipient_trust_level})"
        }

    # Message delivery: inject into recipient's SDK session
    # For MVP, we'll just log the message - actual delivery requires SDK integration
    logger.info(
        f"Message delivery: {sender_session_id[:8]}→{session_id[:8]} (workspace: {sender_workspace_id})"
    )

    # TODO: Implement actual message injection into SDK session
    # This requires extending the SDK to support mid-stream message injection
    # Return error until delivery is implemented to maintain honest contract
    return {
        "error": "Message delivery not yet implemented. Validation passed, but delivery requires SDK mid-stream message injection support.",
        "validation_passed": True,
        "sender_session_id": sender_session_id,
        "recipient_session_id": session_id,
        "workspace_id": sender_workspace_id,
    }


async def list_workspace_sessions() -> dict[str, Any]:
    """
    List all sessions in the caller's workspace.

    Respects trust level restrictions (sandboxed only sees sandboxed sessions).
    Returns session metadata including parent-child relationships.
    """
    # Validate session context is available
    if not _session_context or not _session_context.is_available:
        return {
            "error": "Session context not available. This tool can only be called from an active session."
        }

    db = await get_db()
    workspace_id = _session_context.workspace_id
    trust_level = _session_context.trust_level

    # Get sessions in the workspace with trust level filtering at SQL level
    if trust_level == "sandboxed":
        # Sandboxed sessions only see other sandboxed sessions
        sessions = await db.list_sessions(
            workspace_id=workspace_id,
            trust_level="sandboxed",
            limit=1000
        )
    else:
        # Direct sessions see all sessions
        sessions = await db.list_sessions(workspace_id=workspace_id, limit=1000)

    # Format response
    result_sessions = []
    for session in sessions:
        result_sessions.append({
            "id": session.id,
            "title": session.title,
            "agent_type": session.agent_type,
            "trust_level": session.get_trust_level().value,
            "source": session.source.value,
            "module": session.module,
            "message_count": session.message_count,
            "created_at": session.created_at.isoformat(),
            "last_accessed": session.last_accessed.isoformat(),
            "archived": session.archived,
            "parent_session_id": session.parent_session_id,
            "created_by": session.created_by,
        })

    return {
        "workspace_id": workspace_id,
        "caller_trust_level": trust_level,
        "total_sessions": len(result_sessions),
        "sessions": result_sessions,
    }


# =============================================================================
# Daily Journal Functions
# =============================================================================

def get_journals_path() -> Path:
    """Get the path to the Daily journals folder."""
    return Path(_vault_path) / "Daily" / "journals"


async def search_journals(
    query: str,
    limit: int = 10,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
) -> list[dict[str, Any]]:
    """Search journal entries by keyword."""
    journals_path = get_journals_path()
    if not journals_path.exists():
        return []

    results = []
    query_lower = query.lower()

    # Get all journal files, sorted by date descending
    journal_files = sorted(
        [f for f in journals_path.glob("*.md") if f.name != "ids.jsonl"],
        key=lambda f: f.stem,
        reverse=True,
    )

    # Apply date filters
    if date_from:
        journal_files = [f for f in journal_files if f.stem >= date_from]
    if date_to:
        journal_files = [f for f in journal_files if f.stem <= date_to]

    for journal_file in journal_files:
        if len(results) >= limit:
            break

        try:
            content = await asyncio.to_thread(journal_file.read_text, encoding="utf-8")

            # Search in content
            if query_lower in content.lower():
                # Extract matching entries
                entries = content.split("\n# para:daily:")
                for i, entry in enumerate(entries[1:], 1):  # Skip first (frontmatter)
                    if query_lower in entry.lower():
                        # Extract entry ID and time from header
                        lines = entry.strip().split("\n")
                        if lines:
                            header = lines[0]
                            entry_content = "\n".join(lines[1:]).strip()

                            # Create snippet around match
                            match_pos = entry_content.lower().find(query_lower)
                            if match_pos >= 0:
                                start = max(0, match_pos - 50)
                                end = min(len(entry_content), match_pos + len(query) + 100)
                                snippet = entry_content[start:end]
                                if start > 0:
                                    snippet = "..." + snippet
                                if end < len(entry_content):
                                    snippet = snippet + "..."
                            else:
                                snippet = entry_content[:150] + "..." if len(entry_content) > 150 else entry_content

                            results.append({
                                "date": journal_file.stem,
                                "entry_header": header.strip(),
                                "snippet": snippet,
                                "file": str(journal_file.name),
                            })

                            if len(results) >= limit:
                                break
        except Exception as e:
            logger.warning(f"Error reading journal {journal_file}: {e}")
            continue

    return results


async def list_recent_journals(limit: int = 14) -> list[dict[str, Any]]:
    """List recent journal dates."""
    journals_path = get_journals_path()
    if not journals_path.exists():
        return []

    # Get all journal files, sorted by date descending
    journal_files = sorted(
        [f for f in journals_path.glob("*.md") if f.name != "ids.jsonl"],
        key=lambda f: f.stem,
        reverse=True,
    )[:limit]

    results = []
    for journal_file in journal_files:
        try:
            content = await asyncio.to_thread(journal_file.read_text, encoding="utf-8")
            # Count entries (each starts with # para:daily:)
            entry_count = content.count("# para:daily:")

            results.append({
                "date": journal_file.stem,
                "entry_count": entry_count,
                "file": str(journal_file.name),
            })
        except Exception as e:
            logger.warning(f"Error reading journal {journal_file}: {e}")
            results.append({
                "date": journal_file.stem,
                "entry_count": 0,
                "file": str(journal_file.name),
                "error": str(e),
            })

    return results


async def get_journal(date: str) -> Optional[dict[str, Any]]:
    """Get a specific day's journal."""
    journals_path = get_journals_path()
    journal_file = journals_path / f"{date}.md"

    if not journal_file.exists():
        return None

    try:
        content = await asyncio.to_thread(journal_file.read_text, encoding="utf-8")

        # Parse entries
        entries = []
        parts = content.split("\n# para:daily:")

        for i, part in enumerate(parts[1:], 1):  # Skip frontmatter
            lines = part.strip().split("\n")
            if lines:
                header = lines[0].strip()
                entry_content = "\n".join(lines[1:]).strip()

                # Extract ID and time from header like "g2jvjpj4g9tk 07:30"
                header_parts = header.split(" ", 1)
                entry_id = header_parts[0] if header_parts else ""
                entry_time = header_parts[1] if len(header_parts) > 1 else ""

                entries.append({
                    "id": entry_id,
                    "time": entry_time,
                    "content": entry_content,
                })

        return {
            "date": date,
            "file": str(journal_file.name),
            "entry_count": len(entries),
            "entries": entries,
            "raw_content": content,
        }
    except Exception as e:
        logger.error(f"Error reading journal {journal_file}: {e}")
        return {"date": date, "error": str(e)}


async def _brain_call(method: str, path: str, **kwargs) -> dict[str, Any]:
    """Make an HTTP call to the local brain API."""
    if not _brain_base_url:
        return {"error": "Brain module not available"}
    url = f"{_brain_base_url}{path}"
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await getattr(client, method)(url, **kwargs)
            if response.status_code >= 400:
                try:
                    detail = response.json().get("detail", response.text)
                except Exception:
                    detail = response.text
                return {"error": detail, "status_code": response.status_code}
            return response.json()
    except httpx.ConnectError:
        return {"error": "Brain API unavailable — is the server running?"}
    except Exception as e:
        logger.error(f"Brain API call failed ({method} {path}): {e}")
        return {"error": str(e)}


async def handle_tool_call(name: str, arguments: dict[str, Any]) -> str:
    """Handle a tool call and return the result as JSON string."""
    try:
        if name == "search_sessions":
            result = await search_sessions(
                query=arguments["query"],
                limit=arguments.get("limit", 10),
                tags=arguments.get("tags"),
                source=arguments.get("source"),
            )
        elif name == "list_recent_sessions":
            result = await list_recent_sessions(
                limit=arguments.get("limit", 20),
                archived=arguments.get("archived", False),
                module=arguments.get("module"),
            )
        elif name == "get_session":
            result = await get_session(
                session_id=arguments["session_id"],
                include_messages=arguments.get("include_messages", True),
            )
            if result is None:
                return json.dumps({"error": f"Session not found: {arguments['session_id']}"})
        elif name == "search_by_tag":
            result = await search_by_tag(
                tag=arguments["tag"],
                limit=arguments.get("limit", 20),
            )
        elif name == "list_tags":
            result = await list_tags()
        elif name == "add_session_tag":
            result = await add_session_tag(
                session_id=arguments["session_id"],
                tag=arguments["tag"],
            )
        elif name == "remove_session_tag":
            result = await remove_session_tag(
                session_id=arguments["session_id"],
                tag=arguments["tag"],
            )
        # Multi-Agent Session Tools
        elif name == "create_session":
            result = await create_session(
                title=arguments["title"],
                agent_type=arguments["agent_type"],
                initial_message=arguments["initial_message"],
            )
        elif name == "send_message":
            result = await send_message(
                session_id=arguments["session_id"],
                message=arguments["message"],
            )
        elif name == "list_workspace_sessions":
            result = await list_workspace_sessions()
        # Daily Journal Tools
        elif name == "search_journals":
            result = await search_journals(
                query=arguments["query"],
                limit=arguments.get("limit", 10),
                date_from=arguments.get("date_from"),
                date_to=arguments.get("date_to"),
            )
        elif name == "list_recent_journals":
            result = await list_recent_journals(
                limit=arguments.get("limit", 14),
            )
        elif name == "get_journal":
            result = await get_journal(date=arguments["date"])
            if result is None:
                return json.dumps({"error": f"Journal not found for date: {arguments['date']}"})
        # Brain Knowledge Graph Tools
        elif name == "brain_list_types":
            result = await _brain_call("get", "/types")
        elif name == "brain_create_type":
            payload: dict[str, Any] = {"name": arguments["name"], "fields": arguments["fields"]}
            if "key_strategy" in arguments:
                payload["key_strategy"] = arguments["key_strategy"]
            if "description" in arguments:
                payload["description"] = arguments["description"]
            result = await _brain_call("post", "/types", json=payload)
        elif name == "brain_update_type":
            type_name = urllib.parse.quote(arguments["name"], safe="")
            result = await _brain_call("put", f"/types/{type_name}", json={"fields": arguments["fields"]})
        elif name == "brain_delete_type":
            type_name = urllib.parse.quote(arguments["name"], safe="")
            result = await _brain_call("delete", f"/types/{type_name}")
        elif name == "brain_create_entity":
            payload = {"entity_type": arguments["entity_type"], "data": arguments["data"]}
            if "commit_msg" in arguments:
                payload["commit_msg"] = arguments["commit_msg"]
            result = await _brain_call("post", "/entities", json=payload)
        elif name == "brain_query_entities":
            entity_type = urllib.parse.quote(arguments["entity_type"], safe="")
            params = {"limit": arguments.get("limit", 100), "offset": arguments.get("offset", 0)}
            result = await _brain_call("get", f"/entities/{entity_type}", params=params)
        elif name == "brain_get_entity":
            result = await _brain_call("get", "/entities/by_id", params={"id": arguments["entity_id"]})
        elif name == "brain_update_entity":
            entity_id = urllib.parse.quote(arguments["entity_id"], safe="")
            payload = {"data": arguments["data"]}
            if "commit_msg" in arguments:
                payload["commit_msg"] = arguments["commit_msg"]
            result = await _brain_call("put", f"/entities/{entity_id}", json=payload)
        elif name == "brain_delete_entity":
            entity_id = urllib.parse.quote(arguments["entity_id"], safe="")
            kwargs: dict[str, Any] = {}
            if "commit_msg" in arguments:
                kwargs["json"] = {"commit_msg": arguments["commit_msg"]}
            result = await _brain_call("delete", f"/entities/{entity_id}", **kwargs)
        elif name == "brain_create_relationship":
            result = await _brain_call("post", "/relationships", json={
                "from_id": arguments["from_id"],
                "relationship": arguments["relationship"],
                "to_id": arguments["to_id"],
            })
        elif name == "brain_traverse_graph":
            result = await _brain_call("post", "/traverse", json={
                "start_id": arguments["start_id"],
                "relationship": arguments["relationship"],
                "max_depth": arguments.get("max_depth", 2),
            })
        elif name == "brain_list_saved_queries":
            result = await _brain_call("get", "/queries")
        elif name == "brain_save_query":
            result = await _brain_call("post", "/queries", json={
                "name": arguments["name"],
                "entity_type": arguments["entity_type"],
                "filters": arguments["filters"],
            })
        elif name == "brain_delete_saved_query":
            query_id = urllib.parse.quote(arguments["query_id"], safe="")
            result = await _brain_call("delete", f"/queries/{query_id}")
        else:
            return json.dumps({"error": f"Unknown tool: {name}"})

        return json.dumps(result, indent=2, default=str)

    except Exception as e:
        logger.error(f"Tool error ({name}): {e}", exc_info=True)
        return json.dumps({"error": str(e)})


async def run_server(vault_path: str):
    """Run the MCP server."""
    global _vault_path, _brain_base_url
    _vault_path = vault_path
    port = os.environ.get("PARACHUTE_SERVER_PORT", "3333")
    _brain_base_url = f"http://localhost:{port}/api/brain"

    logger.info(f"Starting Parachute MCP server with vault: {vault_path}")

    # Create MCP server
    server = Server("parachute")

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        return TOOLS

    @server.call_tool()
    async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
        result = await handle_tool_call(name, arguments)
        return [TextContent(type="text", text=result)]

    # Run with stdio transport
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


def main():
    parser = argparse.ArgumentParser(description="Parachute MCP Server")
    parser.add_argument(
        "vault_path",
        nargs="?",
        default=None,
        help="Path to Parachute vault",
    )
    args = parser.parse_args()

    # Get vault path from args or environment
    vault_path = args.vault_path or os.environ.get("PARACHUTE_VAULT_PATH")

    if not vault_path:
        print("Error: Vault path required (argument or PARACHUTE_VAULT_PATH env)", file=sys.stderr)
        sys.exit(1)

    if not Path(vault_path).exists():
        print(f"Error: Vault path does not exist: {vault_path}", file=sys.stderr)
        sys.exit(1)

    # Initialize session context from env vars
    global _session_context
    _session_context = SessionContext.from_env()

    if _session_context.is_available:
        logger.info(
            f"Session context: session={_session_context.session_id[:8]}, "
            f"workspace={_session_context.workspace_id}, "
            f"trust={_session_context.trust_level}"
        )
    else:
        logger.warning("MCP server started without session context (legacy mode)")

    asyncio.run(run_server(vault_path))


if __name__ == "__main__":
    main()
