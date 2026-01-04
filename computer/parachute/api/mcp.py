"""
MCP (Model Context Protocol) server management API endpoints.
"""

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.lib.mcp_loader import load_mcp_servers, invalidate_mcp_cache

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

    is_builtin = config.get("_builtin", False)

    return {
        "name": name,
        "builtin": is_builtin,
        # Include all config fields except internal markers
        **{k: v for k, v in config.items() if not k.startswith("_")},
        # Add display info (same as Node.js)
        "displayType": "stdio" if command else config.get("type", "unknown"),
        "displayCommand": display_command.strip(),
    }


@router.get("/mcps")
async def list_mcp_servers_endpoint(request: Request) -> dict[str, Any]:
    """
    List all configured MCP servers.

    Returns both built-in servers (like 'parachute') and user-configured ones.
    """
    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    servers = []

    for name, server_config in all_servers.items():
        servers.append(config_to_server_response(name, server_config))

    return {"servers": servers}


@router.get("/mcps/{name}")
async def get_mcp_server(request: Request, name: str) -> dict[str, Any]:
    """
    Get a specific MCP server configuration.
    """
    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    return config_to_server_response(name, server_config)


@router.post("/mcps")
async def add_mcp_server(request: Request, body: McpServerConfig) -> dict[str, Any]:
    """
    Add or update an MCP server configuration.

    Note: Cannot modify built-in servers - they must be overridden via .mcp.json.
    """
    config = load_mcp_config()

    if "mcpServers" not in config:
        config["mcpServers"] = {}

    config["mcpServers"][body.name] = body.config
    save_mcp_config(config)
    invalidate_mcp_cache()  # Clear cache so changes are picked up

    logger.info(f"Added/updated MCP server: {body.name}")

    return {
        "success": True,
        "server": config_to_server_response(body.name, body.config),
    }


@router.delete("/mcps/{name}")
async def remove_mcp_server(request: Request, name: str) -> dict[str, Any]:
    """
    Remove an MCP server configuration.

    Note: Cannot remove built-in servers, only user-configured ones.
    """
    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)

    if name not in all_servers:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    if all_servers[name].get("_builtin"):
        raise HTTPException(
            status_code=400,
            detail=f"Cannot remove built-in server '{name}'. You can override it in .mcp.json instead.",
        )

    config = load_mcp_config()
    if name in config.get("mcpServers", {}):
        del config["mcpServers"][name]
        save_mcp_config(config)
        invalidate_mcp_cache()

    logger.info(f"Removed MCP server: {name}")

    return {"success": True, "removed": name}


@router.post("/mcps/{name}/test")
async def test_mcp_server(request: Request, name: str) -> dict[str, Any]:
    """
    Test if an MCP server can start successfully.

    Attempts to start the MCP server and check if it responds.
    """
    import shutil
    import subprocess

    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    is_builtin = server_config.get("_builtin", False)
    command = server_config.get("command")

    if not command:
        return {
            "name": name,
            "builtin": is_builtin,
            "status": "error",
            "error": "No command configured",
        }

    # Check if the command exists
    # For absolute paths, check file exists; for commands, use shutil.which
    if command.startswith("/"):
        from pathlib import Path

        if not Path(command).exists():
            return {
                "name": name,
                "builtin": is_builtin,
                "status": "error",
                "error": f"Command not found: {command}",
                "hint": "Check that the path exists and is executable",
            }
    else:
        if not shutil.which(command):
            return {
                "name": name,
                "builtin": is_builtin,
                "status": "error",
                "error": f"Command not found: {command}",
                "hint": "Make sure the command is installed and in your PATH",
            }

    # Try to actually start the server briefly
    try:
        args = server_config.get("args", [])
        env = {**dict(os.environ), **server_config.get("env", {})}

        # Start the process
        proc = subprocess.Popen(
            [command] + args,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
        )

        # Give it a moment to start (or fail)
        try:
            # Wait briefly for it to either start or fail
            proc.wait(timeout=2)
            # If it exited, check if it was an error
            if proc.returncode != 0:
                stderr = proc.stderr.read().decode("utf-8", errors="replace")[:500]
                return {
                    "name": name,
                    "builtin": is_builtin,
                    "status": "error",
                    "error": f"Server exited with code {proc.returncode}",
                    "hint": stderr if stderr else "Check server logs for details",
                }
        except subprocess.TimeoutExpired:
            # Server is still running after 2 seconds - that's good!
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()

        return {
            "name": name,
            "builtin": is_builtin,
            "status": "ok",
            "message": "Server started successfully",
        }

    except FileNotFoundError as e:
        return {
            "name": name,
            "builtin": is_builtin,
            "status": "error",
            "error": f"Command not found: {e}",
        }
    except Exception as e:
        return {
            "name": name,
            "builtin": is_builtin,
            "status": "error",
            "error": str(e),
        }


@router.get("/mcps/{name}/tools")
async def get_mcp_server_tools(request: Request, name: str) -> dict[str, Any]:
    """
    Get the list of tools provided by an MCP server.
    """
    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    # For now, return empty tools - full implementation would query the server
    return {
        "name": name,
        "tools": [],
        "message": "Tool discovery not yet implemented in Python backend",
    }
