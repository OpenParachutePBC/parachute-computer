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
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

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
        messages = await sm.load_session_messages(session)
        result["messages"] = messages

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
            content = journal_file.read_text(encoding="utf-8")

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
            content = journal_file.read_text(encoding="utf-8")
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
        content = journal_file.read_text(encoding="utf-8")

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
        else:
            return json.dumps({"error": f"Unknown tool: {name}"})

        return json.dumps(result, indent=2, default=str)

    except Exception as e:
        logger.error(f"Tool error ({name}): {e}", exc_info=True)
        return json.dumps({"error": str(e)})


async def run_server(vault_path: str):
    """Run the MCP server."""
    global _vault_path
    _vault_path = vault_path

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
    import os
    vault_path = args.vault_path or os.environ.get("PARACHUTE_VAULT_PATH")

    if not vault_path:
        print("Error: Vault path required (argument or PARACHUTE_VAULT_PATH env)", file=sys.stderr)
        sys.exit(1)

    if not Path(vault_path).exists():
        print(f"Error: Vault path does not exist: {vault_path}", file=sys.stderr)
        sys.exit(1)

    asyncio.run(run_server(vault_path))


if __name__ == "__main__":
    main()
