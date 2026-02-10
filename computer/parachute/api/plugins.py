"""
Plugin management API endpoints.

CRUD operations for plugins installed from GitHub URLs.
Plugins are stored in {vault}/.parachute/plugins/{slug}/.
"""

import logging
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.core.plugins import discover_plugins
from parachute.core.plugin_installer import (
    install_plugin_from_url,
    uninstall_plugin,
    update_plugin,
    check_plugin_update,
)

router = APIRouter()
logger = logging.getLogger(__name__)


class InstallPluginInput(BaseModel):
    """Input for installing a plugin from a URL."""

    url: str
    slug: Optional[str] = None


def _plugin_to_dict(plugin) -> dict[str, Any]:
    """Convert an InstalledPlugin to API response dict."""
    return {
        "slug": plugin.slug,
        "name": plugin.name,
        "version": plugin.version,
        "description": plugin.description,
        "author": plugin.author,
        "source": plugin.source,
        "sourceUrl": plugin.source_url,
        "path": plugin.path,
        "skills": plugin.skills,
        "agents": plugin.agents,
        "mcps": list(plugin.mcps.keys()) if plugin.mcps else [],
        "mcpConfigs": plugin.mcps,
        "installedAt": plugin.installed_at,
    }


@router.get("/plugins")
async def list_plugins(request: Request) -> dict[str, Any]:
    """List all installed plugins."""
    settings = get_settings()
    plugins = discover_plugins(settings.vault_path)
    return {"plugins": [_plugin_to_dict(p) for p in plugins]}


@router.get("/plugins/{slug}")
async def get_plugin(request: Request, slug: str) -> dict[str, Any]:
    """Get details for a specific plugin."""
    settings = get_settings()
    plugins = discover_plugins(settings.vault_path)

    for plugin in plugins:
        if plugin.slug == slug:
            return _plugin_to_dict(plugin)

    raise HTTPException(status_code=404, detail=f"Plugin '{slug}' not found")


@router.post("/plugins/install")
async def install_plugin(request: Request, body: InstallPluginInput) -> dict[str, Any]:
    """Install a plugin from a Git URL."""
    settings = get_settings()

    if not body.url:
        raise HTTPException(status_code=400, detail="URL is required")

    try:
        plugin = await install_plugin_from_url(
            vault_path=settings.vault_path,
            url=body.url,
            slug=body.slug,
        )
        logger.info(f"Installed plugin '{plugin.slug}' from {body.url}")
        return {"success": True, "plugin": _plugin_to_dict(plugin)}

    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.delete("/plugins/{slug}")
async def delete_plugin(request: Request, slug: str) -> dict[str, Any]:
    """Uninstall a plugin. Only removes Parachute-managed plugins."""
    settings = get_settings()

    # Check if it's a user plugin (not deletable from API)
    plugins = discover_plugins(settings.vault_path)
    for plugin in plugins:
        if plugin.slug == slug and plugin.source == "user":
            raise HTTPException(
                status_code=403,
                detail=f"Cannot delete user plugin '{slug}'. Remove it from ~/.claude/plugins/ manually.",
            )

    removed = await uninstall_plugin(settings.vault_path, slug)
    if not removed:
        raise HTTPException(status_code=404, detail=f"Plugin '{slug}' not found")

    return {"success": True, "deleted": slug}


@router.post("/plugins/{slug}/update")
async def update_plugin_endpoint(request: Request, slug: str) -> dict[str, Any]:
    """Pull latest changes for an installed plugin."""
    settings = get_settings()

    try:
        plugin = await update_plugin(settings.vault_path, slug)
        return {"success": True, "plugin": _plugin_to_dict(plugin)}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/plugins/{slug}/check-update")
async def check_plugin_update_endpoint(
    request: Request, slug: str
) -> dict[str, Any]:
    """Check if a newer version is available for a plugin."""
    settings = get_settings()

    result = await check_plugin_update(settings.vault_path, slug)
    if result is None:
        return {"upToDate": True, "slug": slug}

    return {"upToDate": False, "behind": result["behind"], "slug": slug}
