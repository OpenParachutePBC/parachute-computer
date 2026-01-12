"""
Daily Curator Tools - In-process MCP tools for the daily curator.

These tools are purpose-built for the daily curator agent:
- read_journal: Read journal entries for a specific date
- read_chat_log: Read AI chat logs for a specific date
- read_recent_journals: Read recent journal entries for context
- write_reflection: Write the daily reflection

Uses the claude-agent-sdk's in-process MCP server for better performance.
"""

import logging
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

from claude_agent_sdk import tool, create_sdk_mcp_server, SdkMcpTool

logger = logging.getLogger(__name__)


def create_daily_curator_tools(
    vault_path: Path,
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create daily curator tools bound to a specific vault.

    Args:
        vault_path: Path to the vault

    Returns:
        Tuple of (list of SdkMcpTool instances, server config dict)
    """
    journals_dir = vault_path / "Daily" / "journals"
    chat_log_dir = vault_path / "Daily" / "chat-log"
    reflections_dir = vault_path / "Daily" / "reflections"

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

        today = datetime.now().date()
        journals_found = []

        for i in range(1, days_back + 1):
            date = today - timedelta(days=i)
            date_str = date.strftime("%Y-%m-%d")
            journal_file = journals_dir / f"{date_str}.md"

            if journal_file.exists():
                try:
                    content = journal_file.read_text(encoding="utf-8")
                    # Truncate very long journals for context
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
        "write_reflection",
        "Write the daily reflection to Daily/reflections/{date}.md. Include the reflection text, song URL, and image URL.",
        {"date": str, "content": str}
    )
    async def write_reflection(args: dict[str, Any]) -> dict[str, Any]:
        """Write the daily reflection."""
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

        # Ensure reflections directory exists
        reflections_dir.mkdir(parents=True, exist_ok=True)

        reflection_file = reflections_dir / f"{date_str}.md"

        try:
            # Add metadata header
            full_content = f"""---
date: {date_str}
generated_at: {datetime.now(timezone.utc).isoformat()}
---

{content}
"""
            reflection_file.write_text(full_content, encoding="utf-8")

            logger.info(f"Daily curator wrote reflection for {date_str}")
            return {
                "content": [{"type": "text", "text": f"Successfully wrote reflection to Daily/reflections/{date_str}.md"}]
            }
        except Exception as e:
            logger.error(f"Error writing reflection: {e}")
            return {
                "content": [{"type": "text", "text": f"Error writing reflection: {e}"}],
                "is_error": True
            }

    tools = [read_journal, read_chat_log, read_recent_journals, write_reflection]

    # Create the MCP server config
    server_config = create_sdk_mcp_server(
        name="daily_curator",
        version="1.0.0",
        tools=tools
    )

    return tools, server_config
