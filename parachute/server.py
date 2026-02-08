"""
Parachute Computer Server

Main FastAPI application entry point with modular architecture.
Discovers and loads modules from vault/.modules/ directory.
"""

import logging
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

import uvicorn
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from parachute.api import api_router
from parachute.config import get_settings, Settings
from parachute.core.module_loader import ModuleLoader
from parachute.core.orchestrator import Orchestrator
# CURATOR REMOVED - curator service excluded from modular architecture
from parachute.core.scheduler import init_scheduler, stop_scheduler
from parachute.db.database import Database, init_database, close_database
from parachute.lib.logger import setup_logging, get_logger
from parachute.lib.server_config import (
    init_server_config,
    get_server_config,
    AuthMode,
)

logger = get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    settings = get_settings()

    # Set up logging
    setup_logging(level=settings.log_level)

    logger.info(f"Starting Parachute Computer server...")
    logger.info(f"Vault path: {settings.vault_path}")

    # Ensure vault directories exist
    settings.vault_path.mkdir(parents=True, exist_ok=True)
    (settings.vault_path / ".parachute").mkdir(exist_ok=True)

    # Initialize server config (API keys, auth settings)
    server_config = init_server_config(settings.vault_path)
    app.state.server_config = server_config
    logger.info(f"Auth mode: {server_config.security.require_auth.value}")
    logger.info(f"API keys configured: {len(server_config.security.api_keys)}")
    logger.info(f"Claude token: {'configured' if settings.claude_code_oauth_token else 'not set (run `claude setup-token`)'}")

    # Initialize database
    db = await init_database(settings.database_path)
    logger.info(f"Database initialized: {settings.database_path}")

    # Initialize orchestrator and store in app.state
    orchestrator = Orchestrator(
        vault_path=settings.vault_path,
        database=db,
        settings=settings,
    )
    app.state.orchestrator = orchestrator
    app.state.sandbox = orchestrator._sandbox  # Shared DockerSandbox for health checks
    app.state.database = db

    # CURATOR REMOVED - curator service excluded from modular architecture

    # Initialize scheduler for automated tasks
    scheduler = await init_scheduler(settings.vault_path)
    app.state.scheduler = scheduler
    logger.info("Scheduler initialized")

    # Load modules from vault/.modules/
    module_loader = ModuleLoader(settings.vault_path)
    modules = await module_loader.discover_and_load()
    app.state.module_loader = module_loader
    app.state.modules = modules
    logger.info(f"Loaded {len(modules)} modules: {list(modules.keys())}")

    # Register module routes dynamically and track which modules have routers
    module_has_router: dict[str, bool] = {}
    for name, module in modules.items():
        if hasattr(module, 'get_router'):
            router = module.get_router()
            if router:
                prefix = f"/api/{name}"
                app.include_router(router, prefix=prefix, tags=[name])
                logger.info(f"Registered routes for module: {name} at {prefix}")
                module_has_router[name] = True
                continue
        module_has_router[name] = False
    app.state.module_has_router = module_has_router

    # Initialize hooks runner
    from parachute.core.hooks.runner import HookRunner
    from parachute.api.hooks import init_hooks_api
    try:
        hook_runner = HookRunner(settings.vault_path)
        await hook_runner.discover()
        init_hooks_api(hook_runner)
        app.state.hook_runner = hook_runner
        logger.info(f"Hooks: {len(hook_runner.get_registered_hooks())} hooks discovered")
    except Exception as e:
        logger.warning(f"Failed to initialize hooks: {e}")
        app.state.hook_runner = None

    # Initialize bots API (pass server_ref with database for connector sessions)
    from parachute.api.bots import init_bots_api
    from types import SimpleNamespace

    async def orchestrate(session_id, message, source="bot"):
        """Wrapper that bridges connector call signature to orchestrator.run_streaming().

        Connectors call: orchestrate(session_id, message, source)
        Orchestrator expects: run_streaming(message, session_id, ..., trust_level)
        """
        session = await db.get_session(session_id)
        trust_level = getattr(session, 'trust_level', None) if session else None

        async for event in orchestrator.run_streaming(
            message=message,
            session_id=session_id,
            trust_level=trust_level,
        ):
            yield event

    server_ref = SimpleNamespace(
        database=db,
        orchestrator=orchestrator,
        orchestrate=orchestrate,
    )
    init_bots_api(vault_path=settings.vault_path, server_ref=server_ref)

    logger.info("Server ready")

    yield

    # Shutdown
    logger.info("Shutting down...")

    # Stop any running bot connectors
    from parachute.api.bots import _connectors as bot_connectors
    for platform, connector in list(bot_connectors.items()):
        try:
            await connector.stop()
            logger.info(f"Stopped {platform} connector")
        except Exception as e:
            logger.warning(f"Error stopping {platform} connector: {e}")
    bot_connectors.clear()

    await stop_scheduler()
    # CURATOR REMOVED - no curator to stop
    await close_database()
    app.state.orchestrator = None
    app.state.sandbox = None
    app.state.database = None
    app.state.module_loader = None
    app.state.modules = None
    app.state.module_has_router = None
    app.state.scheduler = None
    app.state.server_config = None
    app.state.hook_runner = None


