"""
Plugin management API endpoints.

CRUD operations for plugins installed from GitHub URLs.
Plugins are stored in {vault}/.parachute/plugins/{slug}/.
"""

import logging
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from parachute.config import get_settings
from parachute.core.plugins import discover_plugins
import yaml as _yaml
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


def _find_plugin_path(slug: str) -> tuple[Path, Any]:
    """Find a plugin by slug and return (plugin_path, plugin_info)."""
    settings = get_settings()
    plugins = discover_plugins(settings.vault_path)
    for plugin in plugins:
        if plugin.slug == slug:
            return Path(plugin.path), plugin
    raise HTTPException(status_code=404, detail=f"Plugin '{slug}' not found")


def _parse_plugin_skill(skill_path: Path, name: str) -> dict[str, Any]:
    """Parse a plugin skill file, same shape as GET /skills/{name}."""
    content = skill_path.read_text(encoding="utf-8")

    skill_name = name
    description = ""
    version = "1.0.0"
    allowed_tools: list[str] = []
    prompt = content

    if content.startswith("---"):
        parts = content.split("---", 2)
        if len(parts) >= 3:
            frontmatter = parts[1].strip()
            prompt = parts[2].strip()

            for line in frontmatter.split("\n"):
                if ":" in line:
                    key, value = line.split(":", 1)
                    key = key.strip().lower().replace("-", "_")
                    value = value.strip()
                    raw_value = value.strip('"').strip("'")
                    if key == "name":
                        skill_name = raw_value
                    elif key == "description":
                        description = raw_value
                    elif key == "version":
                        version = raw_value
                    elif key == "allowed_tools":
                        if value.startswith("[") and value.endswith("]"):
                            allowed_tools = [
                                t.strip().strip('"').strip("'")
                                for t in value[1:-1].split(",")
                                if t.strip()
                            ]
                        elif raw_value:
                            allowed_tools = [raw_value]

    stat = skill_path.stat()
    is_directory = skill_path.name.upper() in ("SKILL.MD", "INDEX.MD") or skill_path.parent.name != "skills"

    result: dict[str, Any] = {
        "name": skill_name,
        "description": description,
        "content": prompt,
        "size": stat.st_size,
        "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
        "version": version,
        "allowed_tools": allowed_tools,
        "is_directory": is_directory,
        "source": "plugin",
    }

    if is_directory and skill_path.parent.is_dir():
        files = []
        for f in skill_path.parent.iterdir():
            if f.is_file():
                fstat = f.stat()
                files.append({"name": f.name, "size": fstat.st_size})
        files.sort(key=lambda x: x["name"])
        result["files"] = files

    return result


@router.get("/plugins/{slug}/skills/{skill_name:path}")
async def get_plugin_skill(
    request: Request, slug: str, skill_name: str
) -> dict[str, Any]:
    """Get a specific skill from a plugin."""
    plugin_path, _ = _find_plugin_path(slug)
    skills_dir = plugin_path / "skills"

    if not skills_dir.is_dir():
        raise HTTPException(status_code=404, detail=f"Plugin '{slug}' has no skills")

    # Try single file first
    skill_file = skills_dir / f"{skill_name}.md"
    if skill_file.exists():
        return _parse_plugin_skill(skill_file, skill_name)

    # Try directory skill
    skill_dir = skills_dir / skill_name
    if skill_dir.is_dir():
        for candidate in ["SKILL.md", "skill.md", "index.md", f"{skill_name}.md"]:
            skill_file = skill_dir / candidate
            if skill_file.exists():
                return _parse_plugin_skill(skill_file, skill_name)

    # Handle colon-separated names (e.g. "workflows:work")
    if ":" in skill_name:
        parts = skill_name.split(":")
        skill_dir = skills_dir
        for part in parts[:-1]:
            skill_dir = skill_dir / part
        final_name = parts[-1]
        # Try as directory
        final_dir = skill_dir / final_name
        if final_dir.is_dir():
            for candidate in ["SKILL.md", "skill.md", "index.md", f"{final_name}.md"]:
                skill_file = final_dir / candidate
                if skill_file.exists():
                    return _parse_plugin_skill(skill_file, skill_name)
        # Try as file
        skill_file = skill_dir / f"{final_name}.md"
        if skill_file.exists():
            return _parse_plugin_skill(skill_file, skill_name)

    raise HTTPException(
        status_code=404,
        detail=f"Skill '{skill_name}' not found in plugin '{slug}'",
    )


@router.get("/plugins/{slug}/agents/{agent_name:path}")
async def get_plugin_agent(
    request: Request, slug: str, agent_name: str
) -> dict[str, Any]:
    """Get a specific agent from a plugin."""
    plugin_path, _ = _find_plugin_path(slug)
    agents_dir = plugin_path / "agents"

    if not agents_dir.is_dir():
        raise HTTPException(status_code=404, detail=f"Plugin '{slug}' has no agents")

    # Search for agent file by name (supports nested dirs)
    for ext in (".md", ".yaml", ".yml"):
        # Direct file
        agent_file = agents_dir / f"{agent_name}{ext}"
        if agent_file.exists():
            break
        # Recursive search
        for candidate in agents_dir.rglob(f"{agent_name}{ext}"):
            agent_file = candidate
            break
        if agent_file.exists():
            break
    else:
        raise HTTPException(
            status_code=404,
            detail=f"Agent '{agent_name}' not found in plugin '{slug}'",
        )

    # Parse agent file inline (no dependency on core.agents)
    content = agent_file.read_text(encoding="utf-8")
    description = f"Agent: {agent_name}"
    model = None
    tools: list[str] = []
    prompt = content

    if agent_file.suffix == ".md" and content.startswith("---"):
        parts = content.split("---", 2)
        if len(parts) >= 3:
            try:
                data = _yaml.safe_load(parts[1].strip())
                if isinstance(data, dict):
                    description = data.get("description", description)
                    model = data.get("model")
                    tools = data.get("tools", [])
                    if isinstance(tools, str):
                        tools = [t.strip() for t in tools.split(",")]
            except _yaml.YAMLError:
                pass
            prompt = parts[2].strip()
    elif agent_file.suffix in (".yaml", ".yml"):
        data = _yaml.safe_load(content)
        if isinstance(data, dict):
            description = data.get("description", description)
            model = data.get("model")
            tools = data.get("tools", [])
            prompt = data.get("prompt", "")

    if not prompt:
        raise HTTPException(
            status_code=400,
            detail=f"Could not parse agent '{agent_name}' in plugin '{slug}'",
        )

    return {
        "name": agent_name,
        "description": description,
        "type": "chatbot",
        "model": model,
        "path": str(agent_file.relative_to(plugin_path)),
        "source": "plugin",
        "tools": tools,
        "system_prompt": prompt,
        "system_prompt_preview": prompt[:500] if prompt else None,
    }
