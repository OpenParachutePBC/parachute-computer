"""
Day-scoped agent tools.

Tools that operate on a date's worth of data — notes, chat logs, etc.
Each factory creates a single SDK tool bound to scope data via closure.

Also provides create_daily_agent_tools() for backwards compatibility with
the old monolithic tool creation pattern.
"""

import logging
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any, TYPE_CHECKING

from claude_agent_sdk import tool, create_sdk_mcp_server, SdkMcpTool

if TYPE_CHECKING:
    from parachute.core.daily_agent import DailyAgentConfig

logger = logging.getLogger(__name__)


# ── Individual tool factories ─────────────────────────────────────────────────
# Each returns a single SdkMcpTool, bound to scope data via closure.
# Signature: (graph, scope, agent_name, vault_path) -> SdkMcpTool


def _make_read_days_notes(graph: Any, scope: dict, agent_name: str, vault_path: Path) -> SdkMcpTool:
    """Read all notes for a specific date from the graph."""

    @tool(
        "read_days_notes",
        "Read all notes for a specific date. Returns the full content of that day's entries.",
        {"date": str},
    )
    async def read_days_notes(args: dict[str, Any]) -> dict[str, Any]:
        date_str = args.get("date", "").strip()
        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date is required (YYYY-MM-DD format)"}], "is_error": True}

        if graph is None:
            return {"content": [{"type": "text", "text": f"No notes found for {date_str} (graph unavailable)"}]}

        try:
            rows = await graph.execute_cypher(
                "MATCH (e:Note) WHERE e.date = $date "
                "RETURN e.content AS content, e.created_at AS created_at "
                "ORDER BY e.created_at ASC",
                {"date": date_str},
            )
            if not rows:
                return {"content": [{"type": "text", "text": f"No notes found for {date_str}"}]}
            entries_text = "\n\n---\n\n".join(r["content"] for r in rows if r.get("content"))
            return {"content": [{"type": "text", "text": f"# Notes for {date_str}\n\n{entries_text}"}]}
        except Exception as e:
            logger.error(f"Error reading notes from graph: {e}")
            return {"content": [{"type": "text", "text": f"Error reading notes: {e}"}], "is_error": True}

    return read_days_notes


def _make_read_days_chats(graph: Any, scope: dict, agent_name: str, vault_path: Path) -> SdkMcpTool:
    """Read AI chat logs for a specific date from vault files."""
    chat_log_dir = vault_path / "Daily" / "chat-log"

    @tool(
        "read_days_chats",
        "Read AI chat logs for a specific date. Shows what conversations happened with AI assistants that day.",
        {"date": str},
    )
    async def read_days_chats(args: dict[str, Any]) -> dict[str, Any]:
        date_str = args.get("date", "").strip()
        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date is required (YYYY-MM-DD format)"}], "is_error": True}

        chat_log_file = chat_log_dir / f"{date_str}.md"
        if not chat_log_file.exists():
            return {"content": [{"type": "text", "text": f"No chat log found for {date_str}"}]}

        try:
            content = chat_log_file.read_text(encoding="utf-8")
            if len(content) > 10000:
                content = content[:10000] + "\n\n...(truncated - chat log was very long)"
            return {"content": [{"type": "text", "text": f"# Chat Log for {date_str}\n\n{content}"}]}
        except Exception as e:
            logger.error(f"Error reading chat log: {e}")
            return {"content": [{"type": "text", "text": f"Error reading chat log: {e}"}], "is_error": True}

    return read_days_chats


def _make_read_recent_journals(graph: Any, scope: dict, agent_name: str, vault_path: Path) -> SdkMcpTool:
    """Read journal entries from the past N days for context."""

    @tool(
        "read_recent_journals",
        "Read journal entries from the past N days for context. Useful for noticing patterns across days.",
        {"days": int},
    )
    async def read_recent_journals(args: dict[str, Any]) -> dict[str, Any]:
        days_back = min(int(args.get("days", 7)), 30)

        if graph is None:
            return {"content": [{"type": "text", "text": "Graph unavailable — cannot read recent journals"}]}

        today = datetime.now().astimezone().date()
        journals_found = []

        for i in range(1, days_back + 1):
            date = today - timedelta(days=i)
            date_str = date.strftime("%Y-%m-%d")
            try:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note) WHERE e.date = $date "
                    "RETURN e.content AS content ORDER BY e.created_at ASC",
                    {"date": date_str},
                )
                if rows:
                    content = "\n\n".join(r["content"] for r in rows if r.get("content"))
                    if len(content) > 5000:
                        content = content[:5000] + "\n\n...(truncated)"
                    journals_found.append(f"## {date_str}\n\n{content}")
            except Exception:
                continue

        if not journals_found:
            return {"content": [{"type": "text", "text": f"No journals found in the past {days_back} days"}]}

        return {"content": [{"type": "text", "text": f"# Recent Journals ({len(journals_found)} days)\n\n" + "\n\n---\n\n".join(journals_found)}]}

    return read_recent_journals


