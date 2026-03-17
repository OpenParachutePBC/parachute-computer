"""
MCP tool handlers for the sandbox HTTP bridge.

Registers tools on the MCP Server instance. Read tools are available to all
sandbox sessions. Write tools are gated by the token's allowed_writes list.

Tools access host services via the service registry (BrainService,
BrainChatStore) — no HTTP loopback needed since we're in the same process.
"""

import json
import logging
import re
from datetime import datetime, timedelta, timezone
from typing import Any

from mcp.server import Server
from mcp.types import TextContent, Tool
from parachute.core.chat_memory import (
    CHAT_MEMORY_TOOLS,
    search_chats as _search_chats,
    get_chat as _get_chat,
    get_exchange as _get_exchange,
)

logger = logging.getLogger(__name__)


def _get_graph():
    """Get BrainService from the service registry."""
    try:
        from parachute.core.interfaces import get_registry
        return get_registry().get("BrainDB")
    except Exception as e:
        logger.warning(f"Failed to get BrainDB from registry: {e}")
        return None


def _get_chat_store():
    """Get BrainChatStore from the service registry."""
    try:
        from parachute.core.interfaces import get_registry
        return get_registry().get("ChatStore")
    except Exception as e:
        logger.warning(f"Failed to get ChatStore from registry: {e}")
        return None


# ── Tool Definitions ──────────────────────────────────────────────────────────

TOOLS = [
    Tool(
        name="read_journal",
        description="Read journal entries for a specific date.",
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
    Tool(
        name="read_recent_journals",
        description="Read recent journal entries from the last N days.",
        inputSchema={
            "type": "object",
            "properties": {
                "days": {
                    "type": "integer",
                    "description": "Number of days to look back (default: 7)",
                    "default": 7,
                },
            },
        },
    ),
    Tool(
        name="search_memory",
        description=(
            "Search across all memory — journal entries, chat sessions, and exchanges. "
            "Returns ranked results with snippets."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query (keyword or phrase)",
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum results to return (default: 10)",
                    "default": 10,
                },
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="list_recent_sessions",
        description="List recent chat sessions.",
        inputSchema={
            "type": "object",
            "properties": {
                "limit": {
                    "type": "integer",
                    "description": "Maximum sessions to return (default: 20)",
                    "default": 20,
                },
            },
        },
    ),
    Tool(
        name="read_brain_entity",
        description="Read a brain graph entity by name.",
        inputSchema={
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Entity name (primary key in the brain graph)",
                },
            },
            "required": ["name"],
        },
    ),
    Tool(
        name="write_output",
        description=(
            "Write agent output as a card. Used by agents to save their "
            "reflection or analysis results."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "content": {
                    "type": "string",
                    "description": "The output content (markdown supported)",
                },
                "date": {
                    "type": "string",
                    "description": "Date for the card in YYYY-MM-DD format",
                },
            },
            "required": ["content", "date"],
        },
    ),
] + CHAT_MEMORY_TOOLS  # Chat memory tools (search_chats, get_chat, get_exchange)


# ── Tool Handlers ─────────────────────────────────────────────────────────────


async def _handle_read_journal(arguments: dict[str, Any]) -> str:
    """Read journal entries for a specific date."""
    date = arguments.get("date", "")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        return json.dumps({"error": "Invalid date format. Use YYYY-MM-DD"})

    graph = _get_graph()
    if graph is None:
        return json.dumps({"error": "BrainDB not available"})

    rows = await graph.execute_cypher(
        "MATCH (e:Note) WHERE e.date = $date "
        "RETURN e ORDER BY e.created_at ASC",
        {"date": date},
    )

    entries = []
    for row in rows:
        entries.append({
            "entry_id": row.get("entry_id", ""),
            "date": row.get("date", ""),
            "content": row.get("content", ""),
            "title": row.get("title", ""),
            "entry_type": row.get("entry_type", "text"),
            "created_at": row.get("created_at", ""),
        })

    return json.dumps({"entries": entries, "count": len(entries), "date": date}, default=str)


