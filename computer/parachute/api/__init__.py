"""
API routes for Parachute server.
"""

from fastapi import APIRouter

from parachute.api import chat, sessions, modules, health, filesystem, claude_code, mcp, skills

# Create main API router
api_router = APIRouter(prefix="/api")

# Include all route modules
api_router.include_router(health.router, tags=["health"])
api_router.include_router(chat.router, tags=["chat"])
api_router.include_router(sessions.router, tags=["sessions"])
api_router.include_router(modules.router, tags=["modules"])
api_router.include_router(filesystem.router, tags=["filesystem"])
api_router.include_router(claude_code.router, tags=["claude-code"])
api_router.include_router(mcp.router, tags=["mcp"])
api_router.include_router(skills.router, tags=["skills"])
