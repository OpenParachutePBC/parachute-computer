"""
MCP (Model Context Protocol) server management API endpoints.

Includes support for:
- Listing/adding/removing MCP servers
- Testing stdio servers
- OAuth flow for remote servers
"""

import asyncio
import hashlib
import json
import logging
import os
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlencode

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import RedirectResponse
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.db.database import get_database
from parachute.lib.mcp_loader import (
    load_mcp_servers,
    invalidate_mcp_cache,
    _get_server_type,
)

router = APIRouter()
logger = logging.getLogger(__name__)

# In-memory storage for PKCE challenges (should use Redis in production)
# Key: state parameter, Value: {code_verifier, server_name, created_at}
_oauth_states: dict[str, dict[str, Any]] = {}


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

    # Add auth info for remote servers
    if server_type == "http":
        auth = config.get("auth", "none")
        response["auth"] = auth
        response["authRequired"] = auth != "none"
        response["scopes"] = config.get("scopes", [])

        # Validate remote server config
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

    # Get headers if configured (including auth)
    headers = dict(server_config.get("headers", {}))

    # Check if OAuth token is stored
    auth = server_config.get("auth", "none")
    if auth in ("oauth", "bearer"):
        try:
            db = await get_database()
            token = await db.get_oauth_token(name)
            if token and token.get("access_token"):
                token_type = token.get("token_type", "Bearer")
                headers["Authorization"] = f"{token_type} {token['access_token']}"
        except Exception as e:
            logger.warning(f"Failed to get OAuth token for {name}: {e}")

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


# =============================================================================
# OAuth Flow for Remote MCP Servers
# =============================================================================

# Cache for OAuth discovery metadata
_oauth_discovery_cache: dict[str, dict[str, Any]] = {}

# Cache for dynamically registered clients
_dynamic_clients_cache: dict[str, dict[str, Any]] = {}


async def _discover_oauth_metadata(server_url: str) -> Optional[dict[str, Any]]:
    """
    Discover OAuth metadata from server's .well-known endpoint.

    Per MCP OAuth spec, servers advertise their OAuth config at:
    {origin}/.well-known/oauth-authorization-server
    """
    import httpx
    from urllib.parse import urlparse

    # Check cache first
    if server_url in _oauth_discovery_cache:
        return _oauth_discovery_cache[server_url]

    try:
        parsed = urlparse(server_url)
        origin = f"{parsed.scheme}://{parsed.netloc}"
        discovery_url = f"{origin}/.well-known/oauth-authorization-server"

        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(discovery_url)
            if response.status_code == 200:
                metadata = response.json()
                _oauth_discovery_cache[server_url] = metadata
                logger.info(f"Discovered OAuth metadata for {server_url}")
                return metadata
    except Exception as e:
        logger.debug(f"No OAuth discovery for {server_url}: {e}")

    return None


