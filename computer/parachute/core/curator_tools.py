"""
Curator MCP Tools - In-process MCP server for the curator agent.

Provides a single tool: log_activity - for logging significant activities
to the session's chat log entry.
"""

import logging
import random
import re
import string
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml
from mcp.server.fastmcp import FastMCP

logger = logging.getLogger(__name__)


def _generate_para_id() -> str:
    """Generate a random para ID like 'rhxo89'."""
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))


def create_curator_mcp(vault_path: Path) -> FastMCP:
    """
    Create an in-process MCP server with curator tools.

    The curator has one main tool: log_activity
    This logs significant activities to the session's chat log entry.
    """
    mcp = FastMCP("curator")
    chat_log_dir = vault_path / "Daily" / "chat-log"

    def _get_today_path() -> Path:
        today = datetime.now(timezone.utc).astimezone()
        return chat_log_dir / f"{today.strftime('%Y-%m-%d')}.md"

    def _parse_log(path: Path) -> tuple[dict, str]:
        """Parse chat log into frontmatter and body."""
        if not path.exists():
            return {}, ""
        content = path.read_text(encoding="utf-8")
        if not content.startswith("---"):
            return {}, content
        end = content.find("\n---", 3)
        if end == -1:
            return {}, content
        try:
            fm = yaml.safe_load(content[4:end]) or {}
        except yaml.YAMLError:
            fm = {}
        return fm, content[end + 4:].lstrip("\n")

    def _write_log(path: Path, fm: dict, body: str) -> None:
        """Write chat log file."""
        fm_str = yaml.dump(fm, default_flow_style=False, sort_keys=False)
        path.write_text(f"---\n{fm_str}---\n\n{body}", encoding="utf-8")

    def _get_session_para_id(fm: dict, session_id: str) -> Optional[str]:
        """Get para_id for a session from frontmatter."""
        for pid, meta in fm.get("entries", {}).items():
            if meta.get("session") == session_id:
                return pid
        return None

    @mcp.tool()
    def log_activity(session_id: str, activity: str, title: Optional[str] = None) -> str:
        """
        Log a significant activity for a chat session.

        Creates the session's log entry if it doesn't exist.
        Appends the activity to the entry if it does exist.

        Args:
            session_id: The chat session ID
            activity: The activity to log (markdown, e.g. "- **14:30** Refactored auth module")
            title: Session title (used when creating new entry)

        Returns:
            Status message
        """
        chat_log_dir.mkdir(parents=True, exist_ok=True)
        path = _get_today_path()
        fm, body = _parse_log(path)
        now = datetime.now(timezone.utc).astimezone()
        time_str = now.strftime("%H:%M")

        # Check if session has an entry
        para_id = _get_session_para_id(fm, session_id)

        if para_id:
            # Append to existing entry
            pattern = rf"(# para:{re.escape(para_id)} [^\n]+\n)"
            match = re.search(pattern, body)
            if match:
                # Find entry end
                rest = body[match.end():]
                end_match = re.search(r'\n---\n\n# para:', rest)
                if end_match:
                    insert_pos = match.end() + end_match.start()
                    new_body = body[:insert_pos].rstrip() + "\n" + activity + "\n" + body[insert_pos:]
                else:
                    new_body = body.rstrip() + "\n" + activity + "\n"

                fm["entries"][para_id]["modified"] = time_str
                _write_log(path, fm, new_body)
                logger.info(f"Logged activity to para:{para_id}")
                return f"Appended to para:{para_id}"

        # Create new entry
        para_id = _generate_para_id()
        if "date" not in fm:
            fm["date"] = now.strftime("%Y-%m-%d")
        fm.setdefault("entries", {})
        fm["entries"][para_id] = {
            "type": "session",
            "created": time_str,
            "session": session_id,
        }

        entry_title = title or "Chat session"
        entry = f"# para:{para_id} {time_str}\n\n**{entry_title}**\n\nSession: `{session_id}`\n\n{activity}\n"

        separator = "\n\n---\n\n" if body.strip() else ""
        new_body = body.rstrip() + separator + entry

        _write_log(path, fm, new_body)
        logger.info(f"Created entry para:{para_id} for session {session_id[:8]}")
        return f"Created para:{para_id}"

    return mcp
