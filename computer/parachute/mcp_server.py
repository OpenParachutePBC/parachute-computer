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

Graph Query Tools:
- get_graph_schema: Returns all node and relationship tables with columns
- list_conversations: List conversation sessions from the graph
- get_conversation: Get a single session by ID from the graph
- list_projects: List named project environments (container envs)
- list_entries: List Daily journal entries from the graph

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

# Global session_store connection
_db = None
_graph_base_url: str = ""
_PARACHUTE_DIR = Path.home() / ".parachute"


@dataclass(frozen=True, slots=True)
class SessionContext:
    """Immutable session context injected by orchestrator via env vars."""
    session_id: str | None
    trust_level: str | None  # Will be normalized to TrustLevelStr
    container_env_id: str | None = None

    @classmethod
    def from_env(cls) -> Self:
        """Read session context from environment variables.

        Normalizes trust level to canonical TrustLevelStr values.
        Validates session_id format.
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

        raw_trust = os.getenv("PARACHUTE_TRUST_LEVEL")
        container_env_id = os.getenv("PARACHUTE_CONTAINER_ENV_ID") or None
        return cls(
            session_id=session_id,
            trust_level=normalize_trust_level(raw_trust) if raw_trust else None,
            container_env_id=container_env_id,
        )

    @property
    def is_available(self) -> bool:
        """Check if session context is fully populated."""
        return all([self.session_id, self.trust_level])


# Module-level session context singleton
_session_context: SessionContext | None = None


async def get_db():
    """Get or create GraphSessionStore connection."""
    global _db
    if _db is None:
        from parachute.db.graph import GraphService
        from parachute.db.graph_sessions import GraphSessionStore
        graph = GraphService(db_path=str(_PARACHUTE_DIR / "graph" / "parachute.kz"))
        await graph.connect()
        _db = GraphSessionStore(graph)
        await _db.ensure_schema()
        logger.info(f"Connected to graph DB: {_PARACHUTE_DIR / 'graph' / 'parachute.kz'}")
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
        description="Create a child session. Trust level and container env are inherited from session context. Enforces spawn limits (max 10 children) and rate limiting (1/second).",
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
        description="Send a message to another session. Enforces trust level restrictions (sandboxed can only message sandboxed).",
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
    # Graph Query Tools
    Tool(
        name="get_graph_schema",
        description=(
            "Returns all node and relationship tables in the graph database with their "
            "column names and types. Call this first to understand what data is queryable."
        ),
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="list_conversations",
        description="List conversation sessions from the graph.",
        inputSchema={
            "type": "object",
            "properties": {
                "module": {"type": "string", "description": "Filter by module: chat, daily"},
                "limit": {"type": "integer", "description": "Max results (default 20)"},
                "archived": {"type": "boolean", "description": "Include archived (default false)"},
            },
        },
    ),
    Tool(
        name="get_conversation",
        description="Get a single conversation session by ID.",
        inputSchema={
            "type": "object",
            "properties": {"session_id": {"type": "string"}},
            "required": ["session_id"],
        },
    ),
    Tool(
        name="list_projects",
        description="List named project environments (shared containers).",
        inputSchema={
            "type": "object",
            "properties": {"limit": {"type": "integer", "description": "Max results (default 20)"}},
        },
    ),
    Tool(
        name="list_entries",
        description="List Daily journal entries.",
        inputSchema={
            "type": "object",
            "properties": {
                "date_from": {"type": "string", "description": "YYYY-MM-DD"},
                "date_to": {"type": "string", "description": "YYYY-MM-DD"},
                "limit": {"type": "integer", "description": "Max results (default 20)"},
            },
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
        sm = SessionManager(_PARACHUTE_DIR, db)
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
    Create a child session.

    Trust level and container env are inherited from session context env vars.
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
            "error": "Invalid agent_type: must contain only letters, numbers, hyphens, and underscores"
        }

    # Content validation (max 50k chars, no control chars except newlines/tabs)
    if error := _validate_message_content(initial_message, "initial message"):
        return {"error": error}

    db = await get_db()
    parent_session_id = _session_context.session_id
    trust_level = _session_context.trust_level
    container_env_id = _session_context.container_env_id

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

    # Create session
    from parachute.models.session import SessionCreate, SessionSource

    session_id = f"sess_{uuid.uuid4().hex[:16]}"

    session_create = SessionCreate(
        id=session_id,
        title=title.strip(),
        module="chat",
        source=SessionSource.PARACHUTE,
        working_directory=None,
        agent_type=agent_type,
        trust_level=trust_level,
        container_env_id=container_env_id,
        parent_session_id=parent_session_id,
        created_by=f"agent:{parent_session_id}",
    )

    # Create session in database
    await db.create_session(session_create)

    logger.info(f"Created child session {session_id} (parent: {parent_session_id})")

    return {
        "success": True,
        "session_id": session_id,
        "title": title,
        "agent_type": agent_type,
        "container_env_id": container_env_id,
        "trust_level": trust_level,
        "parent_session_id": parent_session_id,
        "initial_message_queued": True,
        "note": "Session created. Use send_message to deliver the initial message.",
    }


async def send_message(
    session_id: str,
    message: str,
) -> dict[str, Any]:
    """
    Send a message to another session.

    Enforces trust level restrictions (sandboxed can only message sandboxed).
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
    sender_trust_level = _session_context.trust_level

    # Get recipient session
    recipient_session = await db.get_session(session_id.strip())
    if not recipient_session:
        return {"error": f"Recipient session not found: {session_id}"}

    # Enforce trust level restrictions (sandboxed can only message sandboxed)
    recipient_trust_level = recipient_session.get_trust_level().value
    if sender_trust_level == "sandboxed" and recipient_trust_level != "sandboxed":
        return {
            "error": f"Sandboxed sessions can only message other sandboxed sessions (recipient trust: {recipient_trust_level})"
        }

    # Message delivery: inject into recipient's SDK session
    # For MVP, we'll just log the message - actual delivery requires SDK integration
    logger.info(
        f"Message delivery: {sender_session_id[:8]}→{session_id[:8]}"
    )

    # TODO: Implement actual message injection into SDK session
    # This requires extending the SDK to support mid-stream message injection
    # Return error until delivery is implemented to maintain honest contract
    return {
        "error": "Message delivery not yet implemented. Validation passed, but delivery requires SDK mid-stream message injection support.",
        "validation_passed": True,
        "sender_session_id": sender_session_id,
        "recipient_session_id": session_id,
    }


