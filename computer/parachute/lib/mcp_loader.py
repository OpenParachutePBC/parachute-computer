"""
MCP (Model Context Protocol) server configuration loader.

Loads MCP server definitions from .mcp.json in the vault.
"""

import json
import logging
import os
import re
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

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
    Load MCP server configurations from .mcp.json.

    Args:
        vault_path: Path to the vault
        raw: If True, don't substitute environment variables

    Returns:
        Dictionary mapping server names to their configurations
    """
    global _mcp_cache, _mcp_cache_path

    mcp_path = vault_path / ".mcp.json"

    # Check cache (invalidate if path changed)
    if not raw and _mcp_cache_path == mcp_path and _mcp_cache:
        return _mcp_cache

    if not mcp_path.exists():
        return {}

    try:
        with open(mcp_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        servers = data.get("mcpServers", {})

        if raw:
            return servers

        # Process each server config
        processed = {}
        for name, config in servers.items():
            processed[name] = _process_config(config)

        # Update cache
        _mcp_cache = processed
        _mcp_cache_path = mcp_path

        logger.debug(f"Loaded {len(processed)} MCP servers from {mcp_path}")
        return processed

    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON in {mcp_path}: {e}")
        return {}
    except Exception as e:
        logger.error(f"Error loading MCP servers: {e}")
        return {}


async def list_mcp_servers(vault_path: Path) -> list[dict[str, Any]]:
    """List all configured MCP servers with metadata."""
    servers = await load_mcp_servers(vault_path)
    result = []

    for name, config in servers.items():
        server_info = {
            "name": name,
            "type": "stdio" if "command" in config else "http" if "url" in config else "unknown",
            **config,
        }
        result.append(server_info)

    return result


async def add_mcp_server(
    vault_path: Path, name: str, config: dict[str, Any]
) -> dict[str, dict[str, Any]]:
    """Add or update an MCP server configuration."""
    mcp_path = vault_path / ".mcp.json"

    # Load existing config or create new
    if mcp_path.exists():
        with open(mcp_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = {"mcpServers": {}}

    # Add/update server
    data["mcpServers"][name] = config

    # Write back
    with open(mcp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

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

    with open(mcp_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    if name in data.get("mcpServers", {}):
        del data["mcpServers"][name]

        with open(mcp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)

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