async def _handle_read_recent_journals(arguments: dict[str, Any]) -> str:
    """Read recent journal entries from the last N days."""
    days = arguments.get("days", 7)
    days = max(1, min(days, 90))  # Clamp to 1-90

    # Calculate date range
    today = datetime.now(timezone.utc).date()
    start_date = (today - timedelta(days=days - 1)).isoformat()

    graph = _get_graph()
    if graph is None:
        return json.dumps({"error": "BrainDB not available"})

    rows = await graph.execute_cypher(
        "MATCH (e:Note) WHERE e.date >= $start_date "
        "RETURN e ORDER BY e.date DESC, e.created_at DESC",
        {"start_date": start_date},
    )

    entries = []
    for row in rows:
        entries.append({
            "entry_id": row.get("entry_id", ""),
            "date": row.get("date", ""),
            "content": row.get("content", ""),
            "title": row.get("title", ""),
            "entry_type": row.get("entry_type", "text"),
            "created_at": row.get("created_at", ""),
        })

    return json.dumps(
        {"entries": entries, "count": len(entries), "days": days, "from_date": start_date},
        default=str,
    )


async def _handle_search_memory(arguments: dict[str, Any]) -> str:
    """Search across all memory — journals, sessions, exchanges."""
    query = arguments.get("query", "").strip()
    if not query:
        return json.dumps({"error": "Query cannot be empty"})

    limit = min(arguments.get("limit", 10), 50)

    graph = _get_graph()
    if graph is None:
        return json.dumps({"error": "BrainDB not available"})

    results: list[dict] = []

    # Search journal entries (Note nodes)
    note_rows = await graph.execute_cypher(
        "MATCH (e:Note) WHERE e.content CONTAINS $query "
        "RETURN e ORDER BY e.date DESC LIMIT $limit",
        {"query": query, "limit": limit},
    )
    for row in note_rows:
        content = row.get("content", "")
        # Extract snippet around the match (CONTAINS is case-sensitive)
        idx = content.find(query)
        if idx == -1:
            idx = 0  # Fallback: show beginning if exact match not found
        start = max(0, idx - 100)
        end = min(len(content), idx + len(query) + 100)
        snippet = ("..." if start > 0 else "") + content[start:end] + ("..." if end < len(content) else "")

        results.append({
            "type": "journal",
            "id": row.get("entry_id", ""),
            "date": row.get("date", ""),
            "title": row.get("title", ""),
            "snippet": snippet,
        })

    # Search chat sessions (Chat nodes- title + summary)
    session_rows = await graph.execute_cypher(
        "MATCH (s:Chat) WHERE "
        "(s.title CONTAINS $query OR (s.summary IS NOT NULL AND s.summary CONTAINS $query)) "
        "AND (s.archived IS NULL OR s.archived = false) "
        "RETURN s ORDER BY s.last_accessed DESC LIMIT $limit",
        {"query": query, "limit": limit},
    )
    for row in session_rows:
        summary = row.get("summary") or row.get("title") or ""
        results.append({
            "type": "session",
            "id": row.get("session_id", ""),
            "title": row.get("title", ""),
            "snippet": summary[:200],
            "module": row.get("module", "chat"),
        })

    return json.dumps({"results": results, "count": len(results), "query": query}, default=str)


async def _handle_list_recent_chats(arguments: dict[str, Any]) -> str:
    """List recent chats."""
    limit = min(arguments.get("limit", 20), 100)

    session_store = _get_chat_store()
    if session_store is None:
        return json.dumps({"error": "ChatStore not available"})

    sessions = await session_store.list_sessions(limit=limit)

    items = []
    for s in sessions:
        items.append({
            "session_id": s.session_id,
            "title": s.title or "Untitled",
            "module": s.module or "chat",
            "created_at": s.created_at.isoformat() if s.created_at else "",
            "last_accessed": s.last_accessed.isoformat() if s.last_accessed else "",
            "message_count": s.message_count or 0,
        })

    return json.dumps({"sessions": items, "count": len(items)}, default=str)


async def _handle_read_brain_entity(arguments: dict[str, Any]) -> str:
    """Read a brain graph entity by name."""
    name = arguments.get("name", "").strip()
    if not name:
        return json.dumps({"error": "Entity name cannot be empty"})

    graph = _get_graph()
    if graph is None:
        return json.dumps({"error": "BrainDB not available"})

    rows = await graph.execute_cypher(
        "MATCH (e:Brain_Entity {name: $name}) RETURN e",
        {"name": name},
    )

    if not rows:
        return json.dumps({"error": f"Entity not found: {name}"})

    entity = rows[0]
    return json.dumps(entity, default=str)


