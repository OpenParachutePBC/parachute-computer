"""
Capability filtering for workspaces and trust levels.

Two-stage filtering:
1. Trust-level filter: MCPs annotated with trust_level are only available at
   that trust level or above (sandboxed < vault < full).
2. Workspace filter: applies workspace capability sets ("all"/"none"/[list]).
"""

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Union

from parachute.models.workspace import WorkspaceCapabilities

logger = logging.getLogger(__name__)

# Trust level restrictiveness order: higher number = more restricted
_TRUST_ORDER = {"full": 0, "vault": 1, "sandboxed": 2}


@dataclass
class FilteredCapabilities:
    """Result of filtering capabilities through a workspace config."""

    mcp_servers: dict[str, Any] = field(default_factory=dict)
    plugin_dirs: list[Path] = field(default_factory=list)
    agents: list[str] = field(default_factory=list)
    skills: list[str] = field(default_factory=list)


def filter_by_trust_level(
    mcps: dict[str, Any],
    session_trust: str,
) -> dict[str, Any]:
    """Filter MCPs by trust level compatibility.

    An MCP is available if its declared trust_level is at least as restrictive
    as the session's trust level. For example:
    - MCP with trust_level="sandboxed" is available in all sessions
    - MCP with trust_level="vault" is available in vault and full sessions
    - MCP with trust_level="full" (or no annotation) is only available in full sessions

    Args:
        mcps: MCP server configs (may include a "trust_level" key)
        session_trust: The effective session trust level ("full", "vault", "sandboxed")

    Returns:
        Filtered MCP dict with only trust-compatible servers
    """
    if not mcps:
        return {}

    session_order = _TRUST_ORDER.get(session_trust, 0)
    filtered = {}

    for name, config in mcps.items():
        # MCPs without trust_level default to "full" (most restrictive access)
        mcp_trust = config.get("trust_level", "full")
        mcp_order = _TRUST_ORDER.get(mcp_trust, 0)

        # MCP is available if its trust_level is >= session trust (more or equally restrictive)
        # i.e., an MCP declared "sandboxed" (order=2) is available everywhere
        # because 2 >= any session order
        if mcp_order >= session_order:
            filtered[name] = config
        else:
            logger.debug(
                f"Trust filter: {name} requires {mcp_trust} trust, "
                f"session has {session_trust} — excluded"
            )

    return filtered


def _filter_by_set(
    items: dict[str, Any] | list[str],
    capability_set: Union[str, list[str]],
    label: str,
) -> dict[str, Any] | list[str]:
    """Apply a capability set filter to a collection.

    capability_set:
        "all" → return items unchanged
        "none" → return empty
        [list] → return only items whose name is in the list
    """
    if capability_set == "all":
        return items
    if capability_set == "none":
        return {} if isinstance(items, dict) else []

    # Filter by name list
    allowed = set(capability_set)
    if isinstance(items, dict):
        filtered = {k: v for k, v in items.items() if k in allowed}
    else:
        filtered = [item for item in items if item in allowed]

    removed = (set(items.keys()) if isinstance(items, dict) else set(items)) - allowed
    if removed:
        logger.debug(f"Workspace filtered out {label}: {removed}")

    return filtered


def filter_capabilities(
    capabilities: WorkspaceCapabilities,
    all_mcps: dict[str, Any] | None = None,
    all_skills: list[str] | None = None,
    all_agents: list[str] | None = None,
    plugin_dirs: list[Path] | None = None,
) -> FilteredCapabilities:
    """Apply workspace capability configuration to discovered capabilities.

    "all" = pass everything through (default)
    "none" = empty set
    [list] = only named items
    """
    result = FilteredCapabilities()

    # Filter MCPs
    if all_mcps is not None:
        result.mcp_servers = _filter_by_set(all_mcps, capabilities.mcps, "MCPs")

    # Filter skills
    if all_skills is not None:
        result.skills = _filter_by_set(all_skills, capabilities.skills, "skills")

    # Filter agents
    if all_agents is not None:
        result.agents = _filter_by_set(all_agents, capabilities.agents, "agents")

    # Filter plugins based on workspace plugin config
    if plugin_dirs is not None:
        if capabilities.plugins.include_user:
            result.plugin_dirs = list(plugin_dirs)
        else:
            # Remove user plugin dir (~/.claude/plugins/)
            user_plugins = Path.home() / ".claude" / "plugins"
            result.plugin_dirs = [p for p in plugin_dirs if p != user_plugins]

        # Add workspace-specific plugin dirs
        for pd in capabilities.plugins.dirs:
            p = Path(pd).expanduser()
            if p.is_dir() and p not in result.plugin_dirs:
                result.plugin_dirs.append(p)
            elif not p.is_dir():
                logger.warning(f"Workspace plugin dir does not exist: {pd}")

    return result
