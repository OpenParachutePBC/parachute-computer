"""
Daily Curator MCP Server - External subprocess MCP server for daily curator tools.

This server provides daily-curator-specific tools as an external MCP server.

Tools provided:
- read_journal: Read journal entries for a specific date
- read_recent_journals: Read recent journal entries for context
- write_reflection: Write the daily reflection

Usage:
    python -m parachute.daily_curator_mcp_server

Environment variables:
    PARACHUTE_VAULT_PATH: Path to the vault
"""

import asyncio
import json
import logging
import os
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import (
    Tool,
    TextContent,
    CallToolResult,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Get configuration from environment
VAULT_PATH = Path(os.environ.get("PARACHUTE_VAULT_PATH", os.getcwd()))

# Directories
JOURNALS_DIR = VAULT_PATH / "Daily" / "journals"
REFLECTIONS_DIR = VAULT_PATH / "Daily" / "reflections"

# Create server
server = Server("daily-curator")


@server.list_tools()
async def list_tools() -> list[Tool]:
    """List available tools."""
    return [
        Tool(
            name="read_journal",
            description="Read journal entries for a specific date. Returns the full content of that day's journal.",
            inputSchema={
                "type": "object",
                "properties": {
                    "date": {
                        "type": "string",
                        "description": "Date in YYYY-MM-DD format"
                    }
                },
                "required": ["date"]
            }
        ),
        Tool(
            name="read_recent_journals",
            description="Read journal entries from the past N days for context. Useful for noticing patterns across days.",
            inputSchema={
                "type": "object",
                "properties": {
                    "days": {
                        "type": "integer",
                        "description": "Number of days to look back (default 7, max 30)",
                        "default": 7
                    }
                }
            }
        ),
        Tool(
            name="write_reflection",
            description="Write the daily reflection to Daily/reflections/{date}.md",
            inputSchema={
                "type": "object",
                "properties": {
                    "date": {
                        "type": "string",
                        "description": "Date in YYYY-MM-DD format"
                    },
                    "content": {
                        "type": "string",
                        "description": "The reflection content (markdown)"
                    }
                },
                "required": ["date", "content"]
            }
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> CallToolResult:
    """Handle tool calls."""

    if name == "read_journal":
        date_str = arguments.get("date", "")

        if not date_str:
            return CallToolResult(
                content=[TextContent(type="text", text="Error: date is required (YYYY-MM-DD format)")],
                isError=True
            )

        journal_file = JOURNALS_DIR / f"{date_str}.md"

        if not journal_file.exists():
            return CallToolResult(
                content=[TextContent(type="text", text=f"No journal found for {date_str}")]
            )

        try:
            content = journal_file.read_text(encoding="utf-8")
            return CallToolResult(
                content=[TextContent(type="text", text=f"# Journal for {date_str}\n\n{content}")]
            )
        except Exception as e:
            return CallToolResult(
                content=[TextContent(type="text", text=f"Error reading journal: {e}")],
                isError=True
            )

    elif name == "read_recent_journals":
        days_back = arguments.get("days", 7)
        days_back = min(int(days_back), 30)  # Cap at 30 days

        today = datetime.now().date()
        journals_found = []

        for i in range(1, days_back + 1):
            date = today - timedelta(days=i)
            date_str = date.strftime("%Y-%m-%d")
            journal_file = JOURNALS_DIR / f"{date_str}.md"

            if journal_file.exists():
                try:
                    content = journal_file.read_text(encoding="utf-8")
                    # Truncate very long journals for context
                    if len(content) > 5000:
                        content = content[:5000] + "\n\n...(truncated)"
                    journals_found.append(f"## {date_str}\n\n{content}")
                except Exception:
                    continue

        if not journals_found:
            return CallToolResult(
                content=[TextContent(type="text", text=f"No journals found in the past {days_back} days")]
            )

        return CallToolResult(
            content=[TextContent(
                type="text",
                text=f"# Recent Journals ({len(journals_found)} days)\n\n" + "\n\n---\n\n".join(journals_found)
            )]
        )

    elif name == "write_reflection":
        date_str = arguments.get("date", "")
        content = arguments.get("content", "")

        if not date_str:
            return CallToolResult(
                content=[TextContent(type="text", text="Error: date is required")],
                isError=True
            )

        if not content:
            return CallToolResult(
                content=[TextContent(type="text", text="Error: content is required")],
                isError=True
            )

        # Ensure reflections directory exists
        REFLECTIONS_DIR.mkdir(parents=True, exist_ok=True)

        reflection_file = REFLECTIONS_DIR / f"{date_str}.md"

        try:
            # Add metadata header
            full_content = f"""---
date: {date_str}
generated_at: {datetime.now(timezone.utc).isoformat()}
---

{content}
"""
            reflection_file.write_text(full_content, encoding="utf-8")

            logger.info(f"Daily curator wrote reflection for {date_str}")
            return CallToolResult(
                content=[TextContent(type="text", text=f"Successfully wrote reflection to Daily/reflections/{date_str}.md")]
            )
        except Exception as e:
            logger.error(f"Error writing reflection: {e}")
            return CallToolResult(
                content=[TextContent(type="text", text=f"Error writing reflection: {e}")],
                isError=True
            )

    else:
        return CallToolResult(
            content=[TextContent(type="text", text=f"Unknown tool: {name}")],
            isError=True
        )


async def main():
    """Run the MCP server."""
    logger.info(f"Starting daily curator MCP server for vault: {VAULT_PATH}")

    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
