"""
Dynamic tool guidance for system prompts.

Generates contextual documentation for MCP tools based on the session's
trust level. This replaces the previously hardcoded tool lists in prompt
constants, ensuring the agent always sees accurate, trust-appropriate
tool documentation with usage guidance.
"""

from __future__ import annotations

from typing import Literal, TypedDict

from parachute.core.capability_filter import TRUST_ORDER, trust_rank


class ToolEntry(TypedDict):
    """A single MCP tool with its name and description."""

    name: str
    description: str


class ToolGroup(TypedDict):
    """A group of related MCP tools with shared trust level and usage guidance."""

    name: str
    trust: Literal["direct", "sandboxed"]
    guidance: str
    tools: list[ToolEntry]


TOOL_GROUPS: list[ToolGroup] = [
    {
        "name": "Memory Search",
        "trust": "sandboxed",
        "guidance": (
            "Search the vault when the user references their own thoughts, projects, "
            "or history, or when personalized context would improve your response."
        ),
        "tools": [
            {
                "name": "search_memory",
                "description": (
                    "Search all memory — chats, exchanges, and journal entries — by keyword. "
                    "Returns ranked results with summaries and matched snippets. "
                    "Use 'source' to narrow to 'journal' or 'chat'. "
                    "Use date_from/date_to to scope by date."
                ),
            },
            {
                "name": "search_chats",
                "description": (
                    "Search chat conversations with matched exchanges inline. "
                    "Use get_exchange to drill into full content."
                ),
            },
        ],
    },
    {
        "name": "Browse",
        "trust": "sandboxed",
        "guidance": (
            "Browse and read past conversations, journal entries, and projects. "
            "Use list_chats to find conversations, get_chat to read one, "
            "and get_exchange for full untruncated content of a specific exchange. "
            "Use list_notes for journal entries."
        ),
        "tools": [
            {
                "name": "list_chats",
                "description": "List recent conversations. Filter by module (chat, daily) or search by keyword.",
            },
            {
                "name": "get_chat",
                "description": (
                    "Get a conversation by ID with its exchanges (truncated). "
                    "Use get_exchange for full content."
                ),
            },
            {
                "name": "get_exchange",
                "description": (
                    "Get a single exchange by ID with full untruncated content. "
                    "Use after search_memory or get_chat identifies a specific exchange."
                ),
            },
            {
                "name": "list_notes",
                "description": "List journal entries. Use date_from/date_to to scope by date, note_type='journal' for Daily entries.",
            },
            {
                "name": "brain_schema",
                "description": "View the brain graph schema — node/relationship tables, columns, and types.",
            },
        ],
    },
    {
        "name": "Sessions & Tags",
        "trust": "sandboxed",
        "guidance": (
            "Look up specific sessions by ID or find sessions by tag. "
            "Tags help organize and retrieve related conversations."
        ),
        "tools": [
            {
                "name": "get_session",
                "description": "Get a specific session by ID with its message history.",
            },
            {
                "name": "search_by_tag",
                "description": "Find all sessions with a specific tag.",
            },
            {
                "name": "list_tags",
                "description": "List all tags with usage counts.",
            },
            {
                "name": "add_session_tag",
                "description": "Add a tag to a session.",
            },
            {
                "name": "remove_session_tag",
                "description": "Remove a tag from a session.",
            },
        ],
    },
    {
        "name": "Multi-Agent",
        "trust": "sandboxed",
        "guidance": (
            "Spawn child sessions. "
            "Child sessions inherit trust level and container environment."
        ),
        "tools": [
            {
                "name": "create_session",
                "description": "Create a child session with a title, agent type, and initial message.",
            },
        ],
    },
    {
        "name": "Raw Queries",
        "trust": "direct",
        "guidance": (
            "Execute Cypher queries directly against the brain graph. "
            "Prefer the structured tools (search_memory, list_chats, etc.) for common use cases. "
            "Call brain_schema first to discover available tables and columns."
        ),
        "tools": [
            {
                "name": "brain_query",
                "description": "Execute a read-only Cypher query against the brain graph.",
            },
            {
                "name": "brain_execute",
                "description": "Execute a write Cypher query (MERGE, CREATE, SET, DELETE).",
            },
        ],
    },
]


def build_tool_guidance(trust_level: str) -> str:
    """Build a markdown section documenting available MCP tools for the given trust level.

    Filters TOOL_GROUPS to include only groups whose trust level is compatible
    with the session's trust level, then formats them as a readable markdown
    section with usage guidance.

    Args:
        trust_level: The session's effective trust level ("direct" or "sandboxed").

    Returns:
        Formatted markdown string, or empty string if no tools match.
    """
    session_order = trust_rank(trust_level)
    sections: list[str] = []

    for group in TOOL_GROUPS:
        group_trust = group["trust"]
        group_order = TRUST_ORDER.get(group_trust, 0)

        # Same logic as capability_filter: group is available if its trust level
        # is at least as restrictive as the session's trust level
        if group_order >= session_order:
            lines = [f"### {group['name']}"]
            lines.append(group["guidance"])
            lines.append("")
            for tool in group["tools"]:
                lines.append(f"- **mcp__parachute__{tool['name']}** — {tool['description']}")
            sections.append("\n".join(lines))

    if not sections:
        return ""

    header = "## Vault Tools (mcp__parachute__*)\n"
    return header + "\n\n".join(sections)