def _make_read_recent_sessions(graph: Any, scope: dict, agent_name: str, vault_path: Path) -> SdkMcpTool:
    """Read recent AI chat sessions for context from vault files."""
    chat_log_dir = vault_path / "Daily" / "chat-log"

    @tool(
        "read_recent_sessions",
        "Read recent AI chat sessions for context. Returns summaries of recent conversations.",
        {"days": int},
    )
    async def read_recent_sessions(args: dict[str, Any]) -> dict[str, Any]:
        days_back = min(int(args.get("days", 7)), 30)

        today = datetime.now().astimezone().date()
        logs_found = []

        for i in range(1, days_back + 1):
            date = today - timedelta(days=i)
            date_str = date.strftime("%Y-%m-%d")
            log_file = chat_log_dir / f"{date_str}.md"
            if log_file.exists():
                try:
                    content = log_file.read_text(encoding="utf-8")
                    if len(content) > 3000:
                        content = content[:3000] + "\n\n...(truncated)"
                    logs_found.append(f"## {date_str}\n\n{content}")
                except Exception:
                    continue

        if not logs_found:
            return {"content": [{"type": "text", "text": f"No chat logs found in the past {days_back} days"}]}

        return {"content": [{"type": "text", "text": f"# Recent Chat Sessions ({len(logs_found)} days)\n\n" + "\n\n---\n\n".join(logs_found)}]}

    return read_recent_sessions


def _make_write_card(graph: Any, scope: dict, agent_name: str, vault_path: Path) -> SdkMcpTool:
    """Write the agent's output as a Card to the graph."""

    @tool(
        "write_card",
        "Write the agent's output. Saves as a Card in the graph.",
        {"date": str, "content": str},
    )
    async def write_card(args: dict[str, Any]) -> dict[str, Any]:
        date_str = args.get("date", "").strip()
        content = args.get("content", "").strip()

        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date is required"}], "is_error": True}
        if not content:
            return {"content": [{"type": "text", "text": "Error: content is required"}], "is_error": True}
        if graph is None:
            return {"content": [{"type": "text", "text": "Error: graph unavailable — cannot write output"}], "is_error": True}

        # Use display_name from scope if available (set by runner from config)
        display_name = scope.get("display_name", agent_name.replace("-", " ").title())
        card_id = f"{agent_name}:{date_str}"
        generated_at = datetime.now(timezone.utc).isoformat()

        try:
            await graph.execute_cypher(
                "MERGE (c:Card {card_id: $card_id}) "
                "SET c.agent_name = $agent_name, "
                "    c.display_name = $display_name, "
                "    c.content = $content, "
                "    c.generated_at = $generated_at, "
                "    c.status = 'done', "
                "    c.date = $date",
                {
                    "card_id": card_id,
                    "agent_name": agent_name,
                    "display_name": display_name,
                    "content": content,
                    "generated_at": generated_at,
                    "date": date_str,
                },
            )
            logger.info(f"Agent '{agent_name}' wrote Card to graph for {date_str}")
            return {"content": [{"type": "text", "text": f"Successfully wrote output to graph (card_id: {card_id})"}]}
        except Exception as e:
            logger.error(f"Error writing Card to graph: {e}")
            return {"content": [{"type": "text", "text": f"Error writing output: {e}"}], "is_error": True}

    return write_card


# ── Register into shared registry ─────────────────────────────────────────────

from parachute.core.agent_tools import TOOL_FACTORIES  # noqa: E402

TOOL_FACTORIES["read_days_notes"] = (_make_read_days_notes, frozenset({"date"}))
TOOL_FACTORIES["read_days_chats"] = (_make_read_days_chats, frozenset({"date"}))
TOOL_FACTORIES["read_recent_journals"] = (_make_read_recent_journals, frozenset())
TOOL_FACTORIES["read_recent_sessions"] = (_make_read_recent_sessions, frozenset())
TOOL_FACTORIES["write_card"] = (_make_write_card, frozenset())

# Legacy aliases — old tool names still work
TOOL_FACTORIES["read_journal"] = TOOL_FACTORIES["read_days_notes"]
TOOL_FACTORIES["read_chat_log"] = TOOL_FACTORIES["read_days_chats"]


# ── Backwards-compatible monolithic creator ───────────────────────────────────


def create_daily_agent_tools(
    vault_path: Path,
    config: "DailyAgentConfig",
    graph=None,
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create tools for a daily agent (backwards-compatible).

    Delegates to bind_tools() with a day scope built from config.
    Kept for callers that haven't migrated to the unified runner yet.
    """
    from parachute.core.agent_tools import bind_tools

    scope = {
        "date": "",  # Placeholder — actual date comes from the prompt, not tool binding
        "display_name": config.display_name,
    }

    return bind_tools(
        tool_names=config.tools,
        scope=scope,
        graph=graph,
        agent_name=config.name,
        vault_path=vault_path,
    )
