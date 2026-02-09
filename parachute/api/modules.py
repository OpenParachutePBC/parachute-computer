"""
Module management API endpoints.

Uses ModuleLoader for real module status instead of hardcoded lists.
Prompt management reads/writes vault/{Module}/CLAUDE.md for system prompts.
"""

import logging
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request

from parachute.config import get_settings
from parachute.models.requests import ModulePromptUpdate

logger = logging.getLogger(__name__)

router = APIRouter()

# Allowlisted module names — only these can be used in path-based endpoints
_ALLOWED_MODULES = {"chat", "daily", "brain", "build"}


def _validate_module_name(mod: str) -> str:
    """Validate and normalize a module name. Raises 404 if not allowlisted."""
    normalized = mod.lower().strip()
    if normalized not in _ALLOWED_MODULES:
        raise HTTPException(404, f"Module '{mod}' not found")
    return normalized.capitalize()


# Default prompt when no CLAUDE.md exists
DEFAULT_PROMPT = """# Parachute Agent

You are an AI companion in Parachute - an open, local-first tool for connected thinking.

## Your Role

You are a **thinking partner and memory extension**. Help the user:
- Think through ideas and problems
- Remember context from past conversations
- Explore topics and make connections
- Find information when they need it
"""


@router.get("/modules")
async def list_modules(request: Request) -> dict[str, Any]:
    """List all loaded modules and their status from ModuleLoader."""
    loader = request.app.state.module_loader
    if loader is None:
        return {"modules": [], "error": "ModuleLoader not initialized"}

    status = loader.get_module_status()

    # Enrich with manifest data from loaded modules
    loaded_modules = request.app.state.modules or {}
    module_has_router = getattr(request.app.state, 'module_has_router', {})
    for entry in status:
        name = entry["name"]
        if name in loaded_modules:
            module = loaded_modules[name]
            manifest = getattr(module, 'manifest', {}) or {}
            entry["version"] = manifest.get("version", "unknown")
            entry["description"] = manifest.get("description", "")
            entry["provides"] = getattr(module, 'provides', [])
            entry["trust_level"] = manifest.get("trust_level", "trusted")
            entry["has_router"] = module_has_router.get(name, False)

    return {"modules": status}


@router.post("/modules/{name}/approve")
async def approve_module(name: str, request: Request) -> dict[str, Any]:
    """Approve a pending module by recording its current hash."""
    loader = request.app.state.module_loader
    if loader is None:
        raise HTTPException(500, "ModuleLoader not initialized")

    result = loader.approve_module(name)
    if not result:
        raise HTTPException(404, f"Module '{name}' not pending approval")

    return {
        "approved": True,
        "name": name,
        "message": "Restart server to load module",
    }


@router.get("/modules/{mod}/prompt")
async def get_module_prompt(mod: str) -> dict[str, Any]:
    """Get system prompt for a module (e.g., Chat/CLAUDE.md)."""
    settings = get_settings()

    module_name = _validate_module_name(mod)
    prompt_path = settings.vault_path / module_name / "CLAUDE.md"

    content = None
    exists = False

    if prompt_path.exists():
        content = prompt_path.read_text(encoding="utf-8")
        exists = True

    return {
        "module": mod,
        "path": f"{module_name}/CLAUDE.md",
        "exists": exists,
        "content": content,
        "defaultPrompt": DEFAULT_PROMPT,
    }


@router.put("/modules/{mod}/prompt")
async def update_module_prompt(mod: str, body: ModulePromptUpdate) -> dict[str, Any]:
    """Update system prompt for a module."""
    settings = get_settings()

    module_name = _validate_module_name(mod)
    prompt_path = settings.vault_path / module_name / "CLAUDE.md"

    if body.reset:
        if prompt_path.exists():
            prompt_path.unlink()
        return {"success": True, "reset": True}

    if body.content is not None:
        prompt_path.parent.mkdir(parents=True, exist_ok=True)
        prompt_path.write_text(body.content, encoding="utf-8")
        return {"success": True, "path": f"{module_name}/CLAUDE.md"}

    raise HTTPException(status_code=400, detail="content or reset required")


@router.get("/modules/{mod}/stats")
async def get_module_stats(mod: str) -> dict[str, Any]:
    """Get file stats for a specific module's vault directory."""
    settings = get_settings()

    module_name = _validate_module_name(mod)
    module_path = settings.vault_path / module_name

    if not module_path.exists():
        raise HTTPException(status_code=404, detail=f"Module '{mod}' not found")

    file_count = 0
    total_size = 0
    for item in module_path.rglob("*"):
        if item.is_file():
            file_count += 1
            total_size += item.stat().st_size

    return {
        "module": mod,
        "fileCount": file_count,
        "totalSize": total_size,
        "hasPrompt": (module_path / "CLAUDE.md").exists(),
    }