# Create FastAPI application
app = FastAPI(
    title="Parachute Computer",
    description="Modular backend server for Parachute ecosystem - AI agents, session management, and vault operations",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS middleware
# By default, only allow localhost and Parachute app requests
# Configure via CORS_ORIGINS environment variable for additional origins
def _get_cors_origins() -> list[str]:
    """Get CORS origins from settings."""
    settings = get_settings()
    if settings.cors_origins_list is None:
        # Wildcard mode - but we still want some basic protection
        # Allow localhost variants and Parachute app
        return [
            "http://localhost:3333",
            "http://localhost:3336",
            "http://localhost:3337",  # Test server
            "http://127.0.0.1:3333",
            "http://127.0.0.1:3336",
            "http://127.0.0.1:3337",
            # Allow requests from any device on local network with Parachute user-agent
            # The middleware below handles user-agent validation
        ]
    return settings.cors_origins_list


# CORS middleware — standard FastAPI CORSMiddleware handles origin checking and preflights
app.add_middleware(
    CORSMiddleware,
    allow_origins=_get_cors_origins(),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Helper to check if request is from localhost
def _is_localhost(request: Request) -> bool:
    """Check if request originates from localhost."""
    client = request.client
    if not client:
        return False

    host = client.host
    return host in ("127.0.0.1", "::1", "localhost")


# API key authentication with localhost bypass
@app.middleware("http")
async def api_key_middleware(request: Request, call_next):
    server_config = get_server_config()

    # Skip auth for health check and non-API routes
    if request.url.path in ["/api/health", "/"] or not request.url.path.startswith("/api"):
        return await call_next(request)

    # Skip auth for auth management endpoints from localhost (bootstrap case)
    if request.url.path.startswith("/api/auth") and _is_localhost(request):
        return await call_next(request)

    # Determine if auth is required
    if server_config:
        auth_mode = server_config.security.require_auth

        # Disabled mode: no auth required
        if auth_mode == AuthMode.DISABLED:
            return await call_next(request)

        # Remote mode: localhost bypasses auth
        if auth_mode == AuthMode.REMOTE and _is_localhost(request):
            return await call_next(request)

        # Always mode or remote request: check API key
        if server_config.security.api_keys:
            provided_key = (
                request.headers.get("x-api-key")
                or request.headers.get("authorization", "").replace("Bearer ", "")
            )

            if provided_key:
                matched_key = server_config.validate_key(provided_key)
                if matched_key:
                    # Store matched key info in request state for logging
                    request.state.api_key = matched_key
                    return await call_next(request)

            # Key required but not provided or invalid
            return JSONResponse(
                status_code=401,
                content={"error": "Unauthorized", "message": "Valid API key required"},
            )

    # Fallback: check legacy single API key from env var
    settings = get_settings()
    if settings.api_key:
        provided_key = (
            request.headers.get("x-api-key")
            or request.headers.get("authorization", "").replace("Bearer ", "")
        )
        if provided_key != settings.api_key:
            return JSONResponse(
                status_code=401,
                content={"error": "Unauthorized"},
            )

    return await call_next(request)


# Include API routes
app.include_router(api_router)


# Root endpoint
@app.get("/")
async def root():
    """Root endpoint - returns server info."""
    return {
        "name": "Parachute Computer",
        "version": "0.1.0",
        "status": "running",
    }


def main():
    """Main entry point."""
    settings = get_settings()

    # Allow PARACHUTE_PORT env var to override
    port = int(os.environ.get("PARACHUTE_PORT", settings.port))

    print(f"""
===============================================================
          Parachute Computer (Modular Architecture)
===============================================================
  Server:  http://{settings.host}:{port}
  Vault:   {str(settings.vault_path)[:45]}
---------------------------------------------------------------
  API Endpoints:
    GET  /health               - Health check
    GET  /api/modules          - List loaded modules
    POST /api/chat             - Run agent (streaming)
    GET  /api/chat             - List sessions
    GET  /api/chat/:id         - Get session
    DELETE /api/chat/:id       - Delete session
    GET  /api/modules/:mod/prompt   - Get module prompt
    PUT  /api/modules/:mod/prompt   - Update module prompt
===============================================================
    """)

    uvicorn.run(
        app,
        host=settings.host,
        port=port,
        reload=settings.reload,
        log_level=settings.log_level.lower(),
    )


if __name__ == "__main__":
    main()
