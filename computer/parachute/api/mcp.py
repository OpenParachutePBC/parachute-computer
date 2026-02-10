"""
MCP (Model Context Protocol) server management API endpoints.

Includes support for:
- Listing/adding/removing MCP servers
- Testing stdio servers
"""

import json
import logging
import os
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.lib.mcp_loader import (
    load_mcp_servers,
    invalidate_mcp_cache,
    _get_server_type,
)

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
    url = config.get("url", "")
    display_command = f"{command} {' '.join(args)}" if command else url or "N/A"

    is_builtin = config.get("_builtin", False)
    server_type = _get_server_type(config)

    response = {
        "name": name,
        "builtin": is_builtin,
        # Include all config fields except internal markers
        **{k: v for k, v in config.items() if not k.startswith("_")},
        # Add display info (same as Node.js)
        "displayType": server_type,
        "displayCommand": display_command.strip(),
    }

    # Add validation info for remote servers
    if server_type == "http":
        from parachute.lib.mcp_loader import _validate_remote_server
        validation_errors = _validate_remote_server(name, config)
        if validation_errors:
            response["validationErrors"] = validation_errors

    return response


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


async def _test_http_server(
    name: str, server_config: dict[str, Any], is_builtin: bool
) -> dict[str, Any]:
    """
    Test connectivity to an HTTP MCP server.

    Makes a simple request to verify the server is reachable.
    """
    import httpx

    url = server_config.get("url")
    if not url:
        return {
            "name": name,
            "builtin": is_builtin,
            "status": "error",
            "error": "No URL configured",
        }

    # Get headers if configured
    headers = dict(server_config.get("headers", {}))

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            # Try a simple request - most MCP servers should respond to OPTIONS or GET
            # We'll try HEAD first (lighter), then GET if that fails
            try:
                response = await client.request("OPTIONS", url, headers=headers)
            except Exception:
                # Fall back to GET
                response = await client.get(url, headers=headers)

            # Check response - MCP servers might return various codes
            # 2xx and 3xx are clearly OK
            # 401/403 means we reached the server but need auth
            # 404 might mean the endpoint exists but requires specific paths
            # 405 Method Not Allowed also means server is reachable
            if response.status_code < 500:
                status_message = f"Server reachable (HTTP {response.status_code})"
                if response.status_code in (401, 403):
                    status_message += " - authentication required"
                elif response.status_code == 404:
                    status_message += " - endpoint exists but may require specific paths"
                elif response.status_code == 405:
                    status_message = "Server reachable (Method Not Allowed is expected)"

                return {
                    "name": name,
                    "builtin": is_builtin,
                    "status": "ok",
                    "message": status_message,
                    "httpStatus": response.status_code,
                }
            else:
                return {
                    "name": name,
                    "builtin": is_builtin,
                    "status": "error",
                    "error": f"Server error (HTTP {response.status_code})",
                    "httpStatus": response.status_code,
                }

    except httpx.ConnectError as e:
        return {
            "name": name,
            "builtin": is_builtin,
            "status": "error",
            "error": f"Connection failed: {e}",
            "hint": "Check that the URL is correct and the server is running",
        }
    except httpx.TimeoutException:
        return {
            "name": name,
            "builtin": is_builtin,
            "status": "error",
            "error": "Connection timed out",
            "hint": "Server took too long to respond",
        }
    except Exception as e:
        return {
            "name": name,
            "builtin": is_builtin,
            "status": "error",
            "error": str(e),
        }


@router.post("/mcps/{name}/test")
async def test_mcp_server(request: Request, name: str) -> dict[str, Any]:
    """
    Test if an MCP server can start/connect successfully.

    For stdio servers: Attempts to start the MCP server process.
    For HTTP servers: Makes a request to verify connectivity.
    """
    import shutil
    import subprocess

    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    is_builtin = server_config.get("_builtin", False)
    server_type = _get_server_type(server_config)

    # Handle HTTP servers differently
    if server_type == "http":
        return await _test_http_server(name, server_config, is_builtin)

    # Handle stdio servers
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