async def _register_dynamic_client(
    registration_endpoint: str,
    redirect_uri: str,
    client_name: str = "Parachute",
    scopes: Optional[list[str]] = None,
) -> Optional[dict[str, Any]]:
    """
    Dynamically register a client with an OAuth server.

    Per OAuth 2.0 Dynamic Client Registration (RFC 7591).

    For mobile/remote clients, we use the OOB (out-of-band) redirect URI
    since many OAuth providers don't allow custom URL schemes.
    """
    import httpx

    # Check cache first
    cache_key = f"{registration_endpoint}:{redirect_uri}"
    if cache_key in _dynamic_clients_cache:
        return _dynamic_clients_cache[cache_key]

    # Determine which redirect URIs to try
    # If OOB is explicitly requested, use it directly
    # Otherwise try the provided URI, falling back to OOB if rejected
    if redirect_uri == "urn:ietf:wg:oauth:2.0:oob":
        redirect_uris_to_try = [redirect_uri]
    elif redirect_uri.startswith("https://") or redirect_uri.startswith("http://localhost"):
        redirect_uris_to_try = [redirect_uri]
    else:
        # Non-standard redirect, try OOB first (more likely to be accepted)
        redirect_uris_to_try = ["urn:ietf:wg:oauth:2.0:oob", redirect_uri]

    for try_redirect in redirect_uris_to_try:
        try:
            registration_data = {
                "client_name": client_name,
                "redirect_uris": [try_redirect],
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "client_secret_post",
            }

            if scopes:
                registration_data["scope"] = " ".join(scopes)

            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.post(
                    registration_endpoint,
                    json=registration_data,
                    headers={"Content-Type": "application/json"},
                )
                if response.status_code in (200, 201):
                    client_info = response.json()
                    # Store which redirect was actually used
                    client_info["_actual_redirect_uri"] = try_redirect
                    _dynamic_clients_cache[cache_key] = client_info
                    logger.info(f"Registered dynamic client: {client_info.get('client_id')} with redirect: {try_redirect}")
                    return client_info
                else:
                    error_data = response.json() if response.headers.get("content-type", "").startswith("application/json") else {}
                    if error_data.get("error") == "invalid_redirect_uri":
                        logger.debug(f"Redirect URI {try_redirect} rejected, trying next...")
                        continue
                    logger.warning(
                        f"Dynamic registration failed: {response.status_code} {response.text}"
                    )
        except Exception as e:
            logger.error(f"Dynamic client registration error: {e}")

    return None


def _generate_pkce_pair() -> tuple[str, str]:
    """Generate PKCE code verifier and challenge pair."""
    # Generate random code verifier (43-128 chars per spec)
    code_verifier = secrets.token_urlsafe(64)[:96]

    # Generate code challenge (S256 method)
    code_challenge = hashlib.sha256(code_verifier.encode("ascii")).digest()
    # Base64url encode without padding
    import base64

    code_challenge_b64 = (
        base64.urlsafe_b64encode(code_challenge).decode("ascii").rstrip("=")
    )

    return code_verifier, code_challenge_b64


def _cleanup_expired_states() -> None:
    """Remove expired OAuth state entries (older than 10 minutes)."""
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=10)
    expired = [
        state
        for state, data in _oauth_states.items()
        if data.get("created_at", datetime.min.replace(tzinfo=timezone.utc)) < cutoff
    ]
    for state in expired:
        del _oauth_states[state]


class OAuthStartRequest(BaseModel):
    """Request to start OAuth flow."""

    redirect_uri: str  # Where to redirect after auth (Flutter app deep link)
    scopes: Optional[list[str]] = None  # Override default scopes


class OAuthCallbackRequest(BaseModel):
    """Request from OAuth callback."""

    code: str
    state: str


class OAuthTokenRequest(BaseModel):
    """Request to store a token directly (for API key auth)."""

    token: str
    token_type: str = "Bearer"
    expires_in: Optional[int] = None  # Seconds until expiry


