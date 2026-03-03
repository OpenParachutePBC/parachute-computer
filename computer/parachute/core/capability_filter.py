"""
Capability filtering by trust level.

MCPs annotated with trust_level are only available at that trust level or above
(sandboxed < direct).
"""

import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Trust level restrictiveness order: higher number = more restricted
TRUST_ORDER: dict[str, int] = {"direct": 0, "sandboxed": 1}


def trust_rank(level: Any) -> int:
    """Get the numeric rank for a trust level (str or enum with .value)."""
    from parachute.core.trust import normalize_trust_level

    key = level.value if hasattr(level, "value") else str(level)
    try:
        key = normalize_trust_level(key)
    except ValueError:
        key = "direct"
    return TRUST_ORDER.get(key, 0)


@dataclass
class FilteredCapabilities:
    """Result of filtering capabilities by trust level."""

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
    - MCP with trust_level="direct" (or no annotation) is only available in direct sessions

    Args:
        mcps: MCP server configs (may include a "trust_level" key)
        session_trust: The effective session trust level ("direct", "sandboxed")

    Returns:
        Filtered MCP dict with only trust-compatible servers
    """
    if not mcps:
        return {}

    session_order = trust_rank(session_trust)
    filtered = {}

    for name, config in mcps.items():
        # MCPs without trust_level default to "direct" (most privileged access)
        mcp_trust = config.get("trust_level", "direct")
        mcp_order = trust_rank(mcp_trust)

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
