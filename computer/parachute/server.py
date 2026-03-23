"""
Parachute Computer Server

Main FastAPI application entry point with modular architecture.
Discovers and loads modules from vault/.modules/ directory.
"""

import asyncio
import logging
import os
from contextlib import asynccontextmanager

# Ensure SSL certificates are available on macOS (Python.org builds lack system certs)
if not os.environ.get("SSL_CERT_FILE"):
    try:
        import certifi
        os.environ["SSL_CERT_FILE"] = certifi.where()
    except ImportError:
        pass
from pathlib import Path
from typing import Optional

import uvicorn
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from parachute import __version__
from parachute.api import api_router
from parachute.config import get_settings, Settings
from parachute.core.module_loader import ModuleLoader
from parachute.core.orchestrator import Orchestrator
from parachute.core.scheduler import init_scheduler, stop_scheduler
from parachute.db.brain_chat_store import BrainChatStore
from parachute.db.brain import BrainService
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
    logger.info(f"Parachute dir: {settings.parachute_dir}")

    # Ensure system directories exist
    settings.parachute_dir.mkdir(parents=True, exist_ok=True)
    settings.sessions_dir.mkdir(exist_ok=True)
    settings.modules_dir.mkdir(exist_ok=True)
    (settings.parachute_dir / "graph").mkdir(exist_ok=True)
    settings.log_dir.mkdir(exist_ok=True)

    # Initialize server config (API keys, auth settings)
    server_config = init_server_config(settings.parachute_dir)
    app.state.server_config = server_config
    logger.info(f"Auth mode: {server_config.security.require_auth.value}")
    logger.info(f"API keys configured: {len(server_config.security.api_keys)}")
    logger.info(f"Claude token: {'configured' if settings.claude_code_oauth_token else 'not set (run `claude setup-token`)'}")

    # Initialize brain database (Kuzu/LadybugDB) (must come before orchestrator — sessions live here)
    brain = BrainService(db_path=settings.brain_db_path)
    await brain.connect()

    # Initialize brain-backed session store and register schema
    session_store = BrainChatStore(brain)
    await session_store.ensure_schema()
    await session_store.seed_builtin_agents()
    app.state.brain = brain
    app.state.session_store = session_store
    from parachute.core.interfaces import get_registry
    get_registry().publish("BrainDB", brain)
    get_registry().publish("ChatStore", session_store)
    await brain.start_checkpoint_loop()
    logger.info(f"BrainDB initialized: {settings.brain_db_path}")

    # Initialize orchestrator and store in app.state
    orchestrator = Orchestrator(
        parachute_dir=settings.parachute_dir,
        session_store=session_store,
        settings=settings,
    )
    app.state.orchestrator = orchestrator
    app.state.sandbox = orchestrator.sandbox  # Shared DockerSandbox for health checks
    get_registry().publish("DockerSandbox", orchestrator.sandbox)

    # Discover existing persistent container env containers
    await orchestrator.reconcile_containers()

    # Initialize transcription service (optional — skip if backend not available)
    from parachute.core.transcription import TranscriptionService

    _transcription_service = TranscriptionService.from_config(settings)
    if _transcription_service:
        try:
            await _transcription_service.initialize()
            get_registry().publish("TranscriptionService", _transcription_service)
            logger.info("Transcription service initialized")
        except Exception as e:
            logger.warning(f"Transcription service failed to initialize: {e}")
            _transcription_service = None
    else:
        logger.info("Transcription service: no backend available, skipping")

    # Load modules from ~/.parachute/modules/
    module_loader = ModuleLoader(settings.parachute_dir)
    modules = await module_loader.discover_and_load()
    app.state.module_loader = module_loader
    app.state.modules = modules
    logger.info(f"Loaded {len(modules)} modules: {list(modules.keys())}")

    # Initialize scheduler after modules so Agent nodes are migrated first
    from parachute.core.interfaces import get_registry
    graph = get_registry().get("BrainDB")
    scheduler = await init_scheduler(settings.parachute_dir, graph=graph)
    app.state.scheduler = scheduler
    logger.info("Scheduler initialized")

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
        hook_runner = HookRunner(settings.parachute_dir)
        await hook_runner.discover()
        init_hooks_api(hook_runner)
        app.state.hook_runner = hook_runner
        logger.info(f"Hooks: {len(hook_runner.get_registered_hooks())} hooks discovered")
    except Exception as e:
        logger.warning(f"Failed to initialize hooks: {e}")
        app.state.hook_runner = None

    # Initialize bots API (pass server_ref with database for connector sessions)
    from parachute.api.bots import init_bots_api, auto_start_connectors
    from types import SimpleNamespace

    async def orchestrate(session_id, message, source="bot"):
        """Wrapper that bridges connector call signature to orchestrator.run_streaming().

        Connectors call: orchestrate(session_id, message, source)
        Orchestrator expects: run_streaming(message, session_id, ..., trust_level)
        """
        session = await session_store.get_session(session_id)
        trust_level = getattr(session, 'trust_level', None) if session else None

        async for event in orchestrator.run_streaming(
            message=message,
            session_id=session_id,
            trust_level=trust_level,
        ):
            yield event

    async def transcribe_audio(audio_data) -> str:
        """Transcribe audio for bot connectors.

        Accepts either raw bytes or a file path string.
        """
        ts = get_registry().get("TranscriptionService")
        if not ts:
            raise RuntimeError("Transcription service not available")
        if isinstance(audio_data, (bytes, bytearray)):
            return await ts.transcribe_bytes(audio_data)
        return await ts.transcribe(Path(audio_data))

    server_ref = SimpleNamespace(
        session_store=session_store,
        orchestrator=orchestrator,
        orchestrate=orchestrate,
        hook_runner=app.state.hook_runner,
        transcribe_audio=transcribe_audio,
    )
    init_bots_api(parachute_dir=settings.parachute_dir, server_ref=server_ref)

    # Auto-start enabled bot connectors (errors logged, never crash server)
    await auto_start_connectors()

    # Initialize MCP HTTP bridge for sandbox containers
    from parachute.lib.sandbox_tokens import SandboxTokenStore
    from parachute.api.mcp_bridge import (
        create_mcp_server,
        create_session_manager,
        create_mcp_asgi_app,
    )

    token_store = SandboxTokenStore()
    app.state.sandbox_token_store = token_store
    get_registry().publish("SandboxTokenStore", token_store)

    mcp_server = create_mcp_server()
    mcp_session_manager = create_session_manager(mcp_server)
    # StreamableHTTPSessionManager.run() returns an async context manager.
    # We call __aenter__/__aexit__ manually because FastAPI's lifespan is
    # itself a context manager — we can't nest `async with` across the yield.
    mcp_run_ctx = mcp_session_manager.run()
    await mcp_run_ctx.__aenter__()
    app.state.mcp_session_manager = mcp_session_manager
    app.state.mcp_run_ctx = mcp_run_ctx

    mcp_asgi_app = create_mcp_asgi_app(mcp_session_manager, token_store)
    app.mount("/mcp/v1", mcp_asgi_app)
    logger.info("MCP HTTP bridge mounted at /mcp/v1")

    logger.info("Server ready")

    yield

    # Shutdown
    logger.info("Shutting down...")

    # Shut down transcription service (waits for in-flight work)
    ts = get_registry().get("TranscriptionService")
    if ts and hasattr(ts, "shutdown"):
        try:
            await ts.shutdown()
        except Exception as e:
            logger.warning(f"Error shutting down transcription service: {e}")

    # Stop all running env containers so they don't idle between restarts.
    # They restart cleanly on next ensure_container() call via docker start.
    if app.state.sandbox:
        try:
            await app.state.sandbox.stop_all_env_containers()
        except Exception as e:
            logger.warning(f"Error stopping env containers on shutdown: {e}")

    # Stop any running bot connectors
    from parachute.api.bots import _connectors as bot_connectors
    for platform, connector in list(bot_connectors.items()):
        try:
            await connector.stop()
            logger.info(f"Stopped {platform} connector")
        except Exception as e:
            logger.warning(f"Error stopping {platform} connector: {e}")
    bot_connectors.clear()

    # Clean up any remaining pending permissions before shutdown
    if app.state.orchestrator:
        for session_id, handler in list(app.state.orchestrator.pending_permissions.items()):
            try:
                handler.cleanup()
            except Exception as e:
                logger.warning("Error cleaning permissions for %s during shutdown: %s", session_id, e)
        app.state.orchestrator.pending_permissions.clear()

    # Close credential broker HTTP clients
    try:
        from parachute.lib.credentials import get_broker
        broker = get_broker()
        await broker.close_all()
    except Exception as e:
        logger.warning(f"Error closing credential broker: {e}")

    # Shut down MCP HTTP bridge
    if hasattr(app.state, "mcp_run_ctx") and app.state.mcp_run_ctx is not None:
        try:
            await app.state.mcp_run_ctx.__aexit__(None, None, None)
        except Exception as e:
            logger.warning(f"Error shutting down MCP bridge: {e}")
        app.state.mcp_run_ctx = None
        app.state.mcp_session_manager = None
        app.state.sandbox_token_store = None

    await stop_scheduler()
    if hasattr(app.state, "brain") and app.state.brain:
        await app.state.brain.close()
        app.state.brain = None
    app.state.orchestrator = None
    app.state.sandbox = None
    app.state.session_store = None
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
    version=__version__,
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
            "http://localhost:3337",  # Test server
            "http://127.0.0.1:3333",
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

    # Skip auth for static asset endpoints (audio/image files).
    # Native media players (ExoPlayer, AVPlayer) can't send custom auth headers.
    if "/assets/" in request.url.path:
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
        "version": __version__,
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
  Data:    {str(settings.parachute_dir)[:45]}
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
