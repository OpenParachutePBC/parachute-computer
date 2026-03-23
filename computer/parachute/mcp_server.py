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
- brain_list_containers: List container environments
- brain_list_notes: List Daily journal Notes from the brain
- brain_query: Execute a read-only Cypher query (power users / debugging)
- brain_execute: Execute a write Cypher query against the brain

Session & Tag Tools (via HTTP API):
- get_session / search_by_tag / list_tags / add_session_tag / remove_session_tag
- create_session (child sessions with spawn limits)

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

import httpx
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Self

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent
from parachute.core.vault_tools import VAULT_TOOLS

# Configure logging to stderr (stdout is for MCP protocol)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("ParachuteMCP")

_brain_base_url: str = ""
_api_base_url: str = ""
_PARACHUTE_DIR = Path.home() / ".parachute"


@dataclass(frozen=True, slots=True)
class SessionContext:
    """Immutable session context injected by orchestrator via env vars."""
    session_id: str | None
    trust_level: str | None  # Will be normalized to TrustLevelStr
    container_id: str | None = None

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
        container_id = os.getenv("PARACHUTE_CONTAINER_ID") or None
        return cls(
            session_id=session_id,
            trust_level=normalize_trust_level(raw_trust) if raw_trust else None,
            container_id=container_id,
        )

    @property
    def is_available(self) -> bool:
        """Check if session context is fully populated."""
        return all([self.session_id, self.trust_level])


