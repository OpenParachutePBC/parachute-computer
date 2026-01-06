"""
Curator MCP Server - External subprocess MCP server for curator tools.

This server provides curator-specific tools as an external MCP server,
avoiding the SDK's in-process MCP server transport issues.

Tools provided:
- update_title: Update session title
- update_context: Append to AGENTS.md files in context chain (or legacy contexts/)
- list_context_files: List available AGENTS.md files in context chain
- get_session_info: Get current session info

Usage:
    python -m parachute.curator_mcp_server

Environment variables:
    PARACHUTE_VAULT_PATH: Path to the vault
    CURATOR_SESSION_ID: Parent session ID to curate
    CURATOR_CONTEXT_FOLDERS: Comma-separated folder paths (e.g., "Projects/parachute,Areas/taiji")
"""

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
from mcp.types import (
    Tool,
    TextContent,
    CallToolResult,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Get configuration from environment
VAULT_PATH = Path(os.environ.get("PARACHUTE_VAULT_PATH", os.getcwd()))
SESSION_ID = os.environ.get("CURATOR_SESSION_ID", "")
CONTEXT_FOLDERS_STR = os.environ.get("CURATOR_CONTEXT_FOLDERS", "")

# Parse context folders
CONTEXT_FOLDERS: list[str] = []
if CONTEXT_FOLDERS_STR:
    CONTEXT_FOLDERS = [f.strip() for f in CONTEXT_FOLDERS_STR.split(",") if f.strip()]

# Create MCP server
server = Server("curator-tools")


def get_contexts_dir() -> Path:
    """Get the legacy contexts directory path."""
    return VAULT_PATH / "Chat" / "contexts"


def get_context_chain() -> tuple[list[str], list[dict]]:
    """Get the AGENTS.md context chain for the session's context folders.

    Returns:
        Tuple of (updatable_file_paths, chain_info)
    """
    try:
        from parachute.core.context_folders import ContextFolderService

        service = ContextFolderService(VAULT_PATH)
        effective_folders = CONTEXT_FOLDERS if CONTEXT_FOLDERS else [""]  # Root if nothing
        chain = service.build_chain(effective_folders, max_tokens=100000)

        updatable = [f.path for f in chain.files if f.exists]
        chain_info = [
            {"path": f.path, "level": f.level, "exists": f.exists}
            for f in chain.files
        ]
        return updatable, chain_info
    except Exception as e:
        logger.warning(f"Failed to build context chain: {e}")
        return [], []


# Cache the context chain at startup
UPDATABLE_FILES, CHAIN_INFO = get_context_chain()


def list_context_files_impl() -> str:
    """List all context files (chain + legacy)."""
    output_lines = []

    # AGENTS.md context chain
    output_lines.append("## Context Chain (AGENTS.md files you can update):\n")
    if CHAIN_INFO:
        for f in CHAIN_INFO:
            if f["exists"]:
                output_lines.append(f"- {f['path']} ({f['level']})")
    else:
        output_lines.append("No AGENTS.md files in context chain.")

    # Legacy context files
    contexts_dir = get_contexts_dir()
    if contexts_dir.exists():
        legacy_files = []
        for f in contexts_dir.glob("*.md"):
            try:
                with open(f, "r", encoding="utf-8") as fp:
                    first_line = fp.readline().strip()
                    name = first_line.lstrip("#").strip() if first_line.startswith("#") else f.stem
            except Exception:
                name = f.stem
            legacy_files.append({"name": f.name, "title": name})

        if legacy_files:
            output_lines.append("\n## Legacy context files (Chat/contexts/):\n")
            for f in legacy_files:
                output_lines.append(f"- {f['name']}: {f['title']}")

    return "\n".join(output_lines)


async def update_title_impl(new_title: str) -> str:
    """Update the session title in the database."""
    if not SESSION_ID:
        return "Error: No session ID configured"

    if not new_title or len(new_title) > 200:
        return "Error: Title must be between 1 and 200 characters"

    # Connect to the database
    db_path = VAULT_PATH / "Chat" / "sessions.db"
    if not db_path.exists():
        return f"Error: Database not found at {db_path}"

    try:
        import aiosqlite
        async with aiosqlite.connect(str(db_path)) as db:
            await db.execute(
                "UPDATE sessions SET title = ? WHERE id = ?",
                (new_title, SESSION_ID)
            )
            await db.commit()

            # Verify the update
            async with db.execute(
                "SELECT title FROM sessions WHERE id = ?", (SESSION_ID,)
            ) as cursor:
                row = await cursor.fetchone()
                if row:
                    return f"Successfully updated title to: {new_title}"
                else:
                    return f"Error: Session {SESSION_ID} not found"
    except Exception as e:
        return f"Error updating title: {e}"


async def update_context_impl(file_path_arg: str, content: str) -> str:
    """Append content to a context file (AGENTS.md chain or legacy contexts/).

    Args:
        file_path_arg: Either a full path like "Projects/parachute/AGENTS.md" for chain files,
                       or just a filename like "general-context.md" for legacy files.
        content: Content to append
    """
    if not file_path_arg:
        return "Error: file_path is required"

    if not content:
        return "Error: content is required"

    # Security: no path traversal
    if ".." in file_path_arg:
        return "Error: Invalid path (no .. allowed)"

    # Determine if this is a chain file path or legacy filename
    if "/" in file_path_arg or file_path_arg in ["AGENTS.md", "CLAUDE.md"]:
        # Chain file - must be in UPDATABLE_FILES
        if file_path_arg not in UPDATABLE_FILES:
            available = ", ".join(UPDATABLE_FILES) if UPDATABLE_FILES else "(none)"
            return f"Error: {file_path_arg} is not in the context chain. Available: {available}"
        target_path = VAULT_PATH / file_path_arg
    else:
        # Legacy file in Chat/contexts/
        if not file_path_arg.endswith(".md"):
            file_path_arg = file_path_arg + ".md"

        contexts_dir = get_contexts_dir()
        contexts_dir.mkdir(parents=True, exist_ok=True)
        target_path = contexts_dir / file_path_arg

        # Verify path is within contexts dir
        try:
            resolved = target_path.resolve()
            if not str(resolved).startswith(str(contexts_dir.resolve())):
                return "Error: File path escapes contexts directory"
        except Exception:
            return "Error: Invalid file path"

    try:
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        addition = f"\n\n<!-- Added by curator on {timestamp} -->\n{content}"

        with open(target_path, "a", encoding="utf-8") as f:
            f.write(addition)

        return f"Successfully appended to {file_path_arg}"
    except Exception as e:
        return f"Error writing to file: {e}"


@server.list_tools()
async def list_tools() -> list[Tool]:
    """List available curator tools."""
    return [
        Tool(
            name="update_title",
            description="Update the session title. Use this when you determine a better, more descriptive title. Format: 'Project: Task' (max 8 words). Be very conservative - only update if the current title is wrong or misleading.",
            inputSchema={
                "type": "object",
                "properties": {
                    "new_title": {
                        "type": "string",
                        "description": "The new title for the session (max 200 chars)",
                    }
                },
                "required": ["new_title"],
            },
        ),
        Tool(
            name="update_context",
            description="Append new information to a context file. For AGENTS.md files in the context chain, use the full path (e.g., 'Projects/parachute/AGENTS.md'). For legacy files in Chat/contexts/, use just the filename (e.g., 'general-context.md'). Be conservative - only add significant information.",
            inputSchema={
                "type": "object",
                "properties": {
                    "file_path": {
                        "type": "string",
                        "description": "Path to AGENTS.md (e.g., 'Projects/parachute/AGENTS.md') or legacy filename (e.g., 'general-context.md')",
                    },
                    "content": {
                        "type": "string",
                        "description": "Content to append to the file",
                    },
                },
                "required": ["file_path", "content"],
            },
        ),
        Tool(
            name="list_context_files",
            description="List all AGENTS.md files in the context chain and legacy context files. Use this to see what files you can update.",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        Tool(
            name="get_session_info",
            description="Get information about the current session being curated.",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> CallToolResult:
    """Handle tool calls."""
    try:
        if name == "update_title":
            result = await update_title_impl(arguments.get("new_title", ""))
            return CallToolResult(content=[TextContent(type="text", text=result)])

        elif name == "update_context":
            result = await update_context_impl(
                arguments.get("file_path", "") or arguments.get("file_name", ""),  # backwards compat
                arguments.get("content", ""),
            )
            return CallToolResult(content=[TextContent(type="text", text=result)])

        elif name == "list_context_files":
            result = list_context_files_impl()
            return CallToolResult(content=[TextContent(type="text", text=result)])

        elif name == "get_session_info":
            result = f"Session ID: {SESSION_ID or 'Not configured'}\nVault: {VAULT_PATH}"
            return CallToolResult(content=[TextContent(type="text", text=result)])

        else:
            return CallToolResult(
                content=[TextContent(type="text", text=f"Unknown tool: {name}")],
                isError=True,
            )

    except Exception as e:
        logger.error(f"Tool {name} error: {e}")
        return CallToolResult(
            content=[TextContent(type="text", text=f"Error: {e}")],
            isError=True,
        )


async def main():
    """Run the MCP server."""
    logger.info(f"Starting curator MCP server")
    logger.info(f"  Vault: {VAULT_PATH}")
    logger.info(f"  Session: {SESSION_ID or 'not set'}")

    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )


if __name__ == "__main__":
    asyncio.run(main())
