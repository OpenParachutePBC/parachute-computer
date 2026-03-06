"""
Generic Daily Agent Tools.

These tools can be used by any daily agent:
- read_journal: Read journal entries for a specific date from the graph
- read_chat_log: Read AI chat logs for a specific date from vault files
- read_recent_journals: Read recent journal entries from the graph
- read_recent_sessions: Read recent AI chat sessions from vault files
- write_output: Write the agent's output as a Card to the graph

Uses the claude-agent-sdk's in-process MCP server.
"""

import logging
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any, TYPE_CHECKING

from claude_agent_sdk import tool, create_sdk_mcp_server, SdkMcpTool

if TYPE_CHECKING:
    from parachute.core.daily_agent import DailyAgentConfig

logger = logging.getLogger(__name__)


def create_daily_agent_tools(
    vault_path: Path,
    config: "DailyAgentConfig",
    graph=None,
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create tools for a daily agent.

    Args:
        vault_path: Path to the vault (used only for chat-log vault reads)
        config: Agent configuration
        graph: GraphDB instance (required for read_journal and write_output)

    Returns:
        Tuple of (list of SdkMcpTool instances, server config dict)
    """
    chat_log_dir = vault_path / "Daily" / "chat-log"

    @tool(
        "read_journal",
        "Read journal entries for a specific date. Returns the full content of that day's journal.",
        {"date": str}
    )
    async def read_journal(args: dict[str, Any]) -> dict[str, Any]:
        """Read journal entries for a date from the graph."""
        date_str = args.get("date", "").strip()

        if not date_str:
            return {
                "content": [{"type": "text", "text": "Error: date is required (YYYY-MM-DD format)"}],
                "is_error": True
            }

        if graph is None:
            return {
                "content": [{"type": "text", "text": f"No journal found for {date_str} (graph unavailable)"}]
            }

        try:
            rows = await graph.execute_cypher(
                "MATCH (e:Note) WHERE e.date = $date "
                "RETURN e.content AS content, e.created_at AS created_at "
                "ORDER BY e.created_at ASC",
                {"date": date_str}
            )
            if not rows:
                return {
                    "content": [{"type": "text", "text": f"No journal found for {date_str}"}]
                }
            entries_text = "\n\n---\n\n".join(
                r["content"] for r in rows if r.get("content")
            )
            return {
                "content": [{"type": "text", "text": f"# Journal for {date_str}\n\n{entries_text}"}]
            }
        except Exception as e:
            logger.error(f"Error reading journal from graph: {e}")
            return {
                "content": [{"type": "text", "text": f"Error reading journal: {e}"}],
                "is_error": True
            }

    @tool(
        "read_chat_log",
        "Read AI chat logs for a specific date. Shows what conversations happened with AI assistants that day.",
        {"date": str}
    )
    async def read_chat_log(args: dict[str, Any]) -> dict[str, Any]:
        """Read chat logs for a date from vault files."""
        date_str = args.get("date", "").strip()

        if not date_str:
            return {
                "content": [{"type": "text", "text": "Error: date is required (YYYY-MM-DD format)"}],
                "is_error": True
            }

        chat_log_file = chat_log_dir / f"{date_str}.md"

        if not chat_log_file.exists():
            return {
                "content": [{"type": "text", "text": f"No chat log found for {date_str}"}]
            }

        try:
            content = chat_log_file.read_text(encoding="utf-8")
            # Truncate if very long
            if len(content) > 10000:
                content = content[:10000] + "\n\n...(truncated - chat log was very long)"
            return {
                "content": [{"type": "text", "text": f"# Chat Log for {date_str}\n\n{content}"}]
            }
        except Exception as e:
            logger.error(f"Error reading chat log: {e}")
            return {
                "content": [{"type": "text", "text": f"Error reading chat log: {e}"}],
                "is_error": True
            }

    @tool(
        "read_recent_journals",
        "Read journal entries from the past N days for context. Useful for noticing patterns across days.",
        {"days": int}
    )
    async def read_recent_journals(args: dict[str, Any]) -> dict[str, Any]:
        """Read recent journal entries from the graph."""
        days_back = args.get("days", 7)
        days_back = min(int(days_back), 30)  # Cap at 30 days

        if graph is None:
            return {
                "content": [{"type": "text", "text": "Graph unavailable — cannot read recent journals"}]
            }

        today = datetime.now().astimezone().date()
        journals_found = []

        for i in range(1, days_back + 1):
            date = today - timedelta(days=i)
            date_str = date.strftime("%Y-%m-%d")

            try:
                rows = await graph.execute_cypher(
                    "MATCH (e:Note) WHERE e.date = $date "
                    "RETURN e.content AS content ORDER BY e.created_at ASC",
                    {"date": date_str}
                )
                if rows:
                    content = "\n\n".join(r["content"] for r in rows if r.get("content"))
                    if len(content) > 5000:
                        content = content[:5000] + "\n\n...(truncated)"
                    journals_found.append(f"## {date_str}\n\n{content}")
            except Exception:
                continue

        if not journals_found:
            return {
                "content": [{"type": "text", "text": f"No journals found in the past {days_back} days"}]
            }

        return {
            "content": [{
                "type": "text",
                "text": f"# Recent Journals ({len(journals_found)} days)\n\n" + "\n\n---\n\n".join(journals_found)
            }]
        }

    @tool(
        "read_recent_sessions",
        "Read recent AI chat sessions for context. Returns summaries of recent conversations.",
        {"days": int}
    )
    async def read_recent_sessions(args: dict[str, Any]) -> dict[str, Any]:
        """Read recent chat sessions from vault files."""
        days_back = args.get("days", 7)
        days_back = min(int(days_back), 30)

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
            return {
                "content": [{"type": "text", "text": f"No chat logs found in the past {days_back} days"}]
            }

        return {
            "content": [{
                "type": "text",
                "text": f"# Recent Chat Sessions ({len(logs_found)} days)\n\n" + "\n\n---\n\n".join(logs_found)
            }]
        }

    @tool(
        "write_output",
        "Write the agent's output. Saves as a Card in the graph.",
        {"date": str, "content": str}
    )
    async def write_output(args: dict[str, Any]) -> dict[str, Any]:
        """Write the agent's output as a Card to the graph."""
        date_str = args.get("date", "").strip()
        content = args.get("content", "").strip()

        if not date_str:
            return {
                "content": [{"type": "text", "text": "Error: date is required"}],
                "is_error": True
            }

        if not content:
            return {
                "content": [{"type": "text", "text": "Error: content is required"}],
                "is_error": True
            }

        if graph is None:
            return {
                "content": [{"type": "text", "text": "Error: graph unavailable — cannot write output"}],
                "is_error": True
            }

        card_id = f"{config.name}:{date_str}"
        generated_at = datetime.now(timezone.utc).isoformat()

        try:
            # Upsert Card — MERGE is idempotent (re-run for same date updates the card)
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
                    "agent_name": config.name,
                    "display_name": config.display_name,
                    "content": content,
                    "generated_at": generated_at,
                    "date": date_str,
                },
            )

            # Link to Day node (MERGE Day for idempotency)
            await graph.execute_cypher(
                "MERGE (d:Day {date: $date}) "
                "WITH d "
                "MATCH (c:Card {card_id: $card_id}) "
                "MERGE (d)-[:HAS_CARD]->(c)",
                {"date": date_str, "card_id": card_id},
            )

            logger.info(f"Agent '{config.name}' wrote Card to graph for {date_str}")
            return {
                "content": [{"type": "text", "text": f"Successfully wrote output to graph (card_id: {card_id})"}]
            }
        except Exception as e:
            logger.error(f"Error writing Card to graph: {e}")
            return {
                "content": [{"type": "text", "text": f"Error writing output: {e}"}],
                "is_error": True
            }

    tools = [read_journal, read_chat_log, read_recent_journals, read_recent_sessions, write_output]

    # Create the MCP server config
    server_config = create_sdk_mcp_server(
        name=f"daily_{config.name}",
        version="1.0.0",
        tools=tools
    )

    return tools, server_config
