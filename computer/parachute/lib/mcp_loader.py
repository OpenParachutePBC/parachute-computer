"""
MCP (Model Context Protocol) server configuration loader.

Built-in MCPs (like the Parachute vault search) are configured in code.
User MCPs are loaded from .mcp.json in the vault.

Supports two types of MCP servers:
1. stdio (local): command + args to spawn a process
2. http (remote): url + auth config for remote MCP servers

Remote servers can use different auth methods:
- none: No authentication required
- bearer: Static API key/token (configured in headers)
"""

import json
import logging
import os
import re
import sys
from pathlib import Path
from typing import Any, Literal, Optional

import aiofiles

logger = logging.getLogger(__name__)


# Valid auth types for remote MCP servers
AuthType = Literal["none", "bearer"]


def _get_builtin_mcp_servers(vault_path: Path) -> dict[str, dict[str, Any]]:
    """
    Get built-in MCP server configurations.

    These are configured in code using paths relative to the server installation,
    making them portable across different machines/vaults.
    """
    # Find the base directory (where this code lives)
    # This file is at: base/parachute/lib/mcp_loader.py
    # Base dir is: base/
    base_dir = Path(__file__).parent.parent.parent

    # Find the Python executable (prefer venv if it exists)
    venv_python = base_dir / "venv" / "bin" / "python"
    if venv_python.exists():
        python_path = str(venv_python)
    else:
        # Fall back to current Python
        python_path = sys.executable

    return {
        "parachute": {
            "command": python_path,
            "args": ["-m", "parachute.mcp_server"],
            "env": {
                "PARACHUTE_VAULT_PATH": str(vault_path),
                "PYTHONPATH": str(base_dir),
            },
            "_builtin": True,  # Marker to identify built-in servers
        }
    }

# Cache for loaded MCP servers
_mcp_cache: dict[str, dict[str, Any]] = {}
_mcp_cache_path: Optional[Path] = None


def _substitute_env_vars(value: str) -> str:
    """Substitute environment variables in a string."""
    # Pattern: ${VAR_NAME} or $VAR_NAME
    pattern = r"\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_]*)"

    def replace(match: re.Match) -> str:
        var_name = match.group(1) or match.group(2)
        return os.environ.get(var_name, match.group(0))

    return re.sub(pattern, replace, value)


def _process_config(config: dict[str, Any]) -> dict[str, Any]:
    """Process a config dict, substituting environment variables."""
    result = {}
    for key, value in config.items():
        if isinstance(value, str):
            result[key] = _substitute_env_vars(value)
        elif isinstance(value, dict):
            result[key] = _process_config(value)
        elif isinstance(value, list):
            result[key] = [
                _substitute_env_vars(v) if isinstance(v, str) else v for v in value
            ]
        else:
            result[key] = value
    return result


async def load_mcp_servers(
    vault_path: Path, raw: bool = False
) -> dict[str, dict[str, Any]]:
    """
    Load MCP server configurations.

    Built-in servers (like 'parachute') are always included.
    User servers from .mcp.json can override built-ins or add new ones.

    Args:
        vault_path: Path to the vault
        raw: If True, don't substitute environment variables

    Returns:
        Dictionary mapping server names to their configurations
    """
    global _mcp_cache, _mcp_cache_path

    mcp_path = vault_path / ".mcp.json"

    # Check cache
    if not raw and _mcp_cache_path == mcp_path and _mcp_cache:
        return _mcp_cache

    # Start with built-in servers
    servers = _get_builtin_mcp_servers(vault_path)

    # Load user servers from .mcp.json (can override built-ins)
    if mcp_path.exists():
        try:
            async with aiofiles.open(mcp_path, "r", encoding="utf-8") as f:
                content = await f.read()
                data = json.loads(content)

            # .mcp.json can have servers under "mcpServers" key or as top-level keys
            # Claude Code uses "mcpServers" wrapper, so check for that first
            if "mcpServers" in data and isinstance(data["mcpServers"], dict):
                user_servers = data["mcpServers"]
            else:
                # Fallback: treat top-level keys as servers
                user_servers = {k: v for k, v in data.items() if isinstance(v, dict)}

            # User servers override built-ins
            servers.update(user_servers)

            logger.debug(f"Loaded {len(user_servers)} user MCP servers from {mcp_path}")

        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in {mcp_path}: {e}")
        except Exception as e:
            logger.error(f"Error loading user MCP servers: {e}")

    if raw:
        return servers

    # Process each server config (substitute env vars and normalize)
    processed = {}
    for name, config in servers.items():
        processed_config = _process_config(config)

        # Ensure HTTP servers have required `type` field for SDK compatibility
        if "url" in processed_config and "type" not in processed_config:
            processed_config["type"] = "http"
            logger.debug(f"Added type='http' to server '{name}' for SDK compatibility")

        processed[name] = processed_config

    # Update cache
    _mcp_cache = processed
    _mcp_cache_path = mcp_path

    logger.debug(f"Total MCP servers available: {len(processed)}")
    return processed


