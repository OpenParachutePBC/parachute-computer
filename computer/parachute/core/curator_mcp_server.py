#!/usr/bin/env python3
"""
Curator MCP Server - runs as a subprocess for the curator agent.

This server provides tools for the curator:
- update_title: Request a title update (curator service applies it)
- get_session_log: Read the current session's log entry for today
- update_session_log: Replace/update the session's log entry for today

The curator "tends" to its section of the daily chat-log, updating it
throughout the session to reflect what was accomplished.

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


def _get_today_path() -> tuple[Path, str, str]:
    """Get today's log file path, date string, and current time."""
    now = datetime.now(timezone.utc).astimezone()
    today = now.strftime("%Y-%m-%d")
    time_str = now.strftime("%H:%M")
    path = CHAT_LOG_DIR / f"{today}.md"
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


def _find_session_para_id(fm: dict, session_id: str) -> Optional[str]:
    """Find the para ID for a session in the frontmatter."""
    for pid, meta in fm.get("entries", {}).items():
        if meta.get("session") == session_id:
            return pid
    return None


def _extract_section(body: str, para_id: str) -> Optional[str]:
    """Extract the content of a para section (everything after the header until next section or end)."""
    pattern = rf"# para:{re.escape(para_id)} [^\n]+\n"
    match = re.search(pattern, body)
    if not match:
        return None

    rest = body[match.end():]
    # Find end of section (next section separator or end of file)
    end_match = re.search(r'\n---\n\n# para:', rest)
    if end_match:
        section_content = rest[:end_match.start()]
    else:
        section_content = rest

    return section_content.strip()


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
def get_session_log(session_id: str) -> str:
    """
    Get the current session's log entry for today.

    Use this to see what you've previously logged for this session today,
    so you can update it with new accomplishments.

    Args:
        session_id: The chat session ID (UUID)

    Returns:
        The current log content, or a message if no entry exists yet
    """
    path, today, _ = _get_today_path()
    fm, body = _parse_chat_log(path)

    para_id = _find_session_para_id(fm, session_id)
    if not para_id:
        return f"No log entry exists yet for session {session_id[:8]} on {today}"

    content = _extract_section(body, para_id)
    if content:
        return f"Current log entry for session {session_id[:8]}:\n\n{content}"
    else:
        return f"Entry exists but content could not be extracted for para:{para_id}"


@mcp.tool()
def update_session_log(session_id: str, title: str, summary: str) -> str:
    """
    Update (or create) the session's log entry for today.

    This REPLACES the entire log section for this session. Use this to
    maintain an up-to-date summary of what was accomplished in this chat.

    The entry will include:
    - A clickable session link for navigation
    - Your summary of accomplishments (markdown formatted)

    Args:
        session_id: The chat session ID (UUID)
        title: Title for the session (what the chat is about)
        summary: Markdown summary of accomplishments (use bullet points)

    Returns:
        Confirmation message
    """
    CHAT_LOG_DIR.mkdir(parents=True, exist_ok=True)

    path, today, time_str = _get_today_path()
    fm, body = _parse_chat_log(path)

    # Check if session already has an entry
    para_id = _find_session_para_id(fm, session_id)

    if para_id:
        # Update existing entry - find and replace the section
        pattern = rf"(# para:{re.escape(para_id)} )([^\n]+)(\n)"
        header_match = re.search(pattern, body)
        if header_match:
            # Find the end of this section
            rest = body[header_match.end():]
            end_match = re.search(r'\n---\n\n# para:', rest)

            # Build the new section content
            # Use parachute:// URL scheme for clickable session link
            new_content = f"""**{title}**

[Open session](parachute://chat/session/{session_id})

{summary.strip()}
"""
            if end_match:
                # There's another section after this one
                new_body = (
                    body[:header_match.end()] +
                    new_content +
                    body[header_match.end() + end_match.start():]
                )
            else:
                # This is the last section
                new_body = body[:header_match.end()] + new_content

            fm["entries"][para_id]["modified"] = time_str
            fm_str = yaml.dump(fm, default_flow_style=False, sort_keys=False)
            path.write_text(f"---\n{fm_str}---\n\n{new_body}", encoding="utf-8")
            logger.info(f"Updated para:{para_id}")
            return f"Updated log entry para:{para_id}"

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

    # Build entry with clickable session link
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
    return f"Created log entry para:{para_id}"


if __name__ == "__main__":
    mcp.run()
