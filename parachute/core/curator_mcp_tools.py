"""
Curator MCP Tools - In-process SDK MCP server for curator agent.

This provides curator tools as an in-process MCP server that runs directly
within the Python application, eliminating subprocess communication issues.

Tools:
- update_title: Update the session title
- get_session_log: Read the current session's log entry for today
- update_session_log: Replace/update the session's log entry for today
"""

import logging
import random
import re
import string
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)


def create_curator_mcp_server(vault_path: Path):
    """
    Create an in-process SDK MCP server with curator tools.

    Args:
        vault_path: Path to the vault directory

    Returns:
        An SDK MCP server configuration
    """
    from claude_agent_sdk import tool, create_sdk_mcp_server

    chat_log_dir = vault_path / "Daily" / "chat-log"

    def _get_today_path() -> tuple[Path, str, str]:
        """Get today's log file path, date string, and current time in local timezone."""
        # Use local timezone since chat logs are organized by local calendar days
        now = datetime.now().astimezone()
        today = now.strftime("%Y-%m-%d")
        time_str = now.strftime("%H:%M")
        path = chat_log_dir / f"{today}.md"
        return path, today, time_str

    def _parse_chat_log(path: Path) -> tuple[dict, str]:
        """Parse a chat log file into frontmatter and body."""
        fm: dict = {}
        body = ""
        if path.exists():
            content = path.read_text(encoding="utf-8")
            if content.startswith("---"):
                end = content.find("\n---", 3)
                if end != -1:
                    try:
                        fm = yaml.safe_load(content[4:end]) or {}
                    except yaml.YAMLError:
                        pass
                    body = content[end + 4:].lstrip("\n")
        return fm, body

    def _find_session_para_id(fm: dict, session_id: str) -> str | None:
        """Find the para ID for a session in the frontmatter."""
        for pid, meta in fm.get("entries", {}).items():
            if meta.get("session") == session_id:
                return pid
        return None

    def _extract_section(body: str, para_id: str) -> str | None:
        """Extract the content of a para section."""
        pattern = rf"# para:{re.escape(para_id)} [^\n]+\n"
        match = re.search(pattern, body)
        if not match:
            return None

        rest = body[match.end():]
        end_match = re.search(r'\n---\n\n# para:', rest)
        if end_match:
            section_content = rest[:end_match.start()]
        else:
            section_content = rest

        return section_content.strip()

    def _generate_para_id() -> str:
        """Generate a random para ID like 'rhxo89'."""
        return ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))

    @tool(
        "update_title",
        "Update the title of a chat session. Keep titles concise (3-8 words, max 60 chars).",
        {"session_id": str, "new_title": str}
    )
    async def update_title(args: dict[str, Any]) -> dict:
        session_id = args["session_id"]
        new_title = args["new_title"]

        if not new_title or not new_title.strip():
            return {"content": [{"type": "text", "text": "Error: new_title cannot be empty"}]}

        new_title = new_title.strip()
        if len(new_title) > 100:
            return {"content": [{"type": "text", "text": "Error: title too long (max 100 chars)"}]}

        # The actual database update is handled by the curator service
        logger.info(f"Title update requested for {session_id[:8]}: {new_title}")
        return {"content": [{"type": "text", "text": f"Title update requested: {new_title}"}]}

    @tool(
        "get_session_log",
        "Get the current session's log entry for today to see what you've previously logged.",
        {"session_id": str}
    )
    async def get_session_log(args: dict[str, Any]) -> dict:
        session_id = args["session_id"]
        path, today, _ = _get_today_path()
        fm, body = _parse_chat_log(path)

        para_id = _find_session_para_id(fm, session_id)
        if not para_id:
            return {"content": [{"type": "text", "text": f"No log entry exists yet for session {session_id[:8]} on {today}"}]}

        content = _extract_section(body, para_id)
        if content:
            return {"content": [{"type": "text", "text": f"Current log entry for session {session_id[:8]}:\n\n{content}"}]}
        else:
            return {"content": [{"type": "text", "text": f"Entry exists but content could not be extracted for para:{para_id}"}]}

    @tool(
        "update_session_log",
        "Update (or create) the session's log entry for today. This REPLACES the entire log section.",
        {"session_id": str, "title": str, "summary": str}
    )
    async def update_session_log(args: dict[str, Any]) -> dict:
        session_id = args["session_id"]
        title = args["title"]
        summary = args["summary"]

        chat_log_dir.mkdir(parents=True, exist_ok=True)

        path, today, time_str = _get_today_path()
        fm, body = _parse_chat_log(path)

        para_id = _find_session_para_id(fm, session_id)

        if para_id:
            # Update existing entry
            pattern = rf"(# para:{re.escape(para_id)} )([^\n]+)(\n)"
            header_match = re.search(pattern, body)
            if header_match:
                rest = body[header_match.end():]
                end_match = re.search(r'\n---\n\n# para:', rest)

                new_content = f"""**{title}**

[Open session](parachute://chat/session/{session_id})

{summary.strip()}
"""
                if end_match:
                    new_body = (
                        body[:header_match.end()] +
                        new_content +
                        body[header_match.end() + end_match.start():]
                    )
                else:
                    new_body = body[:header_match.end()] + new_content

                fm["entries"][para_id]["modified"] = time_str
                fm_str = yaml.dump(fm, default_flow_style=False, sort_keys=False)
                path.write_text(f"---\n{fm_str}---\n\n{new_body}", encoding="utf-8")
                logger.info(f"Updated para:{para_id}")
                return {"content": [{"type": "text", "text": f"Updated log entry para:{para_id}"}]}

        # Create new entry
        para_id = _generate_para_id()
        if "date" not in fm:
            fm["date"] = today
        fm.setdefault("entries", {})
        fm["entries"][para_id] = {
            "type": "session",
            "created": time_str,
            "session": session_id,
        }

        entry = f"""# para:{para_id} {time_str}

**{title}**

[Open session](parachute://chat/session/{session_id})

{summary.strip()}
"""

        separator = "\n\n---\n\n" if body.strip() else ""
        new_body = body.rstrip() + separator + entry

        fm_str = yaml.dump(fm, default_flow_style=False, sort_keys=False)
        path.write_text(f"---\n{fm_str}---\n\n{new_body}", encoding="utf-8")
        logger.info(f"Created entry para:{para_id}")
        return {"content": [{"type": "text", "text": f"Created log entry para:{para_id}"}]}

    # Create the SDK MCP server
    return create_sdk_mcp_server(
        name="curator",
        version="1.0.0",
        tools=[update_title, get_session_log, update_session_log]
    )
