#!/usr/bin/env python3
"""
Parachute MCP Server

Provides memory search and brain graph access via Model Context Protocol.
All tools route through the brain HTTP API — no direct DB access.

Memory Search:
- search_memory: Unified search across Chat sessions, exchanges, and journal Notes

Brain Tools:
- brain_schema: Returns all node and relationship tables in the brain (Kuzu graph)
- brain_list_chats: List conversation sessions from the brain
- brain_get_chat: Get a single session by ID with its exchanges (truncated, paginated)
- brain_get_exchange: Get a single exchange by ID with full message content
- brain_list_projects: List named project environments (container envs)
- brain_list_notes: List Daily journal Notes from the brain
- brain_query: Execute a read-only Cypher query (power users / debugging)
- brain_execute: Execute a write Cypher query against the brain

Tag Tools (read from sessions.db via HTTP API):
- search_by_tag / list_tags / add_session_tag / remove_session_tag

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
from typing import Any, Self

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent
from parachute.core.chat_memory import CHAT_MEMORY_TOOLS

# Configure logging to stderr (stdout is for MCP protocol)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("ParachuteMCP")

# Global session_store connection
_db = None
_brain_base_url: str = ""
_PARACHUTE_DIR = Path.home() / ".parachute"


@dataclass(frozen=True, slots=True)
class SessionContext:
    """Immutable session context injected by orchestrator via env vars."""
    session_id: str | None
    trust_level: str | None  # Will be normalized to TrustLevelStr
    project_id: str | None = None

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
        project_id = os.getenv("PARACHUTE_PROJECT_ID") or None
        return cls(
            session_id=session_id,
            trust_level=normalize_trust_level(raw_trust) if raw_trust else None,
            project_id=project_id,
        )

    @property
    def is_available(self) -> bool:
        """Check if session context is fully populated."""
        return all([self.session_id, self.trust_level])


# Module-level session context singleton
_session_context: SessionContext | None = None


async def get_db():
    """Get or create BrainSessionStore connection."""
    global _db
    if _db is None:
        from parachute.db.brain import BrainService
        from parachute.db.brain_sessions import BrainSessionStore
        brain = BrainService(db_path=_PARACHUTE_DIR / "graph" / "parachute.kz")
        await brain.connect()
        _db = BrainSessionStore(brain)
        await _db.ensure_schema()
        logger.info(f"Connected to brain DB: {_PARACHUTE_DIR / 'graph' / 'parachute.kz'}")
    return _db


def _validate_message_content(
    content: str,
    field_name: str = "message",
    max_length: int = 50_000
) -> str | None:
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
    # Memory Search Tool
    Tool(
        name="search_memory",
        description=(
            "Search all memory — chat sessions, conversation exchanges, and journal entries — by keyword. "
            "Returns ranked results with summaries and matched snippets. "
            "Sessions matched via exchange content include matched_exchange_id for follow-up with brain_get_exchange. "
            "By default searches everything; use 'source' to narrow to 'journal' or 'chat'. "
            "Use date_from/date_to (YYYY-MM-DD) to scope journal results by date."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Keyword or phrase to search across all memory",
                },
                "source": {
                    "type": "string",
                    "description": "Optional: 'journal' to search only journal entries, 'chat' for sessions only",
                },
                "date_from": {
                    "type": "string",
                    "description": "Optional: YYYY-MM-DD — scope journal results from this date",
                },
                "date_to": {
                    "type": "string",
                    "description": "Optional: YYYY-MM-DD — scope journal results to this date",
                },
                "limit": {
                    "type": "number",
                    "description": "Maximum number of results (default: 10)",
                    "default": 10,
                },
            },
            "required": ["query"],
        },
    ),
    # Brain Tools
    Tool(
        name="brain_schema",
        description=(
            "Returns all node and relationship tables in the Parachute brain (Kuzu graph) "
            "with their column names and types. Call this first to understand what memory is queryable."
        ),
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="brain_list_chats",
        description="List recent chat conversations from the brain graph. Use when browsing recent activity rather than searching for something specific.",
        inputSchema={
            "type": "object",
            "properties": {
                "module": {"type": "string", "description": "Filter by module: chat, daily"},
                "limit": {"type": "integer", "description": "Max results (default 20)"},
                "archived": {"type": "boolean", "description": "Include archived (default false)"},
                "search": {"type": "string", "description": "Optional: filter by title or summary keyword"},
            },
        },
    ),
    Tool(
        name="brain_get_chat",
        description=(
            "Get a specific chat session by ID with its exchanges. "
            "Exchanges include description, user_message (truncated), and ai_response (truncated). "
            "For full content of a specific exchange, use brain_get_exchange. "
            "Use exchange_limit to control how many exchanges are returned (default 25, most recent)."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "session_id": {"type": "string", "description": "The session ID to retrieve"},
                "exchange_limit": {"type": "integer", "description": "Max exchanges to return (default 25)"},
                "max_chars": {"type": "integer", "description": "Max chars per message field before truncation (default 2000)"},
            },
            "required": ["session_id"],
        },
    ),
    Tool(
        name="brain_get_exchange",
        description=(
            "Get a single exchange by ID with full message content (user message + AI response, untruncated). "
            "Use after search_memory or brain_get_chat identifies a specific exchange of interest. "
            "The exchange ID is available as matched_exchange_id in search_memory results."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "exchange_id": {"type": "string", "description": "Exchange ID (e.g. session_id:ex:N)"},
            },
            "required": ["exchange_id"],
        },
    ),
    Tool(
        name="brain_list_projects",
        description="List named project environments (shared containers).",
        inputSchema={
            "type": "object",
            "properties": {"limit": {"type": "integer", "description": "Max results (default 20)"}},
        },
    ),
    Tool(
        name="brain_list_notes",
        description="List notes and journal entries from the brain graph. Use date_from/date_to to scope by date. Use note_type='journal' for Daily journal entries.",
        inputSchema={
            "type": "object",
            "properties": {
                "date_from": {"type": "string", "description": "YYYY-MM-DD"},
                "date_to": {"type": "string", "description": "YYYY-MM-DD"},
                "limit": {"type": "integer", "description": "Max results (default 20)"},
                "note_type": {"type": "string", "description": "Filter by note_type (e.g. 'journal')"},
                "search": {"type": "string", "description": "Optional: filter by content keyword"},
            },
        },
    ),
    Tool(
        name="brain_query",
        description=(
            "Execute a read-only Cypher query against the Parachute brain (Kuzu graph). "
            "For power users and debugging. Prefer search_memory, brain_list_chats, brain_list_notes, "
            "and brain_get_chat for common use cases. "
            "Call brain_schema first to discover available tables and columns."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Cypher MATCH/RETURN query"},
                "params": {"type": "object", "description": "Optional $param bindings"},
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="brain_execute",
        description=(
            "Execute a write Cypher query against the Parachute brain (Kuzu graph). "
            "Use for MERGE, CREATE, SET, DELETE. Use brain_query for reads."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Cypher write query"},
                "params": {"type": "object", "description": "Optional $param bindings"},
            },
            "required": ["query"],
        },
    ),
] + CHAT_MEMORY_TOOLS  # Chat memory tools (search_chats, get_chat, get_exchange)


async def get_session(
    session_id: str,
    include_messages: bool = True,
) -> dict[str, Any] | None:
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
    project_id = _session_context.project_id

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
        project_id=project_id,
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
        "project_id": project_id,
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



async def _brain_call(
    path: str,
    method: str = "GET",
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Make a GET or POST request to the local brain API."""
    if not _brain_base_url:
        return {"error": "Brain API not available"}
    url = f"{_brain_base_url}{path}"
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            if method == "POST":
                response = await client.post(url, json=body or {})
            else:
                response = await client.get(url)
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
        if name == "search_memory":
            params: dict[str, Any] = {"search": arguments["query"]}
            if arguments.get("source") == "journal":
                params["type"] = "notes"
                params["note_type"] = "journal"
            elif arguments.get("source") == "chat":
                params["type"] = "sessions"
            if arguments.get("date_from"):
                params["date_from"] = arguments["date_from"]
            if arguments.get("date_to"):
                params["date_to"] = arguments["date_to"]
            params["limit"] = arguments.get("limit", 10)
            qs = "?" + urllib.parse.urlencode(params)
            result = await _brain_call(f"/memory{qs}")
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
        # Brain Tools
        elif name == "brain_schema":
            result = await _brain_call("/schema")
        elif name == "brain_list_chats":
            bp: dict[str, Any] = {k: arguments[k] for k in ("module", "limit", "search") if k in arguments}
            if "archived" in arguments:
                bp["archived"] = "true" if arguments["archived"] else "false"
            qs = ("?" + urllib.parse.urlencode(bp)) if bp else ""
            result = await _brain_call(f"/sessions{qs}")
        elif name == "brain_get_chat":
            sid = urllib.parse.quote(arguments["session_id"], safe="")
            gp: dict[str, Any] = {}
            if "exchange_limit" in arguments:
                gp["exchange_limit"] = arguments["exchange_limit"]
            if "max_chars" in arguments:
                gp["max_chars"] = arguments["max_chars"]
            qs = ("?" + urllib.parse.urlencode(gp)) if gp else ""
            result = await _brain_call(f"/sessions/{sid}{qs}")
        elif name == "brain_get_exchange":
            eid = urllib.parse.quote(arguments["exchange_id"], safe="")
            result = await _brain_call(f"/exchanges?id={eid}")
        elif name == "brain_list_projects":
            qs = f"?limit={arguments['limit']}" if "limit" in arguments else ""
            result = await _brain_call(f"/projects{qs}")
        elif name == "brain_list_notes":
            np: dict[str, Any] = {k: arguments[k] for k in ("date_from", "date_to", "limit", "note_type", "search") if k in arguments}
            qs = ("?" + urllib.parse.urlencode(np)) if np else ""
            result = await _brain_call(f"/daily/entries{qs}")
        elif name == "brain_query":
            # Require vault/direct trust — raw Cypher reads all journal data.
            # Fail-closed: deny if context is absent (standalone/legacy mode).
            trust = _session_context.trust_level if _session_context else None
            if trust != "direct":
                result = {"error": "brain_query requires vault or full trust level"}
            else:
                result = await _brain_call(
                    "/query",
                    method="POST",
                    body={"query": arguments["query"], "params": arguments.get("params")},
                )
        elif name == "brain_execute":
            # Require full (direct) trust — arbitrary writes can corrupt or destroy the graph.
            # Fail-closed: deny if context is absent (standalone/legacy mode).
            trust = _session_context.trust_level if _session_context else None
            if trust != "direct":
                result = {"error": "brain_execute requires full trust level"}
            else:
                result = await _brain_call(
                    "/execute",
                    method="POST",
                    body={"query": arguments["query"], "params": arguments.get("params")},
                )
        # Chat Memory Tools (shared handlers)
        elif name == "search_chats":
            from parachute.core.chat_memory import search_chats as _search_chats
            db = await get_db()
            result = await _search_chats(
                db.graph,
                query=arguments["query"],
                limit=arguments.get("limit", 10),
                module=arguments.get("module"),
            )
        elif name == "get_chat":
            from parachute.core.chat_memory import get_chat as _get_chat
            db = await get_db()
            result = await _get_chat(
                db.graph,
                session_id=arguments["session_id"],
                exchange_limit=arguments.get("exchange_limit", 25),
                max_chars=arguments.get("max_chars", 2000),
            )
        elif name == "get_exchange":
            from parachute.core.chat_memory import get_exchange as _get_exchange
            db = await get_db()
            result = await _get_exchange(
                db.graph,
                exchange_id=arguments["exchange_id"],
            )
        else:
            return json.dumps({"error": f"Unknown tool: {name}"})

        return json.dumps(result, indent=2, default=str)

    except Exception as e:
        logger.error(f"Tool error ({name}): {e}", exc_info=True)
        return json.dumps({"error": str(e)})


async def run_server():
    """Run the MCP server."""
    global _brain_base_url
    port = os.environ.get("PARACHUTE_SERVER_PORT", "3333")
    _brain_base_url = f"http://localhost:{port}/api/brain"

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
