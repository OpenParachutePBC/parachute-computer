"""
Plugin discovery and indexing.

Discovers installed plugins from:
1. Install manifests in {vault}/.parachute/plugin-manifests/ — manifest-based (new)
2. {vault}/.parachute/plugins/ — legacy Parachute-managed plugins (backwards compat)
3. ~/.claude/plugins/installed_plugins.json — Claude Code CLI installed plugins

Plugin contents (skills, agents, MCPs) are tracked in install manifests rather
than discovered by recursive directory scanning.
"""

import json
import logging
from pathlib import Path
from typing import Optional

from parachute.core.plugin_installer import list_install_manifests
from parachute.models.plugin import InstalledPlugin

logger = logging.getLogger(__name__)


def discover_plugins(
    vault_path: Path,
    include_user: bool = True,
) -> list[InstalledPlugin]:
    """Discover all installed plugins.

    Primary source: install manifests in plugin-manifests/.
    Fallback: legacy .parachute/plugins/ directories and CLI plugins.

    Args:
        vault_path: Path to the vault directory
        include_user: Whether to include ~/.claude/plugins/

    Returns:
        List of discovered plugins
    """
    plugins: list[InstalledPlugin] = []
    seen_slugs: set[str] = set()

    # 1. Manifest-based plugins (new install format)
    for manifest in list_install_manifests(vault_path):
        slug = manifest.get("slug", "")
        if not slug:
            continue

        installed_files = manifest.get("installed_files", {})
        plugins.append(InstalledPlugin(
            slug=slug,
            name=manifest.get("name", slug),
            version=manifest.get("version", "0.0.0"),
            description=manifest.get("description", ""),
            author=manifest.get("author"),
            source="parachute",
            source_url=manifest.get("source_url"),
            path=str(vault_path / ".parachute" / "plugin-manifests" / f"{slug}.json"),
            skills=_extract_skill_names(installed_files.get("skills", [])),
            agents=_extract_agent_names(installed_files.get("agents", [])),
            mcps={name: {} for name in installed_files.get("mcps", [])},
            installed_at=manifest.get("installed_at"),
        ))
        seen_slugs.add(slug)

    # 2. Legacy: .parachute/plugins/ directories (backwards compat)
    legacy_dir = vault_path / ".parachute" / "plugins"
    if legacy_dir.is_dir():
        for entry in sorted(legacy_dir.iterdir()):
            if entry.is_dir() and entry.name not in seen_slugs:
                plugin = _index_legacy_plugin(entry, source="parachute")
                if plugin:
                    plugins.append(plugin)
                    seen_slugs.add(plugin.slug)

    # 3. Claude Code CLI installed plugins
    if include_user:
        cli_plugins = _discover_cli_plugins()
        for plugin in cli_plugins:
            if plugin.slug not in seen_slugs:
                plugins.append(plugin)
                seen_slugs.add(plugin.slug)

    logger.info(f"Discovered {len(plugins)} plugins")
    return plugins


def _extract_skill_names(skill_paths: list[str]) -> list[str]:
    """Extract skill names from installed file paths."""
    names: list[str] = []
    for path in skill_paths:
        # ".skills/plugin-foo-my-skill.md" → "plugin-foo-my-skill"
        # ".skills/plugin-foo-my-skill/" → "plugin-foo-my-skill"
        name = Path(path).stem if path.endswith(".md") else Path(path.rstrip("/")).name
        names.append(name)
    return sorted(names)


def _extract_agent_names(agent_paths: list[str]) -> list[str]:
    """Extract agent names from installed file paths."""
    return sorted(Path(p).stem for p in agent_paths)


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

    plugins_map = data.get("plugins", {})
    results: list[InstalledPlugin] = []

    for plugin_key, installs in plugins_map.items():
        if not isinstance(installs, list) or not installs:
            continue

        install = installs[0]
        install_path = install.get("installPath")
        if not install_path:
            continue

        path = Path(install_path)
        if not path.is_dir():
            logger.debug(f"CLI plugin path does not exist: {install_path}")
            continue

        slug = plugin_key.split("@")[0] if "@" in plugin_key else plugin_key

        plugin = _index_legacy_plugin(path, source="cli")
        if plugin:
            plugin.slug = slug
            cli_version = install.get("version")
            if cli_version:
                plugin.version = cli_version
            results.append(plugin)

    return results


