"""
HTTP MCP Bridge for sandbox containers.

Exposes an MCP-compliant Streamable HTTP endpoint at /mcp/v1 that sandboxed
containers connect to over the Docker network. Authenticates requests using
session-scoped bearer tokens and dispatches to registered tool handlers.

Uses stateless mode + JSON responses — each POST is independent, no session
tracking on the MCP side.
"""

import logging
from contextvars import ContextVar
from typing import Any

from mcp.server import Server
from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
from mcp.types import TextContent, Tool

from parachute.lib.sandbox_tokens import SandboxTokenContext, SandboxTokenStore

logger = logging.getLogger(__name__)

# ContextVar carries auth context from ASGI wrapper into MCP tool handlers.
# Set before session_manager.handle_request(), read inside tool callbacks.
_current_sandbox_ctx: ContextVar[SandboxTokenContext | None] = ContextVar(
    "_current_sandbox_ctx", default=None
)


def get_sandbox_context() -> SandboxTokenContext | None:
    """Get the current sandbox token context (for use in tool handlers)."""
    return _current_sandbox_ctx.get()


def create_mcp_server() -> Server:
    """Create the MCP Server instance with tool handlers registered.

    Tool handlers are registered in mcp_tools.py and wired via
    register_tools().
    """
    from parachute.api.mcp_tools import register_tools

    server = Server("parachute-sandbox")
    register_tools(server)
    return server


def create_session_manager(server: Server) -> StreamableHTTPSessionManager:
    """Create the Streamable HTTP session manager.

    Stateless + JSON response mode:
    - Each POST creates a fresh ServerSession (no Mcp-Session-Id tracking)
    - Responses are plain JSON (no SSE streaming)
    """
    return StreamableHTTPSessionManager(
        app=server,
        event_store=None,
        json_response=True,
        stateless=True,
    )


def create_mcp_asgi_app(
    session_manager: StreamableHTTPSessionManager,
    token_store: SandboxTokenStore,
) -> Any:
    """Create an ASGI app that authenticates requests then delegates to MCP.

    Returns an ASGI callable (scope, receive, send) that:
    1. Extracts Bearer token from Authorization header
    2. Validates against token_store
    3. Sets ContextVar so tool handlers can read permissions
    4. Delegates to session_manager.handle_request()
    """

    async def asgi_app(scope: dict, receive: Any, send: Any) -> None:
        if scope["type"] not in ("http",):
            # Let non-HTTP scopes (lifespan, websocket) pass through
            await session_manager.handle_request(scope, receive, send)
            return

        # Extract Bearer token from headers
        headers = dict(scope.get("headers", []))
        auth_header = headers.get(b"authorization", b"").decode("utf-8", errors="ignore")

        token = ""
        if auth_header.startswith("Bearer "):
            token = auth_header[7:]

        ctx = token_store.validate_token(token) if token else None

        if ctx is None:
            # Return 401 Unauthorized
            await send({
                "type": "http.response.start",
                "status": 401,
                "headers": [
                    [b"content-type", b"application/json"],
                ],
            })
            await send({
                "type": "http.response.body",
                "body": b'{"error": "Unauthorized", "message": "Valid sandbox token required"}',
            })
            return

        # Set context for tool handlers
        reset_token = _current_sandbox_ctx.set(ctx)
        try:
            await session_manager.handle_request(scope, receive, send)
        finally:
            _current_sandbox_ctx.reset(reset_token)

    return asgi_app