async def _discover_stdio_tools(
    name: str, server_config: dict[str, Any]
) -> dict[str, Any]:
    """Discover tools from a stdio MCP server via JSON-RPC."""
    import subprocess

    command = server_config.get("command")
    if not command:
        return {"name": name, "tools": [], "error": "No command configured"}

    args = server_config.get("args", [])
    env = {**dict(os.environ), **server_config.get("env", {})}

    try:
        proc = subprocess.Popen(
            [command] + args,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE,
        )

        def _rpc_request(method: str, params: dict | None = None, req_id: int = 1) -> bytes:
            msg = {"jsonrpc": "2.0", "method": method, "id": req_id}
            if params:
                msg["params"] = params
            raw = json.dumps(msg)
            return raw.encode("utf-8") + b"\n"

        def _rpc_notification(method: str, params: dict | None = None) -> bytes:
            msg = {"jsonrpc": "2.0", "method": method}
            if params:
                msg["params"] = params
            raw = json.dumps(msg)
            return raw.encode("utf-8") + b"\n"

        # Send initialize request
        init_params = {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "parachute", "version": "1.0.0"},
        }
        proc.stdin.write(_rpc_request("initialize", init_params, req_id=1))
        proc.stdin.flush()

        # Read initialize response (with timeout)
        import select
        import time

        deadline = time.time() + 10
        init_response = b""
        while time.time() < deadline:
            remaining = deadline - time.time()
            ready, _, _ = select.select([proc.stdout], [], [], min(remaining, 0.5))
            if ready:
                chunk = proc.stdout.read1(4096) if hasattr(proc.stdout, 'read1') else proc.stdout.readline()
                if not chunk:
                    break
                init_response += chunk
                # Try to parse as JSON
                try:
                    json.loads(init_response.decode("utf-8").strip())
                    break  # Got valid JSON
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
            if proc.poll() is not None:
                break

        if not init_response:
            proc.kill()
            return {"name": name, "tools": [], "error": "Server did not respond to initialize"}

        # Send initialized notification
        proc.stdin.write(_rpc_notification("notifications/initialized"))
        proc.stdin.flush()

        # Send tools/list request
        proc.stdin.write(_rpc_request("tools/list", req_id=2))
        proc.stdin.flush()

        # Read tools/list response
        deadline = time.time() + 10
        tools_response = b""
        while time.time() < deadline:
            remaining = deadline - time.time()
            ready, _, _ = select.select([proc.stdout], [], [], min(remaining, 0.5))
            if ready:
                chunk = proc.stdout.read1(4096) if hasattr(proc.stdout, 'read1') else proc.stdout.readline()
                if not chunk:
                    break
                tools_response += chunk
                try:
                    json.loads(tools_response.decode("utf-8").strip())
                    break
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
            if proc.poll() is not None:
                break

        # Clean up
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()

        if not tools_response:
            return {"name": name, "tools": [], "error": "No response to tools/list"}

        parsed = json.loads(tools_response.decode("utf-8").strip())
        raw_tools = parsed.get("result", {}).get("tools", [])
        tools = [
            {
                "name": t.get("name", ""),
                "description": t.get("description"),
            }
            for t in raw_tools
        ]
        return {"name": name, "tools": tools}

    except FileNotFoundError:
        return {"name": name, "tools": [], "error": f"Command not found: {command}"}
    except Exception as e:
        return {"name": name, "tools": [], "error": str(e)}


async def _discover_http_tools(
    name: str, server_config: dict[str, Any]
) -> dict[str, Any]:
    """Discover tools from an HTTP MCP server via JSON-RPC."""
    import httpx

    url = server_config.get("url")
    if not url:
        return {"name": name, "tools": [], "error": "No URL configured"}

    headers = dict(server_config.get("headers", {}))
    headers["Content-Type"] = "application/json"

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            # Initialize
            init_body = {
                "jsonrpc": "2.0",
                "method": "initialize",
                "id": 1,
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "parachute", "version": "1.0.0"},
                },
            }
            await client.post(url, json=init_body, headers=headers)

            # tools/list
            tools_body = {
                "jsonrpc": "2.0",
                "method": "tools/list",
                "id": 2,
            }
            response = await client.post(url, json=tools_body, headers=headers)

            if response.status_code != 200:
                return {"name": name, "tools": [], "error": f"HTTP {response.status_code}"}

            parsed = response.json()
            raw_tools = parsed.get("result", {}).get("tools", [])
            tools = [
                {
                    "name": t.get("name", ""),
                    "description": t.get("description"),
                }
                for t in raw_tools
            ]
            return {"name": name, "tools": tools}

    except Exception as e:
        return {"name": name, "tools": [], "error": str(e)}


@router.get("/mcps/{name}/tools")
async def get_mcp_server_tools(request: Request, name: str) -> dict[str, Any]:
    """
    Get the list of tools provided by an MCP server.

    Connects to the server via JSON-RPC and calls tools/list.
    """
    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    server_type = _get_server_type(server_config)

    if server_type == "http":
        return await _discover_http_tools(name, server_config)
    else:
        return await _discover_stdio_tools(name, server_config)