async def _handle_write_output(arguments: dict[str, Any]) -> str:
    """Write agent output as a Card. Requires write permission."""
    from parachute.api.mcp_bridge import get_sandbox_context

    ctx = get_sandbox_context()
    if ctx is None:
        return json.dumps({"error": "No sandbox context available"})

    # Check write permission
    if "write_output" not in ctx.allowed_writes:
        return json.dumps({"error": "write_output not permitted for this session"})

    content = arguments.get("content", "").strip()
    date_str = arguments.get("date", "").strip()

    if not content:
        return json.dumps({"error": "Content cannot be empty"})
    if len(content) > 512 * 1024:
        return json.dumps({"error": "Content exceeds maximum size (512 KB)"})
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date_str):
        return json.dumps({"error": "Invalid date format. Use YYYY-MM-DD"})

    agent_name = ctx.agent_name
    if not agent_name:
        return json.dumps({"error": "No agent_name in token context"})

    graph = _get_graph()
    if graph is None:
        return json.dumps({"error": "BrainDB not available"})

    # Verify agent exists
    agent_rows = await graph.execute_cypher(
        "MATCH (a:Agent {name: $name}) RETURN a.name",
        {"name": agent_name},
    )
    if not agent_rows:
        return json.dumps({"error": f"Unknown agent: {agent_name}"})

    card_id = f"{agent_name}:{date_str}"
    display_name = agent_name.replace("-", " ").title()
    generated_at = datetime.now(timezone.utc).isoformat()

    await graph.execute_cypher(
        "MERGE (c:Card {card_id: $card_id}) "
        "SET c.agent_name = $agent_name, "
        "    c.display_name = $display_name, "
        "    c.content = $content, "
        "    c.generated_at = $generated_at, "
        "    c.status = 'done', "
        "    c.date = $date",
        {
            "card_id": card_id,
            "agent_name": agent_name,
            "display_name": display_name,
            "content": content,
            "generated_at": generated_at,
            "date": date_str,
        },
    )

    logger.info(f"Card written: {card_id}")
    return json.dumps({"card_id": card_id, "status": "done", "date": date_str})


# ── Chat Memory Handlers (shared with direct MCP server) ─────────────────────


async def _handle_search_chats(arguments: dict[str, Any]) -> str:
    """Search across all chats with bundled exchange results."""
    graph = _get_graph()
    if graph is None:
        return json.dumps({"error": "BrainDB not available"})

    result = await _search_chats(
        graph,
        query=arguments["query"],
        limit=arguments.get("limit", 10),
        module=arguments.get("module"),
    )
    return json.dumps(result, default=str)


async def _handle_get_chat(arguments: dict[str, Any]) -> str:
    """Browse a specific chat with paginated exchanges."""
    graph = _get_graph()
    if graph is None:
        return json.dumps({"error": "BrainDB not available"})

    result = await _get_chat(
        graph,
        session_id=arguments["session_id"],
        exchange_limit=arguments.get("exchange_limit", 25),
        max_chars=arguments.get("max_chars", 2000),
    )
    return json.dumps(result, default=str)


async def _handle_get_exchange(arguments: dict[str, Any]) -> str:
    """Get a single exchange with full untruncated content."""
    graph = _get_graph()
    if graph is None:
        return json.dumps({"error": "BrainDB not available"})

    result = await _get_exchange(
        graph,
        exchange_id=arguments["exchange_id"],
    )
    return json.dumps(result, default=str)


# ── Handler Dispatch ──────────────────────────────────────────────────────────

_HANDLERS = {
    "read_journal": _handle_read_journal,
    "read_recent_journals": _handle_read_recent_journals,
    "search_memory": _handle_search_memory,
    "list_recent_sessions": _handle_list_recent_chats,
    "read_brain_entity": _handle_read_brain_entity,
    "write_output": _handle_write_output,
    # Chat memory (shared handlers)
    "search_chats": _handle_search_chats,
    "get_chat": _handle_get_chat,
    "get_exchange": _handle_get_exchange,
}


def register_tools(server: Server) -> None:
    """Register tool list and call handlers on the MCP Server."""

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        return TOOLS

    @server.call_tool()
    async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
        handler = _HANDLERS.get(name)
        if handler is None:
            result = json.dumps({"error": f"Unknown tool: {name}"})
        else:
            try:
                result = await handler(arguments)
            except Exception as e:
                logger.error(f"MCP tool error ({name}): {e}", exc_info=True)
                result = json.dumps({"error": f"Internal error processing {name}"})

        return [TextContent(type="text", text=result)]