@router.get("/mcps/{name}/oauth/status")
async def get_oauth_status(request: Request, name: str) -> dict[str, Any]:
    """
    Get OAuth authentication status for a remote MCP server.

    Returns whether the server is authenticated and token metadata.
    Also performs OAuth discovery to detect if server supports OAuth.
    """
    logger.info(f"OAuth status check for server: {name}")

    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        logger.warning(f"OAuth status: server '{name}' not found")
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    server_type = _get_server_type(server_config)
    logger.info(f"OAuth status: {name} is type={server_type}")

    if server_type != "http":
        return {
            "name": name,
            "type": server_type,
            "authRequired": False,
            "authenticated": True,  # stdio servers don't need auth
        }

    server_url = server_config.get("url")
    auth = server_config.get("auth", "none")
    supports_oauth = auth == "oauth"
    discovered_scopes = []

    logger.info(f"OAuth status: {name} url={server_url} auth={auth}")

    # If auth is "none", check if server actually supports OAuth via discovery
    if auth == "none" and server_url:
        logger.info(f"OAuth status: attempting discovery for {name}")
        discovered = await _discover_oauth_metadata(server_url)
        if discovered and discovered.get("authorization_endpoint"):
            supports_oauth = True
            auth = "oauth"  # Server supports OAuth even if not configured
            discovered_scopes = discovered.get("scopes_supported", [])
            logger.info(f"OAuth status: discovered OAuth support for {name}, scopes={discovered_scopes}")
        else:
            logger.info(f"OAuth status: no OAuth discovered for {name}")

    # Check for stored token first
    db = await get_database()
    token = await db.get_oauth_token(name)

    if token:
        is_expired = await db.is_token_expired(name)
        return {
            "name": name,
            "type": "http",
            "auth": auth,
            "authRequired": supports_oauth,
            "authenticated": not is_expired,
            "expired": is_expired,
            "scopes": token.get("scopes", []),
            "discoveredScopes": discovered_scopes,
            "expiresAt": token["expires_at"].isoformat() if token.get("expires_at") else None,
        }

    if supports_oauth:
        return {
            "name": name,
            "type": "http",
            "auth": auth,
            "authRequired": True,
            "authenticated": False,
            "discoveredScopes": discovered_scopes,
        }
    else:
        return {
            "name": name,
            "type": "http",
            "authRequired": False,
            "authenticated": True,
        }


@router.post("/mcps/{name}/oauth/start")
async def start_oauth_flow(
    request: Request, name: str, body: OAuthStartRequest
) -> dict[str, Any]:
    """
    Start OAuth flow for a remote MCP server.

    Supports two modes:
    1. Pre-configured OAuth (oauth config in .mcp.json)
    2. OAuth Discovery (auto-discover from .well-known endpoint)

    For discovery mode, also supports dynamic client registration.
    If the requested redirect_uri is rejected, falls back to OOB flow.

    Returns the authorization URL that the client should open in a browser,
    plus the actual redirect_uri being used (may differ if OOB fallback).
    """
    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    server_type = _get_server_type(server_config)
    if server_type != "http":
        raise HTTPException(
            status_code=400, detail=f"Server '{name}' is not a remote server"
        )

    server_url = server_config.get("url")
    if not server_url:
        raise HTTPException(status_code=400, detail=f"Server '{name}' has no URL")

    # Try to get OAuth config from server config first
    oauth_config = server_config.get("oauth", {})
    authorization_url = oauth_config.get("authorization_url")
    token_url = oauth_config.get("token_url")
    client_id = oauth_config.get("client_id")
    actual_redirect_uri = body.redirect_uri  # May change if OOB fallback

    # If not configured, try OAuth discovery
    if not authorization_url or not client_id:
        logger.info(f"Attempting OAuth discovery for {name}")
        discovered = await _discover_oauth_metadata(server_url)

        if discovered:
            authorization_url = discovered.get("authorization_endpoint")
            token_url = discovered.get("token_endpoint")
            registration_url = discovered.get("registration_endpoint")

            # Update oauth_config with discovered values
            oauth_config["authorization_url"] = authorization_url
            oauth_config["token_url"] = token_url
            oauth_config["discovered"] = True

            # Get scopes from discovery if not specified
            if not oauth_config.get("scopes") and discovered.get("scopes_supported"):
                # Use 'mcp' scope if available, otherwise use first available
                supported = discovered.get("scopes_supported", [])
                if "mcp" in supported:
                    oauth_config["scopes"] = ["mcp"]
                elif supported:
                    oauth_config["scopes"] = supported[:1]

            # If server supports dynamic registration and we don't have a client_id
            if not client_id and registration_url:
                logger.info(f"Attempting dynamic client registration for {name}")
                # Pass scopes to registration (some servers require this)
                reg_scopes = oauth_config.get("scopes") or (["mcp"] if "mcp" in discovered.get("scopes_supported", []) else None)
                client_info = await _register_dynamic_client(
                    registration_url,
                    body.redirect_uri,
                    client_name=f"Parachute ({name})",
                    scopes=reg_scopes,
                )
                if client_info:
                    client_id = client_info.get("client_id")
                    oauth_config["client_id"] = client_id
                    oauth_config["client_secret"] = client_info.get("client_secret")
                    # Check if we fell back to OOB redirect
                    actual_redirect_uri = client_info.get("_actual_redirect_uri", body.redirect_uri)

    if not authorization_url or not client_id:
        raise HTTPException(
            status_code=400,
            detail=f"Server '{name}' has no OAuth configuration and discovery failed. "
            "Configure oauth settings in .mcp.json or ensure server supports OAuth discovery.",
        )

    # Cleanup expired states
    _cleanup_expired_states()

    # Generate PKCE pair
    code_verifier, code_challenge = _generate_pkce_pair()

    # Generate state parameter
    state = secrets.token_urlsafe(32)

    # Store state for callback verification (include discovered oauth_config)
    _oauth_states[state] = {
        "code_verifier": code_verifier,
        "server_name": name,
        "redirect_uri": actual_redirect_uri,  # Use actual redirect
        "created_at": datetime.now(timezone.utc),
        "oauth_config": oauth_config,
    }

    # Build authorization URL
    scopes = body.scopes or oauth_config.get("scopes") or server_config.get("scopes", [])
    params = {
        "client_id": client_id,
        "redirect_uri": actual_redirect_uri,  # Use actual redirect
        "response_type": "code",
        "state": state,
        "code_challenge": code_challenge,
        "code_challenge_method": "S256",
    }
    if scopes:
        params["scope"] = " ".join(scopes)

    # Add resource parameter if specified (RFC 8707)
    resource = oauth_config.get("resource") or server_url
    if resource:
        params["resource"] = resource

    auth_url = f"{authorization_url}?{urlencode(params)}"

    is_oob = actual_redirect_uri == "urn:ietf:wg:oauth:2.0:oob"
    logger.info(f"Started OAuth flow for '{name}' (discovered={oauth_config.get('discovered', False)}, oob={is_oob})")

    return {
        "authorizationUrl": auth_url,
        "state": state,
        "redirectUri": actual_redirect_uri,  # Tell client which redirect is being used
        "isOob": is_oob,  # Tell client if this is OOB flow
    }


