"""
Plugin discovery and indexing.

Discovers installed plugins from:
1. {vault}/.parachute/plugins/  — Parachute-managed plugins (installed via API)
2. ~/.claude/plugins/installed_plugins.json — Claude Code CLI installed plugins
3. ~/.claude/plugins/ top-level dirs — Legacy user plugins (direct placement)

Each plugin must have .claude-plugin/plugin.json to be recognized.
Plugin contents (skills, agents, MCPs) are indexed for capability filtering.
"""

import json
import logging
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
    seen_paths: set[str] = set()  # Deduplicate by path

    # 1. Parachute-managed plugins
    plugin_dir = vault_path / ".parachute" / "plugins"
    if plugin_dir.is_dir():
        for entry in sorted(plugin_dir.iterdir()):
            if entry.is_dir() and (entry / ".claude-plugin" / "plugin.json").exists():
                plugin = _index_plugin(entry, source="parachute")
                if plugin:
                    plugins.append(plugin)
                    seen_paths.add(str(entry.resolve()))

    # 2. Claude Code CLI installed plugins (from installed_plugins.json)
    if include_user:
        cli_plugins = _discover_cli_plugins()
        for plugin in cli_plugins:
            resolved = str(Path(plugin.path).resolve())
            if resolved not in seen_paths:
                plugins.append(plugin)
                seen_paths.add(resolved)

        # 3. Legacy: top-level dirs in ~/.claude/plugins/ with plugin.json
        user_dir = Path.home() / ".claude" / "plugins"
        if user_dir.is_dir():
            for entry in sorted(user_dir.iterdir()):
                if (
                    entry.is_dir()
                    and entry.name not in ("cache", "marketplaces")
                    and (entry / ".claude-plugin" / "plugin.json").exists()
                ):
                    resolved = str(entry.resolve())
                    if resolved not in seen_paths:
                        plugin = _index_plugin(entry, source="user")
                        if plugin:
                            plugins.append(plugin)
                            seen_paths.add(resolved)

    logger.info(f"Discovered {len(plugins)} plugins")
    return plugins


def _discover_cli_plugins() -> list[InstalledPlugin]:
    """Read ~/.claude/plugins/installed_plugins.json to find CLI-installed plugins."""
    manifest_path = Path.home() / ".claude" / "plugins" / "installed_plugins.json"
    if not manifest_path.exists():
        return []

    try:
        data = json.loads(manifest_path.read_text())
    except (json.JSONDecodeError, OSError) as e:
        logger.warning(f"Failed to read installed_plugins.json: {e}")
        return []

    version = data.get("version", 1)
    plugins_map = data.get("plugins", {})
    results: list[InstalledPlugin] = []

    for plugin_key, installs in plugins_map.items():
        if not isinstance(installs, list) or not installs:
            continue

        # Use the first (or most recent) installation entry
        install = installs[0]
        install_path = install.get("installPath")
        if not install_path:
            continue

        path = Path(install_path)
        if not path.is_dir():
            logger.debug(f"CLI plugin path does not exist: {install_path}")
            continue

        # Extract slug from key: "compound-engineering@every-marketplace" → "compound-engineering"
        slug = plugin_key.split("@")[0] if "@" in plugin_key else plugin_key

        plugin = _index_plugin(path, source="cli")
        if plugin:
            plugin.slug = slug
            # Override version from installed_plugins.json if available
            cli_version = install.get("version")
            if cli_version:
                plugin.version = cli_version
            results.append(plugin)

    return results


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
    mcps = _discover_plugin_mcps(path, manifest_data)

    # Check for source_url in manifest (set during install)
    source_url = manifest_data.get("source_url") or manifest_data.get("repository")
    installed_at = manifest_data.get("installed_at")

    return InstalledPlugin(
        slug=path.name,
        name=manifest.name or path.name,
        version=manifest.version,
        description=manifest.description,
        author=manifest.author_name,
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

    for entry in agents_dir.rglob("*.md"):
        # Support nested directories: agents/review/code-reviewer.md
        agents.append(entry.stem)
    for entry in agents_dir.rglob("*.yaml"):
        agents.append(entry.stem)
    for entry in agents_dir.rglob("*.yml"):
        agents.append(entry.stem)

    return sorted(set(agents))


def _discover_plugin_mcps(path: Path, manifest_data: dict = None) -> dict:
    """Discover MCP server configs inside a plugin.

    Checks both .mcp.json file and mcpServers in plugin.json manifest.
    """
    mcps = {}

    # 1. Check .mcp.json file
    mcp_json = path / ".mcp.json"
    if mcp_json.exists():
        try:
            data = json.loads(mcp_json.read_text())
            servers = data.get("mcpServers", {})
            if isinstance(servers, dict):
                mcps.update(servers)
        except (json.JSONDecodeError, OSError) as e:
            logger.warning(f"Failed to read plugin MCP config at {mcp_json}: {e}")

    # 2. Check mcpServers in plugin.json manifest
    if manifest_data and isinstance(manifest_data.get("mcpServers"), dict):
        mcps.update(manifest_data["mcpServers"])

    return mcps


def get_plugin_dirs(plugins: list[InstalledPlugin]) -> list[Path]:
    """Get plugin directory paths for passing to SDK."""
    return [Path(p.path) for p in plugins]