def _validate_remote_server(name: str, config: dict[str, Any]) -> list[str]:
    """
    Validate a remote (HTTP) MCP server configuration.

    Returns a list of validation errors (empty if valid).
    """
    errors = []

    url = config.get("url", "")
    if not url:
        errors.append(f"Server '{name}': missing 'url' field")
    elif not url.startswith(("http://", "https://")):
        errors.append(f"Server '{name}': url must start with http:// or https://")

    auth = config.get("auth", "none")
    if auth not in ("none", "bearer"):
        errors.append(f"Server '{name}': invalid auth type '{auth}' (must be none or bearer)")

    if auth == "bearer" and not config.get("headers", {}).get("Authorization"):
        errors.append(f"Server '{name}': bearer auth requires 'Authorization' header")

    return errors


def _get_server_type(config: dict[str, Any]) -> str:
    """Determine server type from config."""
    # Check explicit type field first
    explicit_type = config.get("type", "").lower()
    if explicit_type:
        # Map common type names to our categories
        if explicit_type in ("stdio", "command"):
            return "stdio"
        elif explicit_type in ("http", "https", "sse", "streamable-http"):
            return "http"
        else:
            return explicit_type  # Return unknown types as-is for filtering

    # Fall back to inferring from fields
    if "command" in config:
        return "stdio"
    elif "url" in config:
        return "http"
    else:
        return "unknown"


