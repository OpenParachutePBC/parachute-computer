"""
Module management API endpoints.

Modules are top-level directories in the vault (Chat, Daily, Build, etc.)
"""

from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Query

from parachute.config import get_settings
from parachute.models.requests import ModulePromptUpdate

router = APIRouter()

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
async def list_modules() -> dict[str, Any]:
    """
    List all modules and their status.
    """
    settings = get_settings()
    vault_path = settings.vault_path

    known_modules = ["Chat", "Daily", "Build"]
    modules = []

    for module_name in known_modules:
        module_path = vault_path / module_name
        if module_path.exists():
            has_prompt = (module_path / "CLAUDE.md").exists()
            has_sessions = (module_path / "sessions").exists()

            modules.append({
                "name": module_name.lower(),
                "displayName": module_name,
                "exists": True,
                "hasPrompt": has_prompt,
                "hasSessions": has_sessions,
            })

    return {"modules": modules}


@router.get("/modules/{mod}/prompt")
async def get_module_prompt(mod: str) -> dict[str, Any]:
    """
    Get system prompt for a module (e.g., Chat/CLAUDE.md).
    """
    settings = get_settings()

    # Normalize module name
    module_name = mod.capitalize()
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
    """
    Update system prompt for a module.

    Body: { content: string } or { reset: true } to use default
    """
    settings = get_settings()

    module_name = mod.capitalize()
    prompt_path = settings.vault_path / module_name / "CLAUDE.md"

    if body.reset:
        # Delete the file to use default
        if prompt_path.exists():
            prompt_path.unlink()
        return {"success": True, "reset": True}

    if body.content is not None:
        # Ensure module directory exists
        prompt_path.parent.mkdir(parents=True, exist_ok=True)
        prompt_path.write_text(body.content, encoding="utf-8")
        return {"success": True, "path": f"{module_name}/CLAUDE.md"}

    raise HTTPException(status_code=400, detail="content or reset required")


@router.get("/modules/{mod}/search")
async def search_module(
    mod: str,
    q: str = Query(..., description="Search query"),
    limit: int = Query(20, ge=1, le=100),
) -> dict[str, Any]:
    """
    Search module content.

    Query params:
    - q: Search query (required)
    - limit: Maximum results
    """
    # TODO: Implement semantic search with ModuleIndexer
    return {
        "module": mod,
        "query": q,
        "results": [],
        "message": "Search not yet implemented",
    }


@router.post("/modules/{mod}/index")
async def rebuild_module_index(
    mod: str,
    with_embeddings: bool = Query(True, description="Include embeddings"),
) -> dict[str, Any]:
    """
    Rebuild search index for a module.
    """
    # TODO: Implement with ModuleIndexer
    return {
        "success": True,
        "module": mod,
        "message": "Indexing not yet implemented",
    }


@router.get("/modules/{mod}/stats")
async def get_module_stats(mod: str) -> dict[str, Any]:
    """
    Get stats for a specific module.
    """
    settings = get_settings()

    module_name = mod.capitalize()
    module_path = settings.vault_path / module_name

    if not module_path.exists():
        raise HTTPException(status_code=404, detail=f"Module '{mod}' not found")

    # Count files
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
