"""
MCP (Model Context Protocol) server management API endpoints.
"""

import json
import logging
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from parachute.config import get_settings

router = APIRouter()
logger = logging.getLogger(__name__)


class McpServerConfig(BaseModel):
    """Configuration for an MCP server."""

    name: str
    config: dict[str, Any]


def get_mcp_config_path() -> Path:
    """Get the MCP configuration file path.

    MCP config is stored at {vault}/.mcp.json (same as Node.js server).
    """
    settings = get_settings()
    return settings.vault_path / ".mcp.json"


def load_mcp_config() -> dict[str, Any]:
    """Load MCP configuration from file.

    The .mcp.json format has servers as top-level keys:
    {
        "parachute": { "command": "node", "args": [...] },
        "glif": { "command": "npx", ... }
    }

    We wrap it for internal use with mcpServers key.
    """
    config_path = get_mcp_config_path()
    if not config_path.exists():
        return {"mcpServers": {}}
    try:
        raw_config = json.loads(config_path.read_text(encoding="utf-8"))
        # The file has servers as top-level keys, wrap in mcpServers
        return {"mcpServers": raw_config}
    except Exception as e:
        logger.error(f"Error loading MCP config: {e}")
        return {"mcpServers": {}}


def save_mcp_config(config: dict[str, Any]) -> None:
    """Save MCP configuration to file.

    Unwraps the mcpServers key before saving since file format
    has servers as top-level keys.
    """
    config_path = get_mcp_config_path()
    # Unwrap mcpServers for file format
    raw_config = config.get("mcpServers", config)
    config_path.write_text(json.dumps(raw_config, indent=2), encoding="utf-8")


def config_to_server_response(name: str, config: dict[str, Any]) -> dict[str, Any]:
    """Convert server config to API response format.

    Matches Node.js server format from mcp-loader.js listMcpServers().
    """
    # Build display command string
    command = config.get("command", "")
    args = config.get("args", [])
    display_command = f"{command} {' '.join(args)}" if command else config.get("url", "N/A")

    return {
        "name": name,
        # Include all config fields
        **{k: v for k, v in config.items()},
        # Add display info (same as Node.js)
        "displayType": "stdio" if command else config.get("type", "unknown"),
        "displayCommand": display_command.strip(),
    }


@router.get("/mcps")
async def list_mcp_servers(request: Request) -> dict[str, Any]:
    """
    List all configured MCP servers.
    """
    config = load_mcp_config()
    servers = []

    for name, server_config in config.get("mcpServers", {}).items():
        servers.append(config_to_server_response(name, server_config))

    return {"servers": servers}


@router.get("/mcps/{name}")
async def get_mcp_server(request: Request, name: str) -> dict[str, Any]:
    """
    Get a specific MCP server configuration.
    """
    config = load_mcp_config()
    server_config = config.get("mcpServers", {}).get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    return config_to_server_response(name, server_config)


@router.post("/mcps")
async def add_mcp_server(request: Request, body: McpServerConfig) -> dict[str, Any]:
    """
    Add or update an MCP server configuration.
    """
    config = load_mcp_config()

    if "mcpServers" not in config:
        config["mcpServers"] = {}

    config["mcpServers"][body.name] = body.config
    save_mcp_config(config)

    logger.info(f"Added/updated MCP server: {body.name}")

    return {
        "success": True,
        "server": config_to_server_response(body.name, body.config),
    }


@router.delete("/mcps/{name}")
async def remove_mcp_server(request: Request, name: str) -> dict[str, Any]:
    """
    Remove an MCP server configuration.
    """
    config = load_mcp_config()

    if name not in config.get("mcpServers", {}):
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    del config["mcpServers"][name]
    save_mcp_config(config)

    logger.info(f"Removed MCP server: {name}")

    return {"success": True, "removed": name}


@router.post("/mcps/{name}/test")
async def test_mcp_server(request: Request, name: str) -> dict[str, Any]:
    """
    Test if an MCP server can start successfully.
    """
    config = load_mcp_config()
    server_config = config.get("mcpServers", {}).get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    # For now, just return that we can't test yet
    # Full implementation would need to actually start the server
    return {
        "name": name,
        "status": "unknown",
        "message": "Server test not yet implemented in Python backend",
        "hint": "Ensure the command or URL is accessible",
    }


@router.get("/mcps/{name}/tools")
async def get_mcp_server_tools(request: Request, name: str) -> dict[str, Any]:
    """
    Get the list of tools provided by an MCP server.
    """
    config = load_mcp_config()
    server_config = config.get("mcpServers", {}).get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    # For now, return empty tools - full implementation would query the server
    return {
        "name": name,
        "tools": [],
        "message": "Tool discovery not yet implemented in Python backend",
    }
