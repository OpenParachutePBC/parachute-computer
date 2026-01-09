#!/usr/bin/env python3
"""
Curator MCP Server - runs as a subprocess for the curator agent.

This server provides tools for the curator:
- update_title: Request a title update (curator service applies it)
- log_activity: Log significant activities to the daily chat-log

Run with: python -m parachute.core.curator_mcp_server <vault_path>
"""

import logging
import random
import re
import string
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml
from mcp.server.fastmcp import FastMCP

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Get vault path from command line
if len(sys.argv) < 2:
    print("Usage: python -m parachute.core.curator_mcp_server <vault_path>", file=sys.stderr)
    sys.exit(1)

VAULT_PATH = Path(sys.argv[1])
CHAT_LOG_DIR = VAULT_PATH / "Daily" / "chat-log"

mcp = FastMCP("curator")


@mcp.tool()
def update_title(session_id: str, new_title: str) -> str:
    """
    Update the title of a chat session.

    Use this when you've determined a better, more descriptive title
    based on the conversation content. Keep titles concise (3-8 words, max 60 chars).

    Args:
        session_id: The chat session ID (UUID)
        new_title: The new title for the session

    Returns:
        Confirmation message with the new title
    """
    if not new_title or not new_title.strip():
        return "Error: new_title cannot be empty"

    new_title = new_title.strip()

    if len(new_title) > 100:
        return "Error: title too long (max 100 chars)"

    # The actual database update is handled by the curator service
    # which detects this tool call and applies the update
    logger.info(f"Title update requested for {session_id[:8]}: {new_title}")
    return f"Title update requested: {new_title}"


def _generate_para_id() -> str:
    """Generate a random para ID like 'rhxo89'."""
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=6))


@mcp.tool()
def log_activity(session_id: str, activity: str, title: Optional[str] = None) -> str:
    """
    Log a significant activity for a chat session.

    Creates the session's log entry if it doesn't exist.
    Appends the activity to the entry if it does exist.

    Args:
        session_id: The chat session ID (UUID)
        activity: The activity to log (markdown bullets)
        title: Session title (used when creating new entry)

    Returns:
        Status message indicating what was done
    """
    CHAT_LOG_DIR.mkdir(parents=True, exist_ok=True)

    now = datetime.now(timezone.utc).astimezone()
    today = now.strftime("%Y-%m-%d")
    time_str = now.strftime("%H:%M")
    path = CHAT_LOG_DIR / f"{today}.md"

    # Parse existing file
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

    # Check if session already has an entry
    para_id = None
    for pid, meta in fm.get("entries", {}).items():
        if meta.get("session") == session_id:
            para_id = pid
            break

    if para_id:
        # Append to existing entry
        pattern = rf"(# para:{re.escape(para_id)} [^\n]+\n)"
        match = re.search(pattern, body)
        if match:
            rest = body[match.end():]
            end_match = re.search(r'\n---\n\n# para:', rest)
            if end_match:
                insert_pos = match.end() + end_match.start()
                new_body = body[:insert_pos].rstrip() + "\n" + activity + "\n" + body[insert_pos:]
            else:
                new_body = body.rstrip() + "\n" + activity + "\n"

            fm["entries"][para_id]["modified"] = time_str
            fm_str = yaml.dump(fm, default_flow_style=False, sort_keys=False)
            path.write_text(f"---\n{fm_str}---\n\n{new_body}", encoding="utf-8")
            logger.info(f"Appended to para:{para_id}")
            return f"Appended activity to existing entry para:{para_id}"

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

    entry_title = title or "Chat session"
    entry = f"# para:{para_id} {time_str}\n\n**{entry_title}**\n\nSession: `{session_id}`\n\n{activity}\n"

    separator = "\n\n---\n\n" if body.strip() else ""
    new_body = body.rstrip() + separator + entry

    fm_str = yaml.dump(fm, default_flow_style=False, sort_keys=False)
    path.write_text(f"---\n{fm_str}---\n\n{new_body}", encoding="utf-8")
    logger.info(f"Created entry para:{para_id}")
    return f"Created new entry para:{para_id} for session"


if __name__ == "__main__":
    mcp.run()
