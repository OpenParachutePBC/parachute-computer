"""
Composable tool registry for Parachute agents.

Maps tool names to factory functions that create SDK tool instances.
Each factory declares what scope keys it needs (e.g., "date", "entry_id").
bind_tools() validates scope and creates only the tools an agent config declares.

Tool implementations live in their domain files:
- daily_agent_tools.py — day-scoped tools (read_days_notes, write_card, etc.)
- triggered_agent_tools.py — note-scoped tools (read_this_note, update_this_note, etc.)
"""

import logging
from pathlib import Path
from typing import Any, Callable

from claude_agent_sdk import SdkMcpTool, create_sdk_mcp_server

logger = logging.getLogger(__name__)

# Tool name → (factory_fn, required_scope_keys)
# factory_fn signature: (graph, scope, agent_name, vault_path) -> SdkMcpTool
ToolFactory = Callable[[Any, dict[str, Any], str, Path], SdkMcpTool]
TOOL_FACTORIES: dict[str, tuple[ToolFactory, frozenset[str]]] = {}


def bind_tools(
    tool_names: list[str],
    scope: dict[str, Any],
    graph: Any,
    agent_name: str,
    vault_path: Path,
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create tools for an agent run by matching declared tools against the registry.

    Validates that scope has the required keys for each declared tool.
    Returns (tools_list, mcp_server_config).

    Raises:
        ValueError: If a tool requires scope keys that aren't present.
        KeyError: If a tool name isn't in the registry.
    """
    tools: list[SdkMcpTool] = []

    for name in tool_names:
        if name not in TOOL_FACTORIES:
            raise KeyError(f"Unknown agent tool '{name}' — not in TOOL_FACTORIES registry")

        factory, required_keys = TOOL_FACTORIES[name]
        missing = required_keys - scope.keys()
        if missing:
            raise ValueError(
                f"Tool '{name}' requires scope keys {required_keys} "
                f"but scope only has {set(scope.keys())} (missing: {missing})"
            )

        tools.append(factory(graph, scope, agent_name, vault_path))

    if not tools:
        logger.warning(f"Agent '{agent_name}' has no tools after bind_tools()")

    server_config = create_sdk_mcp_server(
        name=f"agent_{agent_name}",
        version="1.0.0",
        tools=tools,
    )

    return tools, server_config


# Import tool modules so they register their factories at import time.
# No circular import: these modules import TOOL_FACTORIES from us, not vice versa.
import parachute.core.daily_agent_tools  # noqa: F401
import parachute.core.triggered_agent_tools  # noqa: F401