def _index_legacy_plugin(path: Path, source: str = "parachute") -> Optional[InstalledPlugin]:
    """Index a legacy plugin directory (with .claude-plugin/plugin.json or SDK-layout).

    Supports both old .claude-plugin/plugin.json format and SDK-layout plugins.
    """
    # Try .claude-plugin/plugin.json first (legacy format)
    manifest_path = path / ".claude-plugin" / "plugin.json"
    name = path.name
    version = "0.0.0"
    description = ""
    author = None
    source_url = None
    installed_at = None

    if manifest_path.exists():
        try:
            manifest_data = json.loads(manifest_path.read_text())
            name = manifest_data.get("name") or name
            version = manifest_data.get("version", version)
            description = manifest_data.get("description", "")
            a = manifest_data.get("author")
            if isinstance(a, str):
                author = a
            elif isinstance(a, dict):
                author = a.get("name")
            source_url = manifest_data.get("source_url") or manifest_data.get("repository")
            installed_at = manifest_data.get("installed_at")
        except (json.JSONDecodeError, OSError, ValueError):
            pass
    else:
        # Try root plugin.json (SDK-layout)
        root_manifest = path / "plugin.json"
        if root_manifest.exists():
            try:
                data = json.loads(root_manifest.read_text())
                name = data.get("name") or name
                version = data.get("version", version)
                description = data.get("description", "")
                a = data.get("author")
                if isinstance(a, str):
                    author = a
                elif isinstance(a, dict):
                    author = a.get("name")
            except (json.JSONDecodeError, OSError):
                pass

    # Scan content
    skills = _discover_plugin_skills(path)
    agents = _discover_plugin_agents(path)
    mcps = _discover_plugin_mcps(path)

    # Must have at least something recognizable
    if not skills and not agents and not mcps and not manifest_path.exists():
        return None

    return InstalledPlugin(
        slug=path.name,
        name=name,
        version=version,
        description=description,
        author=author,
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
            skills.append(entry.stem)
        elif entry.is_dir():
            if (entry / "SKILL.md").exists() or (entry / "index.md").exists():
                skills.append(entry.name)

    return sorted(skills)


def _discover_plugin_agents(path: Path) -> list[str]:
    """Discover agent names inside a plugin."""
    agents: list[str] = []

    # Check SDK-layout .claude/agents/
    agents_dir = path / ".claude" / "agents"
    if not agents_dir.is_dir():
        # Fallback to legacy agents/ directory
        agents_dir = path / "agents"
    if not agents_dir.is_dir():
        return agents

    for entry in agents_dir.rglob("*.md"):
        agents.append(entry.stem)
    for entry in agents_dir.rglob("*.yaml"):
        agents.append(entry.stem)
    for entry in agents_dir.rglob("*.yml"):
        agents.append(entry.stem)

    return sorted(set(agents))


def _discover_plugin_mcps(path: Path) -> dict:
    """Discover MCP server configs inside a plugin."""
    mcps = {}

    mcp_json = path / ".mcp.json"
    if mcp_json.exists():
        try:
            data = json.loads(mcp_json.read_text())
            servers = data.get("mcpServers", {})
            if isinstance(servers, dict):
                mcps.update(servers)
        except (json.JSONDecodeError, OSError) as e:
            logger.warning(f"Failed to read plugin MCP config at {mcp_json}: {e}")

    return mcps


def get_plugin_dirs(plugins: list[InstalledPlugin]) -> list[Path]:
    """Get plugin directory paths for passing to SDK.

    Only returns paths for legacy plugins that are actual directories on disk.
    Manifest-based plugins don't need directory passing — their content is
    already in vault standard locations.
    """
    dirs: list[Path] = []
    for p in plugins:
        path = Path(p.path)
        # Skip manifest-based plugins (path points to manifest JSON, not a dir)
        if path.suffix == ".json":
            continue
        if path.is_dir():
            dirs.append(path)
    return dirs