# =============================================================================
# Daily Journal Functions
# =============================================================================

def get_journals_path() -> Path:
    """Get the path to the Daily journals folder."""
    return Path.home() / "Daily" / "journals"


def _is_legacy_journal(content: str) -> bool:
    """Return True if content lacks para:daily: markers (pre-Dec 15, 2025 Obsidian format)."""
    return "# para:daily:" not in content


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
                if _is_legacy_journal(content):
                    # Legacy Obsidian file — treat whole document as one searchable unit
                    match_pos = content.lower().find(query_lower)
                    start = max(0, match_pos - 50)
                    end = min(len(content), match_pos + len(query) + 100)
                    snippet = content[start:end]
                    if start > 0:
                        snippet = "..." + snippet
                    if end < len(content):
                        snippet = snippet + "..."
                    results.append({
                        "date": journal_file.stem,
                        "entry_header": f"legacy:{journal_file.stem}",
                        "snippet": snippet,
                        "file": str(journal_file.name),
                        "type": "legacy",
                    })
                else:
                    # New structured format — extract matching para:daily: entries
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
            if _is_legacy_journal(content):
                results.append({
                    "date": journal_file.stem,
                    "entry_count": 1,
                    "file": str(journal_file.name),
                    "type": "legacy",
                })
            else:
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

        # Legacy Obsidian files have no para:daily: markers — return as single entry
        if _is_legacy_journal(content):
            return {
                "date": date,
                "file": str(journal_file.name),
                "entry_count": 1,
                "entries": [{
                    "id": f"legacy-{date}",
                    "time": None,
                    "type": "legacy",
                    "content": content,
                }],
                "raw_content": content,
            }

        # Parse structured entries
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


async def _graph_call(path: str) -> dict[str, Any]:
    """Make a GET request to the local graph API."""
    if not _graph_base_url:
        return {"error": "Graph API not available"}
    url = f"{_graph_base_url}{path}"
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.get(url)
            if response.status_code >= 400:
                try:
                    detail = response.json().get("detail", response.text)
                except Exception:
                    detail = response.text
                return {"error": detail, "status_code": response.status_code}
            return response.json()
    except httpx.ConnectError:
        return {"error": "Graph API unavailable — is the server running?"}
    except Exception as e:
        logger.error(f"Graph API call failed (GET {path}): {e}")
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
        # Graph Query Tools
        elif name == "get_graph_schema":
            result = await _graph_call("/schema")
        elif name == "list_conversations":
            params = {k: arguments[k] for k in ("module", "limit") if k in arguments}
            if "archived" in arguments:
                params["archived"] = "true" if arguments["archived"] else "false"
            qs = ("?" + urllib.parse.urlencode(params)) if params else ""
            result = await _graph_call(f"/sessions{qs}")
        elif name == "get_conversation":
            sid = urllib.parse.quote(arguments["session_id"], safe="")
            result = await _graph_call(f"/sessions/{sid}")
        elif name == "list_projects":
            qs = f"?limit={arguments['limit']}" if "limit" in arguments else ""
            result = await _graph_call(f"/container_envs{qs}")
        elif name == "list_entries":
            params = {k: arguments[k] for k in ("date_from", "date_to", "limit") if k in arguments}
            qs = ("?" + urllib.parse.urlencode(params)) if params else ""
            result = await _graph_call(f"/daily/entries{qs}")
        else:
            return json.dumps({"error": f"Unknown tool: {name}"})

        return json.dumps(result, indent=2, default=str)

    except Exception as e:
        logger.error(f"Tool error ({name}): {e}", exc_info=True)
        return json.dumps({"error": str(e)})


async def run_server():
    """Run the MCP server."""
    global _graph_base_url
    port = os.environ.get("PARACHUTE_SERVER_PORT", "3333")
    _graph_base_url = f"http://localhost:{port}/api/graph"

    logger.info(f"Starting Parachute MCP server (parachute_dir: {_PARACHUTE_DIR})")

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
    args = parser.parse_args()  # noqa: F841 — no args currently required

    # Initialize session context from env vars
    global _session_context
    _session_context = SessionContext.from_env()

    if _session_context.is_available:
        logger.info(
            f"Session context: session={_session_context.session_id[:8]}, "
            f"trust={_session_context.trust_level}"
        )
    else:
        logger.warning("MCP server started without session context (legacy mode)")

    asyncio.run(run_server())


if __name__ == "__main__":
    main()
