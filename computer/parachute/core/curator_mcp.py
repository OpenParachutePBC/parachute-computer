"""
Curator MCP Server — scoped per-run background context agent toolset.

This is a stdio MCP server started as a subprocess for each curator run.
It accepts --session-id and --vault-path at startup so the correct session
is baked in — the global _session_context mechanism in mcp_server.py only
works for HTTP request handlers, not background asyncio tasks.

Tools:
    update_title(title)         — update session title (respects user-set guard)
    update_summary(summary)     — update session summary
    log_activity(summary, ...)  — append entry to daily activity log

Usage:
    python -m parachute.core.curator_mcp --session-id <id> --vault-path <path>
"""

import argparse
import asyncio
import json
import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

# Log to stderr only — stdout is the MCP protocol stream
logging.basicConfig(
    level=logging.WARNING,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("CuratorMCP")


# ---------------------------------------------------------------------------
# Database helpers (open-use-close pattern per call — no persistent connection)
# ---------------------------------------------------------------------------


async def _open_db(vault_path: Path):
    """Open a fresh database connection."""
    from parachute.db.database import Database

    db_path = vault_path / "Chat" / "sessions.db"
    db = Database(db_path)
    await db.connect()
    return db


# ---------------------------------------------------------------------------
# Tool handlers
# ---------------------------------------------------------------------------


async def handle_update_title(
    session_id: str, vault_path: Path, title: str
) -> dict[str, Any]:
    """Update session title — respects user-set title protection."""
    db = await _open_db(vault_path)
    try:
        session = await db.get_session(session_id)
        if session is None:
            return {"error": f"Session not found: {session_id}"}

        title_source = (session.metadata or {}).get("title_source")
        if title_source == "user":
            return {"status": "protected", "message": "Title set by user — not overwritten"}

        from parachute.models.session import SessionUpdate

        metadata = dict(session.metadata or {})
        metadata["title_source"] = "ai"
        await db.update_session(session_id, SessionUpdate(title=title, metadata=metadata))
        return {"status": "ok", "title": title}
    finally:
        await db.close()


async def handle_update_summary(
    session_id: str, vault_path: Path, summary: str
) -> dict[str, Any]:
    """Update session summary."""
    db = await _open_db(vault_path)
    try:
        from parachute.models.session import SessionUpdate

        await db.update_session(session_id, SessionUpdate(summary=summary))
        return {"status": "ok"}
    finally:
        await db.close()


async def handle_log_activity(
    session_id: str,
    vault_path: Path,
    summary: str,
    exchange_number: int = 0,
) -> dict[str, Any]:
    """Append an entry to the daily activity log."""
    # Fetch session title and agent_type for the log entry
    session_title: Optional[str] = None
    agent_type: Optional[str] = None

    db = await _open_db(vault_path)
    try:
        session = await db.get_session(session_id)
        if session:
            session_title = session.title
            agent_type = session.get_agent_type() if hasattr(session, "get_agent_type") else None
    finally:
        await db.close()

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    log_dir = vault_path / "Daily" / ".activity"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / f"{today}.jsonl"

    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "session_id": session_id,
        "session_title": session_title,
        "agent_type": agent_type,
        "exchange_number": exchange_number,
        "summary": summary,
    }
    with open(log_file, "a") as f:
        f.write(json.dumps(entry) + "\n")

    return {"status": "ok"}


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------


def build_server(session_id: str, vault_path: Path) -> Server:
    """Build and configure the curator MCP server."""
    server = Server("curator-mcp")

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        return [
            Tool(
                name="update_title",
                description=(
                    "Update the session title. Use a concise 3-8 word title capturing "
                    "the main topic. Do NOT call if the title was set by the user."
                ),
                inputSchema={
                    "type": "object",
                    "properties": {
                        "title": {
                            "type": "string",
                            "description": "New session title (3-8 words)",
                        },
                    },
                    "required": ["title"],
                },
            ),
            Tool(
                name="update_summary",
                description=(
                    "Update the session summary. Write 1-3 sentences summarizing "
                    "what has been discussed and accomplished so far in this session."
                ),
                inputSchema={
                    "type": "object",
                    "properties": {
                        "summary": {
                            "type": "string",
                            "description": "Session summary (1-3 sentences)",
                        },
                    },
                    "required": ["summary"],
                },
            ),
            Tool(
                name="log_activity",
                description=(
                    "Append a daily activity log entry for this exchange. "
                    "Records what was worked on today within this session — "
                    "sessions span multiple days, so each entry is timestamped. "
                    "Write 1-2 sentences about what was accomplished in this exchange."
                ),
                inputSchema={
                    "type": "object",
                    "properties": {
                        "summary": {
                            "type": "string",
                            "description": "Exchange summary (1-2 sentences)",
                        },
                        "exchange_number": {
                            "type": "integer",
                            "description": "Exchange number in the session",
                        },
                    },
                    "required": ["summary"],
                },
            ),
        ]

    @server.call_tool()
    async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
        try:
            if name == "update_title":
                result = await handle_update_title(session_id, vault_path, arguments["title"])
            elif name == "update_summary":
                result = await handle_update_summary(
                    session_id, vault_path, arguments["summary"]
                )
            elif name == "log_activity":
                result = await handle_log_activity(
                    session_id,
                    vault_path,
                    arguments["summary"],
                    arguments.get("exchange_number", 0),
                )
            else:
                result = {"error": f"Unknown tool: {name}"}
        except Exception as e:
            logger.error(f"Tool {name} failed: {e}", exc_info=True)
            result = {"error": str(e)}

        return [TextContent(type="text", text=json.dumps(result))]

    return server


async def main() -> None:
    parser = argparse.ArgumentParser(description="Curator MCP Server")
    parser.add_argument(
        "--session-id", required=True, help="Chat session ID this curator run is for"
    )
    parser.add_argument(
        "--vault-path",
        default=os.environ.get("VAULT_PATH", ""),
        help="Vault root path (default: VAULT_PATH env var)",
    )
    args = parser.parse_args()

    vault_path = Path(args.vault_path)
    if not vault_path.exists():
        logger.error(f"Vault path does not exist: {vault_path}")
        sys.exit(1)

    server = build_server(args.session_id, vault_path)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )


if __name__ == "__main__":
    asyncio.run(main())
