"""
Generic Daily Agent Tools.

These tools can be used by any daily agent:
- read_journal: Read journal entries for a specific date
- read_chat_log: Read AI chat logs for a specific date
- read_recent_journals: Read recent journal entries for context
- read_recent_sessions: Read recent AI chat sessions for context
- write_output: Write the agent's output to its configured path

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
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create tools for a daily agent bound to a specific vault.

    Args:
        vault_path: Path to the vault
        config: Agent configuration

    Returns:
        Tuple of (list of SdkMcpTool instances, server config dict)
    """
    journals_dir = vault_path / "Daily" / "journals"
    chat_log_dir = vault_path / "Daily" / "chat-log"

    # Determine output directory from config
    output_path_template = config.output_path

    @tool(
        "read_journal",
        "Read journal entries for a specific date. Returns the full content of that day's journal.",
        {"date": str}
    )
    async def read_journal(args: dict[str, Any]) -> dict[str, Any]:
        """Read journal entries for a date."""
        date_str = args.get("date", "").strip()

        if not date_str:
            return {
                "content": [{"type": "text", "text": "Error: date is required (YYYY-MM-DD format)"}],
                "is_error": True
            }

        journal_file = journals_dir / f"{date_str}.md"

        if not journal_file.exists():
            return {
                "content": [{"type": "text", "text": f"No journal found for {date_str}"}]
            }

        try:
            content = journal_file.read_text(encoding="utf-8")
            return {
                "content": [{"type": "text", "text": f"# Journal for {date_str}\n\n{content}"}]
            }
        except Exception as e:
            logger.error(f"Error reading journal: {e}")
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
        """Read chat logs for a date."""
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
        """Read recent journal entries for context."""
        days_back = args.get("days", 7)
        days_back = min(int(days_back), 30)  # Cap at 30 days

        today = datetime.now().astimezone().date()
        journals_found = []

        for i in range(1, days_back + 1):
            date = today - timedelta(days=i)
            date_str = date.strftime("%Y-%m-%d")
            journal_file = journals_dir / f"{date_str}.md"

            if journal_file.exists():
                try:
                    content = journal_file.read_text(encoding="utf-8")
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
        """Read recent chat sessions for context."""
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
        f"Write the agent's output. For this agent, output goes to: {output_path_template}",
        {"date": str, "content": str}
    )
    async def write_output(args: dict[str, Any]) -> dict[str, Any]:
        """Write the agent's output to its configured path."""
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

        # Get output path from config
        output_path = config.get_output_path(date_str)
        output_file = vault_path / output_path

        try:
            # Ensure directory exists
            output_file.parent.mkdir(parents=True, exist_ok=True)

            # Add metadata header
            full_content = f"""---
date: {date_str}
agent: {config.name}
generated_at: {datetime.now(timezone.utc).isoformat()}
---

{content}
"""
            output_file.write_text(full_content, encoding="utf-8")

            logger.info(f"Agent '{config.name}' wrote output for {date_str}")
            return {
                "content": [{"type": "text", "text": f"Successfully wrote output to {output_path}"}]
            }
        except Exception as e:
            logger.error(f"Error writing output: {e}")
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


# =============================================================================
# Curator-specific tools (for backward compatibility)
# =============================================================================

def create_curator_tools(vault_path: Path) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create curator-specific tools (backward compatible wrapper).

    This is a compatibility layer for the existing daily_curator.py.
    It creates tools with the legacy "write_reflection" name.
    """
    from parachute.core.daily_agent import get_daily_agent_config

    # Try to load curator config, or use defaults
    config = get_daily_agent_config(vault_path, "curator")

    journals_dir = vault_path / "Daily" / "journals"
    chat_log_dir = vault_path / "Daily" / "chat-log"
    reflections_dir = vault_path / "Daily" / "reflections"

    @tool(
        "read_journal",
        "Read journal entries for a specific date. Returns the full content of that day's journal.",
        {"date": str}
    )
    async def read_journal(args: dict[str, Any]) -> dict[str, Any]:
        date_str = args.get("date", "").strip()
        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date is required"}], "is_error": True}

        journal_file = journals_dir / f"{date_str}.md"
        if not journal_file.exists():
            return {"content": [{"type": "text", "text": f"No journal found for {date_str}"}]}

        try:
            content = journal_file.read_text(encoding="utf-8")
            return {"content": [{"type": "text", "text": f"# Journal for {date_str}\n\n{content}"}]}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Error: {e}"}], "is_error": True}

    @tool(
        "read_chat_log",
        "Read AI chat logs for a specific date.",
        {"date": str}
    )
    async def read_chat_log(args: dict[str, Any]) -> dict[str, Any]:
        date_str = args.get("date", "").strip()
        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date is required"}], "is_error": True}

        chat_log_file = chat_log_dir / f"{date_str}.md"
        if not chat_log_file.exists():
            return {"content": [{"type": "text", "text": f"No chat log found for {date_str}"}]}

        try:
            content = chat_log_file.read_text(encoding="utf-8")
            if len(content) > 10000:
                content = content[:10000] + "\n\n...(truncated)"
            return {"content": [{"type": "text", "text": f"# Chat Log for {date_str}\n\n{content}"}]}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Error: {e}"}], "is_error": True}

    @tool(
        "read_recent_journals",
        "Read journal entries from the past N days for context.",
        {"days": int}
    )
    async def read_recent_journals(args: dict[str, Any]) -> dict[str, Any]:
        days_back = min(int(args.get("days", 7)), 30)
        today = datetime.now().astimezone().date()
        journals_found = []

        for i in range(1, days_back + 1):
            date = today - timedelta(days=i)
            date_str = date.strftime("%Y-%m-%d")
            journal_file = journals_dir / f"{date_str}.md"

            if journal_file.exists():
                try:
                    content = journal_file.read_text(encoding="utf-8")
                    if len(content) > 5000:
                        content = content[:5000] + "\n\n...(truncated)"
                    journals_found.append(f"## {date_str}\n\n{content}")
                except Exception:
                    continue

        if not journals_found:
            return {"content": [{"type": "text", "text": f"No journals in past {days_back} days"}]}

        return {"content": [{"type": "text", "text": "\n\n---\n\n".join(journals_found)}]}

    @tool(
        "write_reflection",
        "Write the daily reflection to Daily/reflections/{date}.md",
        {"date": str, "content": str}
    )
    async def write_reflection(args: dict[str, Any]) -> dict[str, Any]:
        date_str = args.get("date", "").strip()
        content = args.get("content", "").strip()

        if not date_str:
            return {"content": [{"type": "text", "text": "Error: date is required"}], "is_error": True}
        if not content:
            return {"content": [{"type": "text", "text": "Error: content is required"}], "is_error": True}

        reflections_dir.mkdir(parents=True, exist_ok=True)
        reflection_file = reflections_dir / f"{date_str}.md"

        try:
            full_content = f"""---
date: {date_str}
generated_at: {datetime.now(timezone.utc).isoformat()}
---

{content}
"""
            reflection_file.write_text(full_content, encoding="utf-8")
            logger.info(f"Wrote reflection for {date_str}")
            return {"content": [{"type": "text", "text": f"Successfully wrote to Daily/reflections/{date_str}.md"}]}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Error: {e}"}], "is_error": True}

    tools = [read_journal, read_chat_log, read_recent_journals, write_reflection]
    server_config = create_sdk_mcp_server(name="daily_curator", version="1.0.0", tools=tools)
    return tools, server_config
