"""
MCP tool handlers for the sandbox HTTP bridge.

Registers tools on the MCP Server instance. Read tools are available to all
sandbox sessions. Write tools are gated by the token's allowed_writes list.

Tools access host services via the service registry (BrainService,
BrainChatStore) — no HTTP loopback needed since we're in the same process.

Shared vault tools (search_memory, search_chats, list_chats, list_notes,
get_chat, get_exchange/get_message) are imported from core/vault_tools.py —
same implementations as the direct MCP server.

Bridge-only tools:
- read_brain_entity: Read a brain graph entity by name
- write_card: Write agent output as a card (write-gated)
"""

import json
import logging
import re
from datetime import datetime, timezone
from typing import Any

from mcp.server import Server
from mcp.types import TextContent, Tool
from parachute.core.vault_tools import (
    VAULT_TOOLS,
    search_memory as _search_memory,
    search_chats as _search_chats,
    list_chats as _list_chats,
    list_notes as _list_notes,
    get_chat as _get_chat,
    get_exchange as _get_exchange,
    write_note as _write_note,
)

logger = logging.getLogger(__name__)


# ── Default tool profiles per session type ────────────────────────────────────
# None = all tools visible (backwards-compatible).
# Agents can override via config later (#319).

CHAT_TOOLS = frozenset({
    "search_memory", "search_chats", "list_chats",
    "get_chat", "get_exchange", "list_notes",
})

DAILY_TOOLS = frozenset({
    "read_brain_entity",
    "write_card",
    "search_memory", "list_notes", "get_exchange",
})


def _get_graph():
    """Get BrainService from the service registry."""
    try:
        from parachute.core.interfaces import get_registry
        return get_registry().get("BrainDB")
    except Exception as e:
        logger.warning(f"Failed to get BrainDB from registry: {e}")
        return None


# ── Tool Definitions ──────────────────────────────────────────────────────────

TOOLS = [
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
        name="write_card",
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
                "card_type": {
                    "type": "string",
                    "description": "Type of card (e.g. 'reflection', 'weekly-review'). Defaults to 'default'.",
                },
            },
            "required": ["content", "date"],
        },
    ),
] + VAULT_TOOLS  # Shared vault tools (search_memory, search_chats, list_chats, list_notes, get_chat, get_exchange)

# Validate profiles reference real tool names (catches renames at import time)
_ALL_TOOL_NAMES = frozenset(t.name for t in TOOLS)
assert CHAT_TOOLS <= _ALL_TOOL_NAMES, f"CHAT_TOOLS has unknown tools: {CHAT_TOOLS - _ALL_TOOL_NAMES}"
assert DAILY_TOOLS <= _ALL_TOOL_NAMES, f"DAILY_TOOLS has unknown tools: {DAILY_TOOLS - _ALL_TOOL_NAMES}"


# ── Tool Handlers ─────────────────────────────────────────────────────────────


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


async def _handle_write_card(arguments: dict[str, Any]) -> str:
    """Write agent output as a Card. Requires write permission."""
    from parachute.api.mcp_bridge import get_sandbox_context

    ctx = get_sandbox_context()
    if ctx is None:
        return json.dumps({"error": "No sandbox context available"})

    # Check write permission (accept both old and new name during transition)
    if "write_output" not in ctx.allowed_writes and "write_card" not in ctx.allowed_writes:
        return json.dumps({"error": "write_card not permitted for this session"})

    content = arguments.get("content", "").strip()
    date_str = arguments.get("date", "").strip()
    card_type = arguments.get("card_type", "default").strip() or "default"

    if not content:
        return json.dumps({"error": "Content cannot be empty"})
    if len(content) > 512 * 1024:
        return json.dumps({"error": "Content exceeds maximum size (512 KB)"})
    if not re.fullmatch(r"[a-z0-9][a-z0-9\-]{0,31}", card_type):
        return json.dumps({"error": "Invalid card_type — use lowercase alphanumeric with hyphens, max 32 chars"})
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

    card_id = f"{agent_name}:{card_type}:{date_str}"
    display_name = agent_name.replace("-", " ").title()
    generated_at = datetime.now(timezone.utc).isoformat()

    await graph.execute_cypher(
        "MERGE (c:Card {card_id: $card_id}) "
        "SET c.agent_name = $agent_name, "
        "    c.card_type = $card_type, "
        "    c.display_name = $display_name, "
        "    c.content = $content, "
        "    c.generated_at = $generated_at, "
        "    c.status = 'done', "
        "    c.date = $date, "
        "    c.read_at = ''",
        {
            "card_id": card_id,
            "agent_name": agent_name,
            "card_type": card_type,
            "display_name": display_name,
            "content": content,
            "generated_at": generated_at,
            "date": date_str,
        },
    )

    logger.info(f"Card written: {card_id}")
    return json.dumps({"card_id": card_id, "status": "done", "date": date_str})


