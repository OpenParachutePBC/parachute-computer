"""
Parachute Base Server

Main FastAPI application entry point.
"""

import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

import uvicorn
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from parachute.api import api_router
from parachute.config import get_settings, Settings
from parachute.core.orchestrator import Orchestrator
from parachute.core.curator_service import init_curator_service, stop_curator_service
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

    logger.info(f"Starting Parachute server...")
    logger.info(f"Vault path: {settings.vault_path}")

    # Ensure vault directories exist
    settings.vault_path.mkdir(parents=True, exist_ok=True)
    (settings.vault_path / ".parachute").mkdir(exist_ok=True)

    # Initialize server config (API keys, auth settings)
    server_config = init_server_config(settings.vault_path)
    app.state.server_config = server_config
    logger.info(f"Auth mode: {server_config.security.require_auth.value}")
    logger.info(f"API keys configured: {len(server_config.security.api_keys)}")

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
    app.state.database = db

    # Initialize curator service for background title/context updates
    curator = await init_curator_service(db, settings.vault_path)
    app.state.curator = curator
    logger.info("Curator service initialized")

    # Initialize scheduler for automated tasks (daily curator at 3am, etc.)
    scheduler = await init_scheduler(settings.vault_path)
    app.state.scheduler = scheduler
    logger.info("Scheduler initialized")

    logger.info("Server ready")

    yield

    # Shutdown
    logger.info("Shutting down...")
    await stop_scheduler()
    await stop_curator_service()
    await close_database()
    app.state.orchestrator = None
    app.state.database = None
    app.state.curator = None
    app.state.scheduler = None
    app.state.server_config = None


def get_orchestrator() -> Orchestrator:
    """Get the orchestrator from app state. For use in route handlers."""
    # This is a convenience function that will be called from request context
    # We'll need to use request.app.state.orchestrator in actual routes
    raise RuntimeError(
        "get_orchestrator() should not be called directly. "
        "Use request.app.state.orchestrator instead."
    )


# Create FastAPI application
app = FastAPI(
    title="Parachute Base Server",
    description="Backend server for Parachute ecosystem - AI agents, session management, and vault operations",
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
            "http://localhost:3334",  # Test server
            "http://127.0.0.1:3333",
            "http://127.0.0.1:3334",
            # Allow requests from any device on local network with Parachute user-agent
            # The middleware below handles user-agent validation
        ]
    return settings.cors_origins_list


# Custom CORS middleware that also validates User-Agent for app identification
@app.middleware("http")
async def cors_with_app_validation(request: Request, call_next):
    """CORS middleware with Parachute app identification.

    In addition to standard CORS origin checking, this middleware:
    - Allows requests with User-Agent containing 'Parachute' from any origin
    - Provides a way for the mobile app to identify itself
    """
    origin = request.headers.get("origin", "")
    user_agent = request.headers.get("user-agent", "")

    # Check if this is a Parachute app request (identified by User-Agent)
    is_parachute_app = "Parachute" in user_agent

    response = await call_next(request)

    # Set CORS headers based on validation
    if is_parachute_app:
        # Trust Parachute app requests from any origin
        response.headers["Access-Control-Allow-Origin"] = origin or "*"
        response.headers["Access-Control-Allow-Credentials"] = "true"
        response.headers["Access-Control-Allow-Methods"] = "*"
        response.headers["Access-Control-Allow-Headers"] = "*"
    elif origin:
        cors_origins = _get_cors_origins()
        if origin in cors_origins:
            response.headers["Access-Control-Allow-Origin"] = origin
            response.headers["Access-Control-Allow-Credentials"] = "true"
            response.headers["Access-Control-Allow-Methods"] = "*"
            response.headers["Access-Control-Allow-Headers"] = "*"

    return response


# Also keep standard CORS for preflight requests
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
        "name": "Parachute Base Server",
        "version": "0.1.0",
        "status": "running",
    }


def main():
    """Main entry point."""
    settings = get_settings()

    print(f"""
╔═══════════════════════════════════════════════════════════════╗
║           🪂 Parachute Base Server (Python)                   ║
╠═══════════════════════════════════════════════════════════════╣
║  Server:  http://{settings.host}:{settings.port:<37}║
║  Vault:   {str(settings.vault_path)[:45]:<45}║
╠═══════════════════════════════════════════════════════════════╣
║  API Endpoints:                                               ║
║    POST /api/chat             - Run agent (streaming)         ║
║    GET  /api/chat             - List sessions                 ║
║    GET  /api/chat/:id         - Get session                   ║
║    DELETE /api/chat/:id       - Delete session                ║
║    GET  /api/modules/:mod/prompt   - Get module prompt        ║
║    PUT  /api/modules/:mod/prompt   - Update module prompt     ║
║    GET  /api/modules/:mod/search   - Search module            ║
╚═══════════════════════════════════════════════════════════════╝
    """)

    uvicorn.run(
        app,
        host=settings.host,
        port=settings.port,
        reload=settings.reload,
        log_level=settings.log_level.lower(),
    )


if __name__ == "__main__":
    main()
