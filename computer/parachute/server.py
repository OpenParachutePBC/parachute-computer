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
from parachute.core.context_watches import init_watch_service, stop_watch_service
from parachute.db.database import Database, init_database, close_database
from parachute.lib.logger import setup_logging, get_logger

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

    # Initialize context watch service for AGENTS.md subscriptions
    watch_service = await init_watch_service(settings.vault_path, db)
    app.state.watch_service = watch_service
    logger.info("Context watch service initialized")

    logger.info("Server ready")

    yield

    # Shutdown
    logger.info("Shutting down...")
    await stop_watch_service()
    await stop_curator_service()
    await close_database()
    app.state.orchestrator = None
    app.state.database = None
    app.state.curator = None
    app.state.watch_service = None


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


# Optional API key authentication
@app.middleware("http")
async def api_key_middleware(request: Request, call_next):
    settings = get_settings()

    # Skip auth for health check and static files
    if request.url.path in ["/api/health", "/"] or not request.url.path.startswith("/api"):
        return await call_next(request)

    # Check API key if configured
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
