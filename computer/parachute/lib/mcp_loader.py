"""
MCP (Model Context Protocol) server configuration loader.

Built-in MCPs (like the Parachute vault search) are configured in code.
User MCPs are loaded from .mcp.json in the vault.

Supports two types of MCP servers:
1. stdio (local): command + args to spawn a process
2. http (remote): url + auth config for remote MCP servers

Remote servers can use different auth methods:
- none: No authentication required
- bearer: Static API key/token
- oauth: OAuth 2.1 flow (requires token management)
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
AuthType = Literal["none", "bearer", "oauth"]


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
    vault_path: Path, raw: bool = False, attach_tokens: bool = False
) -> dict[str, dict[str, Any]]:
    """
    Load MCP server configurations.

    Built-in servers (like 'parachute') are always included.
    User servers from .mcp.json can override built-ins or add new ones.

    Args:
        vault_path: Path to the vault
        raw: If True, don't substitute environment variables
        attach_tokens: If True, attach OAuth tokens to HTTP servers (for SDK use)

    Returns:
        Dictionary mapping server names to their configurations
    """
    global _mcp_cache, _mcp_cache_path

    mcp_path = vault_path / ".mcp.json"

    # Check cache (invalidate if path changed or tokens requested)
    # Don't use cache when attaching tokens since they may have changed
    if not raw and not attach_tokens and _mcp_cache_path == mcp_path and _mcp_cache:
        return _mcp_cache

    # Start with built-in servers
    servers = _get_builtin_mcp_servers(vault_path)

    # Load user servers from .mcp.json (can override built-ins)
    if mcp_path.exists():
        try:
            async with aiofiles.open(mcp_path, "r", encoding="utf-8") as f:
                content = await f.read()
                data = json.loads(content)

            # .mcp.json has servers as top-level keys (not under mcpServers)
            # Filter out any non-dict entries that might be metadata
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

    # Attach OAuth tokens to HTTP servers if requested
    if attach_tokens:
        processed = await _attach_oauth_tokens(processed)

    # Update cache (only if not attaching tokens)
    if not attach_tokens:
        _mcp_cache = processed
        _mcp_cache_path = mcp_path

    logger.debug(f"Total MCP servers available: {len(processed)}")
    return processed


async def _attach_oauth_tokens(servers: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """
    Attach OAuth tokens to HTTP servers that require authentication.

    The Claude SDK needs the Authorization header set for HTTP MCP servers.
    """
    from parachute.db.database import get_database

    result = {}
    db = await get_database()

    for name, config in servers.items():
        server_type = _get_server_type(config)

        if server_type == "http":
            # Check if we have a stored OAuth token for this server
            try:
                token = await db.get_oauth_token(name)
                if token and token.get("access_token"):
                    # Check if token is expired
                    is_expired = await db.is_token_expired(name)
                    if not is_expired:
                        # Add Authorization header
                        config = dict(config)  # Make a copy
                        headers = dict(config.get("headers", {}))
                        token_type = token.get("token_type", "Bearer")
                        headers["Authorization"] = f"{token_type} {token['access_token']}"
                        config["headers"] = headers
                        logger.info(f"Attached OAuth token to MCP server '{name}'")
                    else:
                        logger.warning(f"OAuth token expired for MCP server '{name}'")
            except Exception as e:
                logger.warning(f"Failed to get OAuth token for {name}: {e}")

        result[name] = config

    return result


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
    if auth not in ("none", "bearer", "oauth"):
        errors.append(f"Server '{name}': invalid auth type '{auth}' (must be none, bearer, or oauth)")

    if auth == "bearer" and not config.get("token"):
        errors.append(f"Server '{name}': bearer auth requires 'token' field")

    if auth == "oauth":
        # OAuth servers may optionally specify scopes
        scopes = config.get("scopes", [])
        if scopes and not isinstance(scopes, list):
            errors.append(f"Server '{name}': 'scopes' must be a list of strings")

    return errors


def _get_server_type(config: dict[str, Any]) -> str:
    """Determine server type from config."""
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
