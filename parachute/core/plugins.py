"""
Plugin discovery and indexing.

Discovers installed plugins from:
1. {vault}/.parachute/plugins/  — Parachute-managed plugins (installed via API)
2. ~/.claude/plugins/           — User plugins (shared with Claude Code CLI)

Each plugin must have .claude-plugin/plugin.json to be recognized.
Plugin contents (skills, agents, MCPs) are indexed for capability filtering.
"""

import json
import logging
import re
from pathlib import Path
from typing import Optional

from parachute.models.plugin import InstalledPlugin, PluginManifest

logger = logging.getLogger(__name__)


def discover_plugins(
    vault_path: Path,
    include_user: bool = True,
) -> list[InstalledPlugin]:
    """Discover all installed plugins.

    Args:
        vault_path: Path to the vault directory
        include_user: Whether to include ~/.claude/plugins/

    Returns:
        List of discovered and indexed plugins
    """
    plugins: list[InstalledPlugin] = []

    # 1. Parachute-managed plugins
    plugin_dir = vault_path / ".parachute" / "plugins"
    if plugin_dir.is_dir():
        for entry in sorted(plugin_dir.iterdir()):
            if entry.is_dir() and (entry / ".claude-plugin" / "plugin.json").exists():
                plugin = _index_plugin(entry, source="parachute")
                if plugin:
                    plugins.append(plugin)

    # 2. User plugins (~/.claude/plugins/)
    if include_user:
        user_dir = Path.home() / ".claude" / "plugins"
        if user_dir.is_dir():
            for entry in sorted(user_dir.iterdir()):
                if entry.is_dir() and (entry / ".claude-plugin" / "plugin.json").exists():
                    plugin = _index_plugin(entry, source="user")
                    if plugin:
                        plugins.append(plugin)

    logger.info(f"Discovered {len(plugins)} plugins")
    return plugins


def _index_plugin(path: Path, source: str = "parachute") -> Optional[InstalledPlugin]:
    """Index a single plugin directory.

    Reads the manifest and discovers skills, agents, and MCPs.
    """
    try:
        manifest_path = path / ".claude-plugin" / "plugin.json"
        manifest_data = json.loads(manifest_path.read_text())
        manifest = PluginManifest(**manifest_data)
    except (json.JSONDecodeError, OSError, ValueError) as e:
        logger.warning(f"Failed to read plugin manifest at {path}: {e}")
        return None

    skills = _discover_plugin_skills(path)
    agents = _discover_plugin_agents(path)
    mcps = _discover_plugin_mcps(path)

    # Check for source_url in manifest (set during install)
    source_url = manifest_data.get("source_url")
    installed_at = manifest_data.get("installed_at")

    return InstalledPlugin(
        slug=path.name,
        name=manifest.name or path.name,
        version=manifest.version,
        description=manifest.description,
        author=manifest.author,
        source=source,
        source_url=source_url,
        path=str(path),
        skills=skills,
        agents=agents,
        mcps=mcps,
        installed_at=installed_at,
    )


def _discover_plugin_skills(path: Path) -> list[str]:
    """Discover skill names inside a plugin."""
    skills: list[str] = []
    skills_dir = path / "skills"
    if not skills_dir.is_dir():
        return skills

    for entry in skills_dir.iterdir():
        if entry.is_file() and entry.suffix == ".md":
            # Single-file skill: skills/my-skill.md
            skills.append(entry.stem)
        elif entry.is_dir():
            # Directory skill: skills/my-skill/SKILL.md
            if (entry / "SKILL.md").exists() or (entry / "index.md").exists():
                skills.append(entry.name)

    return sorted(skills)


def _discover_plugin_agents(path: Path) -> list[str]:
    """Discover agent names inside a plugin."""
    agents: list[str] = []
    agents_dir = path / "agents"
    if not agents_dir.is_dir():
        return agents

    for entry in agents_dir.iterdir():
        if entry.is_file() and entry.suffix in (".md", ".yaml", ".yml", ".json"):
            agents.append(entry.stem)

    return sorted(agents)


def _discover_plugin_mcps(path: Path) -> dict:
    """Discover MCP server configs inside a plugin."""
    mcp_json = path / ".mcp.json"
    if not mcp_json.exists():
        return {}

    try:
        data = json.loads(mcp_json.read_text())
        servers = data.get("mcpServers", {})
        if isinstance(servers, dict):
            return servers
    except (json.JSONDecodeError, OSError) as e:
        logger.warning(f"Failed to read plugin MCP config at {mcp_json}: {e}")

    return {}


def get_plugin_dirs(plugins: list[InstalledPlugin]) -> list[Path]:
    """Get plugin directory paths for passing to SDK."""
    return [Path(p.path) for p in plugins]