# Module-level session context singleton
_session_context: SessionContext | None = None




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
    # Brain Tools (direct MCP only — not in vault_tools shared set)
    Tool(
        name="brain_schema",
        description=(
            "Returns all node and relationship tables in the Parachute brain (Kuzu graph) "
            "with their column names and types. Call this first to understand what memory is queryable."
        ),
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="brain_list_containers",
        description="List container environments.",
        inputSchema={
            "type": "object",
            "properties": {"limit": {"type": "integer", "description": "Max results (default 20)"}},
        },
    ),
    Tool(
        name="brain_query",
        description=(
            "Execute a read-only Cypher query against the Parachute brain (Kuzu graph). "
            "For power users and debugging. Prefer search_memory, list_chats, list_notes, "
            "and get_chat for common use cases. "
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
] + VAULT_TOOLS  # Shared vault tools (search_memory, search_chats, list_chats, list_notes, get_chat, get_exchange)



async def _brain_call(
    path: str,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    params: dict[str, Any] | None = None,
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
                response = await client.get(url, params=params)
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


async def _api_call(
    path: str,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    params: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Make a request to the local server API (any path under /api/)."""
    if not _api_base_url:
        return {"error": "Server API not available"}
    url = f"{_api_base_url}{path}"
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            if method == "POST":
                response = await client.post(url, json=body or {})
            elif method == "DELETE":
                response = await client.delete(url, params=params)
            else:
                response = await client.get(url, params=params)
            if response.status_code >= 400:
                try:
                    detail = response.json().get("detail", response.text)
                except Exception:
                    detail = response.text
                return {"error": detail, "status_code": response.status_code}
            return response.json()
    except httpx.ConnectError:
        return {"error": "Server API unavailable — is the server running?"}
    except Exception as e:
        logger.error(f"API call failed ({method} {path}): {e}")
        return {"error": str(e)}


async def handle_tool_call(name: str, arguments: dict[str, Any]) -> str:
    """Handle a tool call and return the result as JSON string."""
    try:
        if name == "search_memory":
            p: dict[str, Any] = {"search": arguments["query"]}
            if arguments.get("source") == "journal":
                p["type"] = "notes"
            elif arguments.get("source") == "chat":
                p["type"] = "chats"
            if arguments.get("date_from"):
                p["date_from"] = arguments["date_from"]
            if arguments.get("date_to"):
                p["date_to"] = arguments["date_to"]
            p["limit"] = arguments.get("limit", 10)
            result = await _brain_call("/memory", params=p)
        elif name == "get_session":
            sid = arguments["session_id"]
            result = await _api_call(f"/chat/{sid}")
            if result.get("error") and result.get("status_code") == 404:
                return json.dumps({"error": f"Session not found: {sid}"})
        elif name == "search_by_tag":
            tag = arguments["tag"]
            p = {"limit": arguments.get("limit", 20)}
            result = await _api_call(f"/chat/tags/{tag}", params=p)
        elif name == "list_tags":
            result = await _api_call("/chat/tags")
        elif name == "add_session_tag":
            result = await _api_call(
                f"/chat/{arguments['session_id']}/tags",
                method="POST",
                body={"tag": arguments["tag"]},
            )
        elif name == "remove_session_tag":
            result = await _api_call(
                f"/chat/{arguments['session_id']}/tags/{arguments['tag']}",
                method="DELETE",
            )
        # Multi-Agent Session Tools
        elif name == "create_session":
            if not _session_context or not _session_context.is_available:
                result = {
                    "error": "Session context not available. This tool can only be called from an active session."
                }
            else:
                result = await _api_call(
                    "/chat/children",
                    method="POST",
                    body={
                        "title": arguments["title"],
                        "agentType": arguments["agent_type"],
                        "initialMessage": arguments["initial_message"],
                        "parentSessionId": _session_context.session_id,
                        "trustLevel": _session_context.trust_level,
                        "containerId": _session_context.container_id,
                    },
                )
        # Brain Tools
        elif name == "brain_schema":
            result = await _brain_call("/schema")
        elif name == "brain_list_containers":
            qs = f"?limit={arguments['limit']}" if "limit" in arguments else ""
            result = await _brain_call(f"/containers{qs}")
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
        # Vault Tools — routed through brain HTTP API (server owns the graph lock)
        elif name == "search_chats":
            p = {"query": arguments["query"], "limit": arguments.get("limit", 10)}
            if arguments.get("module"):
                p["module"] = arguments["module"]
            result = await _brain_call("/chats/search", params=p)
        elif name == "list_chats":
            p = {"limit": arguments.get("limit", 20)}
            if arguments.get("module"):
                p["module"] = arguments["module"]
            if arguments.get("archived"):
                p["archived"] = "true"
            if arguments.get("search"):
                p["search"] = arguments["search"]
            result = await _brain_call("/chats", params=p)
        elif name == "list_notes":
            p = {"limit": arguments.get("limit", 20)}
            if arguments.get("date_from"):
                p["date_from"] = arguments["date_from"]
            if arguments.get("date_to"):
                p["date_to"] = arguments["date_to"]
            if arguments.get("note_type"):
                p["note_type"] = arguments["note_type"]
            if arguments.get("search"):
                p["search"] = arguments["search"]
            result = await _brain_call("/daily/entries", params=p)
        elif name == "get_chat":
            sid = arguments["session_id"]
            p = {}
            if "exchange_limit" in arguments:
                p["exchange_limit"] = arguments["exchange_limit"]
            if "max_chars" in arguments:
                p["max_chars"] = arguments["max_chars"]
            result = await _brain_call(f"/chats/{sid}", params=p if p else None)
        elif name == "get_exchange":
            result = await _brain_call("/exchanges", params={"id": arguments["exchange_id"]})
        elif name == "write_note":
            result = await _brain_call(
                "/notes",
                method="POST",
                body={
                    "note_type": arguments["note_type"],
                    "title": arguments["title"],
                    "content": arguments["content"],
                    "date": arguments.get("date"),
                },
            )
        else:
            return json.dumps({"error": f"Unknown tool: {name}"})

        return json.dumps(result, indent=2, default=str)

    except Exception as e:
        logger.error(f"Tool error ({name}): {e}", exc_info=True)
        return json.dumps({"error": str(e)})


async def run_server():
    """Run the MCP server."""
    global _brain_base_url, _api_base_url
    port = os.environ.get("PARACHUTE_SERVER_PORT", "3333")
    _brain_base_url = f"http://localhost:{port}/api/brain"
    _api_base_url = f"http://localhost:{port}/api"

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