def filter_stdio_servers(servers: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """
    Filter MCP servers to only include stdio servers.

    The Claude SDK only supports stdio (command-based) MCP servers.
    HTTP/remote servers are not supported by the SDK and must be
    filtered out before passing to the SDK to avoid validation errors.

    Args:
        servers: Dictionary of server name -> config

    Returns:
        Dictionary containing only stdio servers
    """
    if not servers:
        return {}

    stdio_servers = {}
    for name, config in servers.items():
        server_type = _get_server_type(config)
        if server_type == "stdio":
            stdio_servers[name] = config
        else:
            logger.debug(f"Filtering out non-stdio MCP server '{name}' (type: {server_type})")

    return stdio_servers


def validate_and_filter_servers(
    servers: dict[str, dict[str, Any]]
) -> tuple[dict[str, dict[str, Any]], list[str]]:
    """
    Validate MCP server configurations and filter out invalid ones.

    This provides graceful degradation - invalid servers are logged and skipped
    rather than causing the entire system to fail.

    Args:
        servers: Dictionary of server name -> config

    Returns:
        Tuple of (valid_servers, warning_messages)
    """
    if not servers:
        return {}, []

    valid_servers = {}
    warnings: list[str] = []

    for name, config in servers.items():
        server_type = _get_server_type(config)

        # Validate based on server type
        if server_type == "stdio":
            # Validate stdio server
            errors = _validate_stdio_server(name, config)
            if errors:
                for error in errors:
                    warnings.append(error)
                    logger.warning(f"MCP validation: {error}")
            else:
                valid_servers[name] = config

        elif server_type == "http":
            # Validate HTTP/SSE server
            errors = _validate_remote_server(name, config)
            if errors:
                for error in errors:
                    warnings.append(error)
                    logger.warning(f"MCP validation: {error}")
            else:
                valid_servers[name] = config

        else:
            # Unknown server type - skip with warning
            warning = f"Server '{name}': unsupported type '{server_type}' (skipping)"
            warnings.append(warning)
            logger.warning(f"MCP validation: {warning}")

    if warnings:
        logger.info(
            f"MCP validation: {len(valid_servers)}/{len(servers)} servers valid, "
            f"{len(warnings)} warnings"
        )

    return valid_servers, warnings


def _validate_stdio_server(name: str, config: dict[str, Any]) -> list[str]:
    """
    Validate a stdio (command-based) MCP server configuration.

    Returns a list of validation errors (empty if valid).
    """
    errors = []

    command = config.get("command", "")
    if not command:
        errors.append(f"Server '{name}': missing 'command' field")
    elif not isinstance(command, str):
        errors.append(f"Server '{name}': 'command' must be a string")

    args = config.get("args", [])
    if args and not isinstance(args, list):
        errors.append(f"Server '{name}': 'args' must be a list")

    env = config.get("env", {})
    if env and not isinstance(env, dict):
        errors.append(f"Server '{name}': 'env' must be a dictionary")

    return errors


async def list_mcp_servers(vault_path: Path) -> list[dict[str, Any]]:
    """List all configured MCP servers with metadata."""
    servers = await load_mcp_servers(vault_path)
    result = []

    for name, config in servers.items():
        server_type = _get_server_type(config)

        server_info = {
            "name": name,
            "type": server_type,
            "builtin": config.get("_builtin", False),
            **{k: v for k, v in config.items() if not k.startswith("_")},
        }

        # Add auth status for remote servers
        if server_type == "http":
            auth = config.get("auth", "none")
            server_info["auth"] = auth
            server_info["authRequired"] = auth != "none"

            # Validate remote server config
            validation_errors = _validate_remote_server(name, config)
            if validation_errors:
                server_info["validationErrors"] = validation_errors

        result.append(server_info)

    return result


async def add_mcp_server(
    vault_path: Path, name: str, config: dict[str, Any]
) -> dict[str, dict[str, Any]]:
    """Add or update an MCP server configuration."""
    mcp_path = vault_path / ".mcp.json"

    # Load existing config or create new
    if mcp_path.exists():
        async with aiofiles.open(mcp_path, "r", encoding="utf-8") as f:
            content = await f.read()
            data = json.loads(content)
    else:
        data = {"mcpServers": {}}

    # Add/update server
    data["mcpServers"][name] = config

    # Write back
    async with aiofiles.open(mcp_path, "w", encoding="utf-8") as f:
        await f.write(json.dumps(data, indent=2))

    # Invalidate cache
    global _mcp_cache
    _mcp_cache = {}

    logger.info(f"Added MCP server: {name}")
    return data["mcpServers"]


async def remove_mcp_server(vault_path: Path, name: str) -> dict[str, dict[str, Any]]:
    """Remove an MCP server configuration."""
    mcp_path = vault_path / ".mcp.json"

    if not mcp_path.exists():
        return {}

    async with aiofiles.open(mcp_path, "r", encoding="utf-8") as f:
        content = await f.read()
        data = json.loads(content)

    if name in data.get("mcpServers", {}):
        del data["mcpServers"][name]

        async with aiofiles.open(mcp_path, "w", encoding="utf-8") as f:
            await f.write(json.dumps(data, indent=2))

        # Invalidate cache
        global _mcp_cache
        _mcp_cache = {}

        logger.info(f"Removed MCP server: {name}")

    return data.get("mcpServers", {})


def resolve_mcp_servers(
    agent_config: Optional[str | list[str]], global_servers: dict[str, dict[str, Any]]
) -> Optional[dict[str, dict[str, Any]]]:
    """
    Resolve MCP servers for an agent based on its configuration.

    Args:
        agent_config: Agent's mcpServers config: 'all', list of names, or None
        global_servers: All available MCP servers

    Returns:
        Dictionary of resolved server configurations
    """
    if not global_servers:
        return None

    if agent_config == "all":
        return global_servers

    if isinstance(agent_config, list):
        return {name: global_servers[name] for name in agent_config if name in global_servers}

    return None


def invalidate_mcp_cache() -> None:
    """Invalidate the MCP server cache."""
    global _mcp_cache, _mcp_cache_path
    _mcp_cache = {}
    _mcp_cache_path = None