@router.get("/mcps/{name}/oauth/redirect")
async def handle_oauth_redirect(
    request: Request, name: str, code: str = "", state: str = "", error: str = ""
) -> RedirectResponse:
    """
    Handle OAuth redirect from authorization server (browser redirect).

    This is the GET endpoint that the browser redirects to after user authorizes.
    It processes the callback and redirects to a success/error page.
    """
    if error:
        # OAuth error - show error page
        return RedirectResponse(
            url=f"/oauth-error.html?error={error}&server={name}",
            status_code=302,
        )

    if not code or not state:
        return RedirectResponse(
            url=f"/oauth-error.html?error=missing_params&server={name}",
            status_code=302,
        )

    # Verify state
    if state not in _oauth_states:
        return RedirectResponse(
            url=f"/oauth-error.html?error=invalid_state&server={name}",
            status_code=302,
        )

    state_data = _oauth_states.pop(state)

    if state_data["server_name"] != name:
        return RedirectResponse(
            url=f"/oauth-error.html?error=state_mismatch&server={name}",
            status_code=302,
        )

    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        return RedirectResponse(
            url=f"/oauth-error.html?error=server_not_found&server={name}",
            status_code=302,
        )

    # Use oauth_config from state (includes discovered values)
    oauth_config = state_data.get("oauth_config") or server_config.get("oauth", {})
    token_url = oauth_config.get("token_url")
    client_id = oauth_config.get("client_id")
    client_secret = oauth_config.get("client_secret")

    if not token_url or not client_id:
        return RedirectResponse(
            url=f"/oauth-error.html?error=missing_config&server={name}",
            status_code=302,
        )

    # Exchange code for token
    import httpx

    token_data = {
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": state_data["redirect_uri"],
        "client_id": client_id,
        "code_verifier": state_data["code_verifier"],
    }
    if client_secret:
        token_data["client_secret"] = client_secret

    # Add resource parameter if specified
    resource = oauth_config.get("resource") or server_config.get("url")
    if resource:
        token_data["resource"] = resource

    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                token_url,
                data=token_data,
                headers={"Accept": "application/json"},
            )
            response.raise_for_status()
            token_response = response.json()
    except Exception as e:
        logger.error(f"Token exchange failed: {e}")
        return RedirectResponse(
            url=f"/oauth-error.html?error=token_exchange_failed&server={name}",
            status_code=302,
        )

    # Parse token response
    access_token = token_response.get("access_token")
    refresh_token = token_response.get("refresh_token")
    token_type = token_response.get("token_type", "Bearer")
    expires_in = token_response.get("expires_in")
    scopes = token_response.get("scope", "").split() if token_response.get("scope") else None

    if not access_token:
        return RedirectResponse(
            url=f"/oauth-error.html?error=no_access_token&server={name}",
            status_code=302,
        )

    # Calculate expiry time
    expires_at = None
    if expires_in:
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=int(expires_in))

    # Store token
    db = await get_database()
    await db.store_oauth_token(
        server_name=name,
        access_token=access_token,
        refresh_token=refresh_token,
        token_type=token_type,
        expires_at=expires_at,
        scopes=scopes,
    )

    logger.info(f"OAuth flow completed for MCP server '{name}' via redirect")

    # Return a simple success HTML page
    from fastapi.responses import HTMLResponse
    return HTMLResponse(
        content=f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>Authorization Successful</title>
            <style>
                body {{ font-family: system-ui, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }}
                .card {{ background: white; padding: 2rem; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); text-align: center; }}
                h1 {{ color: #22c55e; margin-bottom: 0.5rem; }}
                p {{ color: #666; }}
            </style>
        </head>
        <body>
            <div class="card">
                <h1>✓ Authorization Successful</h1>
                <p>You have successfully connected <strong>{name}</strong> to Parachute.</p>
                <p>You can close this window and return to the app.</p>
            </div>
        </body>
        </html>
        """,
        status_code=200,
    )


@router.post("/mcps/{name}/oauth/callback")
async def handle_oauth_callback(
    request: Request, name: str, body: OAuthCallbackRequest
) -> dict[str, Any]:
    """
    Handle OAuth callback after user authorizes.

    Exchanges the authorization code for access/refresh tokens.
    """
    # Verify state
    if body.state not in _oauth_states:
        raise HTTPException(status_code=400, detail="Invalid or expired state parameter")

    state_data = _oauth_states.pop(body.state)

    if state_data["server_name"] != name:
        raise HTTPException(status_code=400, detail="State mismatch")

    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    # Use oauth_config from state (includes discovered values) or fall back to server config
    oauth_config = state_data.get("oauth_config") or server_config.get("oauth", {})
    token_url = oauth_config.get("token_url")
    client_id = oauth_config.get("client_id")
    client_secret = oauth_config.get("client_secret")  # Optional

    if not token_url:
        raise HTTPException(
            status_code=400, detail=f"Server '{name}' missing token_url in OAuth config"
        )

    if not client_id:
        raise HTTPException(
            status_code=400, detail=f"Server '{name}' missing client_id in OAuth config"
        )

    # Exchange code for token
    import httpx

    token_data = {
        "grant_type": "authorization_code",
        "code": body.code,
        "redirect_uri": state_data["redirect_uri"],
        "client_id": client_id,
        "code_verifier": state_data["code_verifier"],
    }
    if client_secret:
        token_data["client_secret"] = client_secret

    # Add resource parameter if specified
    resource = oauth_config.get("resource") or server_config.get("url")
    if resource:
        token_data["resource"] = resource

    try:
        async with httpx.AsyncClient() as client:
            response = await client.post(
                token_url,
                data=token_data,
                headers={"Accept": "application/json"},
            )
            response.raise_for_status()
            token_response = response.json()
    except httpx.HTTPStatusError as e:
        logger.error(f"Token exchange failed: {e.response.text}")
        raise HTTPException(
            status_code=400,
            detail=f"Token exchange failed: {e.response.text}",
        )
    except Exception as e:
        logger.error(f"Token exchange error: {e}")
        raise HTTPException(status_code=500, detail=f"Token exchange error: {str(e)}")

    # Parse token response
    access_token = token_response.get("access_token")
    refresh_token = token_response.get("refresh_token")
    token_type = token_response.get("token_type", "Bearer")
    expires_in = token_response.get("expires_in")
    scopes = token_response.get("scope", "").split() if token_response.get("scope") else None

    if not access_token:
        raise HTTPException(status_code=400, detail="No access token in response")

    # Calculate expiry time
    expires_at = None
    if expires_in:
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=int(expires_in))

    # Store token
    db = await get_database()
    await db.store_oauth_token(
        server_name=name,
        access_token=access_token,
        refresh_token=refresh_token,
        token_type=token_type,
        expires_at=expires_at,
        scopes=scopes,
    )

    logger.info(f"OAuth flow completed for MCP server '{name}'")

    return {
        "success": True,
        "serverName": name,
        "tokenType": token_type,
        "expiresAt": expires_at.isoformat() if expires_at else None,
        "scopes": scopes,
    }


@router.post("/mcps/{name}/oauth/token")
async def store_oauth_token(
    request: Request, name: str, body: OAuthTokenRequest
) -> dict[str, Any]:
    """
    Store a token directly (for bearer/API key auth).

    Use this when the user provides an API key instead of going through OAuth.
    """
    settings = get_settings()
    all_servers = await load_mcp_servers(settings.vault_path)
    server_config = all_servers.get(name)

    if not server_config:
        raise HTTPException(status_code=404, detail=f"MCP server '{name}' not found")

    # Calculate expiry if provided
    expires_at = None
    if body.expires_in:
        expires_at = datetime.now(timezone.utc) + timedelta(seconds=body.expires_in)

    # Store token
    db = await get_database()
    await db.store_oauth_token(
        server_name=name,
        access_token=body.token,
        token_type=body.token_type,
        expires_at=expires_at,
    )

    logger.info(f"Stored API token for MCP server '{name}'")

    return {
        "success": True,
        "serverName": name,
        "tokenType": body.token_type,
        "expiresAt": expires_at.isoformat() if expires_at else None,
    }


@router.delete("/mcps/{name}/oauth/logout")
async def oauth_logout(request: Request, name: str) -> dict[str, Any]:
    """
    Log out from a remote MCP server (delete stored token).
    """
    db = await get_database()
    deleted = await db.delete_oauth_token(name)

    if deleted:
        logger.info(f"Logged out from MCP server '{name}'")
        return {"success": True, "serverName": name}
    else:
        return {"success": False, "serverName": name, "message": "No token found"}


@router.get("/mcps/oauth/tokens")
async def list_oauth_tokens(request: Request) -> dict[str, Any]:
    """
    List all stored OAuth tokens (metadata only, not actual tokens).
    """
    db = await get_database()
    tokens = await db.list_oauth_tokens()

    # Convert datetime objects to ISO strings
    for token in tokens:
        if token.get("expires_at"):
            token["expires_at"] = token["expires_at"].isoformat()
        if token.get("created_at"):
            if isinstance(token["created_at"], datetime):
                token["created_at"] = token["created_at"].isoformat()
        if token.get("updated_at"):
            if isinstance(token["updated_at"], datetime):
                token["updated_at"] = token["updated_at"].isoformat()

    return {"tokens": tokens}