# ── Vault Tool Handlers (shared with direct MCP server) ──────────────────────

async def _handle_vault_tool(name: str, arguments: dict[str, Any]) -> str:
    """Handle shared vault tools by routing to vault_tools handlers."""
    graph = _get_graph()
    if graph is None:
        return json.dumps({"error": "BrainDB not available"})

    if name == "search_memory":
        result = await _search_memory(
            graph,
            query=arguments["query"],
            source=arguments.get("source"),
            date_from=arguments.get("date_from"),
            date_to=arguments.get("date_to"),
            limit=arguments.get("limit", 10),
        )
    elif name == "search_chats":
        result = await _search_chats(
            graph,
            query=arguments["query"],
            limit=arguments.get("limit", 10),
            module=arguments.get("module"),
        )
    elif name == "list_chats":
        result = await _list_chats(
            graph,
            module=arguments.get("module"),
            limit=arguments.get("limit", 20),
            archived=arguments.get("archived", False),
            search=arguments.get("search"),
        )
    elif name == "list_notes":
        result = await _list_notes(
            graph,
            date_from=arguments.get("date_from"),
            date_to=arguments.get("date_to"),
            limit=arguments.get("limit", 20),
            note_type=arguments.get("note_type"),
            search=arguments.get("search"),
        )
    elif name == "get_chat":
        result = await _get_chat(
            graph,
            session_id=arguments["session_id"],
            exchange_limit=arguments.get("exchange_limit", 25),
            max_chars=arguments.get("max_chars", 2000),
        )
    elif name == "get_exchange":
        result = await _get_exchange(
            graph,
            exchange_id=arguments["exchange_id"],
        )
    elif name == "write_note":
        result = await _write_note(
            graph,
            note_type=arguments["note_type"],
            title=arguments["title"],
            content=arguments["content"],
            date=arguments.get("date"),
        )
    else:
        return json.dumps({"error": f"Unknown vault tool: {name}"})

    return json.dumps(result, default=str)


# Vault tool names for dispatch
_VAULT_TOOL_NAMES = {"search_memory", "search_chats", "list_chats", "list_notes", "get_chat", "get_exchange", "write_note"}


# ── Handler Dispatch ──────────────────────────────────────────────────────────

_HANDLERS = {
    "read_brain_entity": _handle_read_brain_entity,
    "write_card": _handle_write_card,
}


def register_tools(server: Server) -> None:
    """Register tool list and call handlers on the MCP Server."""

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        from parachute.api.mcp_bridge import get_sandbox_context

        ctx = get_sandbox_context()
        if ctx is None or ctx.allowed_tools is None:
            return TOOLS  # No filtering (direct sessions, or no context)
        return [t for t in TOOLS if t.name in ctx.allowed_tools]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
        # Defense in depth: reject calls to tools not in allowed set
        from parachute.api.mcp_bridge import get_sandbox_context

        ctx = get_sandbox_context()
        if ctx and ctx.allowed_tools is not None and name not in ctx.allowed_tools:
            return [TextContent(
                type="text",
                text=json.dumps({"error": f"Tool not available: {name}"}),
            )]

        if name in _VAULT_TOOL_NAMES:
            try:
                result = await _handle_vault_tool(name, arguments)
            except Exception as e:
                logger.error(f"MCP tool error ({name}): {e}", exc_info=True)
                result = json.dumps({"error": f"Internal error processing {name}"})
        else:
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
