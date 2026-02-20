"""
API routes for Parachute server.
"""

from fastapi import APIRouter

from parachute.api import (
    agents, auth, bots, capabilities, chat, claude_code, context_folders,
    filesystem, health, hooks, imports, mcp, models, modules, plugins, prompts,
    sandbox, scheduler, sessions, skills, sync, usage,
    workspaces,
)

# Create main API router
api_router = APIRouter(prefix="/api")

# Include all route modules
api_router.include_router(auth.router, tags=["auth"])
api_router.include_router(health.router, tags=["health"])
api_router.include_router(chat.router, tags=["chat"])
api_router.include_router(sessions.router, tags=["sessions"])
api_router.include_router(models.router, tags=["models"])
api_router.include_router(modules.router, tags=["modules"])
api_router.include_router(filesystem.router, tags=["filesystem"])
api_router.include_router(claude_code.router, tags=["claude-code"])
api_router.include_router(mcp.router, tags=["mcp"])
api_router.include_router(skills.router, tags=["skills"])
api_router.include_router(imports.router, tags=["imports"])
api_router.include_router(prompts.router, tags=["prompts"])
api_router.include_router(context_folders.router, prefix="/contexts", tags=["contexts"])
api_router.include_router(scheduler.router, tags=["scheduler"])
api_router.include_router(sync.router, tags=["sync"])
api_router.include_router(usage.router, tags=["usage"])
api_router.include_router(hooks.router, tags=["hooks"])
api_router.include_router(bots.router, tags=["bots"])
api_router.include_router(sandbox.router, tags=["sandbox"])
api_router.include_router(workspaces.router, tags=["workspaces"])
api_router.include_router(agents.router, tags=["agents"])
api_router.include_router(capabilities.router, tags=["capabilities"])
api_router.include_router(plugins.router, tags=["plugins"])
