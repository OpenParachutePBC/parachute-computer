"""
Capability filtering for workspaces and trust levels.

Two-stage filtering:
1. Trust-level filter: MCPs annotated with trust_level are only available at
   that trust level or above (untrusted < trusted).
2. Workspace filter: applies workspace capability sets ("all"/"none"/[list]).
"""

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Union

from parachute.models.workspace import WorkspaceCapabilities

logger = logging.getLogger(__name__)

# Trust level restrictiveness order: higher number = more restricted
TRUST_ORDER: dict[str, int] = {"trusted": 0, "untrusted": 1}

# Legacy mapping for old trust level values
_LEGACY_TRUST_MAP: dict[str, str] = {"full": "trusted", "vault": "trusted", "sandboxed": "untrusted"}


def trust_rank(level: Any) -> int:
    """Get the numeric rank for a trust level (str or enum with .value)."""
    key = level.value if hasattr(level, "value") else str(level)
    # Map legacy values
    key = _LEGACY_TRUST_MAP.get(key, key)
    return TRUST_ORDER.get(key, 0)


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
    - MCP with trust_level="untrusted" is available in all sessions
    - MCP with trust_level="trusted" (or no annotation) is only available in trusted sessions

    Args:
        mcps: MCP server configs (may include a "trust_level" key)
        session_trust: The effective session trust level ("trusted", "untrusted")

    Returns:
        Filtered MCP dict with only trust-compatible servers
    """
    if not mcps:
        return {}

    # Map legacy session trust values
    mapped_session = _LEGACY_TRUST_MAP.get(session_trust, session_trust)
    session_order = TRUST_ORDER.get(mapped_session, 0)
    filtered = {}

    for name, config in mcps.items():
        # MCPs without trust_level default to "trusted" (most privileged access)
        mcp_trust = config.get("trust_level", "trusted")
        # Map legacy MCP trust annotations
        mcp_trust = _LEGACY_TRUST_MAP.get(mcp_trust, mcp_trust)
        mcp_order = TRUST_ORDER.get(mcp_trust, 0)

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

    # Filter plugins by slug (directory name)
    if plugin_dirs is not None:
        plugin_set = capabilities.plugins
        if plugin_set == "all":
            result.plugin_dirs = list(plugin_dirs)
        elif plugin_set == "none":
            result.plugin_dirs = []
        else:
            # Filter by slug (directory name matches allowed list)
            allowed = set(plugin_set) if isinstance(plugin_set, list) else set()
            result.plugin_dirs = [
                p for p in plugin_dirs if p.name in allowed
            ]
            removed = {p.name for p in plugin_dirs} - allowed
            if removed:
                logger.debug(f"Workspace filtered out plugins: {removed}")

    return result
