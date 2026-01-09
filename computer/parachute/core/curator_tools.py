"""
Curator Tools - Tools for Background Curator Agents.

These tools are purpose-built for the curator agent:
- update_title: Update session titles in the database
- read_context: Read any AGENTS.md or CLAUDE.md file in the vault
- update_context: Append to any AGENTS.md file in the vault
- get_session_info: Read-only access to session metadata

The curator sees the same CLAUDE.md hierarchy as the main agent via SDK's
setting_sources, so it understands the project context naturally.
"""

import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from claude_agent_sdk import tool, create_sdk_mcp_server, SdkMcpTool

from parachute.db.database import Database
from parachute.models.session import SessionUpdate

logger = logging.getLogger(__name__)


def create_curator_tools(
    db: Database,
    vault_path: Path,
    parent_session_id: str,
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create curator tools bound to a specific session context.

    Args:
        db: Database instance
        vault_path: Path to the vault
        parent_session_id: The session being curated

    Returns:
        Tuple of (list of SdkMcpTool instances, server config dict)
    """

    # Tool: Update session title
    @tool(
        "update_title",
        "Update the title of the current chat session. Use this when you've determined a better, more descriptive title based on the conversation content.",
        {"new_title": str}
    )
    async def update_title(args: dict[str, Any]) -> dict[str, Any]:
        """Update the session title."""
        new_title = args.get("new_title", "").strip()

        if not new_title:
            return {
                "content": [{"type": "text", "text": "Error: new_title cannot be empty"}],
                "is_error": True
            }

        if len(new_title) > 200:
            return {
                "content": [{"type": "text", "text": "Error: title too long (max 200 chars)"}],
                "is_error": True
            }

        try:
            await db.update_session(
                parent_session_id,
                SessionUpdate(title=new_title)
            )

            logger.info(f"Curator updated title for {parent_session_id}: {new_title}")
            return {
                "content": [{"type": "text", "text": f"Successfully updated title to: {new_title}"}]
            }
        except Exception as e:
            logger.error(f"Failed to update title: {e}")
            return {
                "content": [{"type": "text", "text": f"Error updating title: {str(e)}"}],
                "is_error": True
            }

    # Tool: Read context file
    @tool(
        "read_context",
        "Read an AGENTS.md or CLAUDE.md file from the vault. Use this to check current content before deciding whether updates are needed.",
        {"file_path": str}
    )
    async def read_context(args: dict[str, Any]) -> dict[str, Any]:
        """Read a context file."""
        file_path = args.get("file_path", "").strip()

        if not file_path:
            return {
                "content": [{"type": "text", "text": "Error: file_path cannot be empty"}],
                "is_error": True
            }

        # Security: no path traversal
        if ".." in file_path:
            return {
                "content": [{"type": "text", "text": "Error: invalid file path (no .. allowed)"}],
                "is_error": True
            }

        # Must be an AGENTS.md or CLAUDE.md file
        if not (file_path.endswith("AGENTS.md") or file_path.endswith("CLAUDE.md")):
            return {
                "content": [{"type": "text", "text": "Error: can only read AGENTS.md or CLAUDE.md files"}],
                "is_error": True
            }

        target_path = vault_path / file_path

        if not target_path.exists():
            return {
                "content": [{"type": "text", "text": f"File not found: {file_path}"}]
            }

        try:
            content = target_path.read_text(encoding="utf-8")
            return {
                "content": [{"type": "text", "text": f"# {file_path}\n\n{content}"}]
            }
        except Exception as e:
            logger.error(f"Failed to read context file: {e}")
            return {
                "content": [{"type": "text", "text": f"Error reading file: {str(e)}"}],
                "is_error": True
            }

    # Tool: Update context file (append-only)
    @tool(
        "update_context",
        "Append new information to an AGENTS.md file. Use the full path (e.g., 'AGENTS.md' for root, 'Projects/myproject/AGENTS.md' for project-specific). Only add genuinely new, significant information.",
        {
            "file_path": str,
            "additions": str,
        }
    )
    async def update_context(args: dict[str, Any]) -> dict[str, Any]:
        """Append to a context file (append-only, no overwrite)."""
        file_path = args.get("file_path", "").strip()
        additions = args.get("additions", "").strip()

        if not file_path:
            return {
                "content": [{"type": "text", "text": "Error: file_path cannot be empty"}],
                "is_error": True
            }

        if not additions:
            return {
                "content": [{"type": "text", "text": "Error: additions cannot be empty"}],
                "is_error": True
            }

        # Security: no path traversal
        if ".." in file_path:
            return {
                "content": [{"type": "text", "text": "Error: invalid file path (no .. allowed)"}],
                "is_error": True
            }

        # Must be an AGENTS.md file (not CLAUDE.md - that's for instructions, not curator updates)
        if not file_path.endswith("AGENTS.md"):
            return {
                "content": [{"type": "text", "text": "Error: can only update AGENTS.md files (not CLAUDE.md)"}],
                "is_error": True
            }

        target_path = vault_path / file_path

        # Ensure parent directory exists
        target_path.parent.mkdir(parents=True, exist_ok=True)

        try:
            timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
            formatted_addition = f"\n\n<!-- Added by curator on {timestamp} -->\n{additions}"

            with open(target_path, "a", encoding="utf-8") as f:
                f.write(formatted_addition)

            logger.info(f"Curator appended to context file: {file_path}")
            return {
                "content": [{"type": "text", "text": f"Successfully added to {file_path}"}]
            }
        except Exception as e:
            logger.error(f"Failed to update context file: {e}")
            return {
                "content": [{"type": "text", "text": f"Error updating context: {str(e)}"}],
                "is_error": True
            }

    # Tool: Get session info (read-only)
    @tool(
        "get_session_info",
        "Get current information about the chat session being curated, including current title and message count.",
        {}
    )
    async def get_session_info(args: dict[str, Any]) -> dict[str, Any]:
        """Get read-only session information."""
        try:
            session = await db.get_session(parent_session_id)
            if not session:
                return {
                    "content": [{"type": "text", "text": "Error: session not found"}],
                    "is_error": True
                }

            info = f"""Session Information:
- ID: {session.id}
- Current Title: {session.title or '(untitled)'}
- Message Count: {session.message_count}
- Created: {session.created_at}
- Last Accessed: {session.last_accessed}
- Working Directory: {session.working_directory or '(vault root)'}"""

            return {
                "content": [{"type": "text", "text": info}]
            }
        except Exception as e:
            logger.error(f"Failed to get session info: {e}")
            return {
                "content": [{"type": "text", "text": f"Error getting session info: {str(e)}"}],
                "is_error": True
            }

    tools = [update_title, read_context, update_context, get_session_info]

    server_config = create_sdk_mcp_server(
        name="curator",
        version="1.0.0",
        tools=tools
    )

    return tools, server_config


# System prompt for curator agent - used for simple title-only generation
CURATOR_TITLE_PROMPT = """You are a title generator. Given a conversation, respond with ONLY a concise title that captures the main topic. No explanation, no punctuation at the end, just the title itself.

## Title Format: "Project: Task" (max 8 words total)

Use a **prefix: suffix** format where:
- **Prefix** = Short project/topic name (1-2 words) inferred from the conversation
- **Suffix** = What's being done (3-6 words)

Infer the prefix from:
- The working directory or codebase being discussed
- The main project or topic of conversation
- Use "Personal:" only for non-project conversations

Examples of good titles:
- MyApp: Fix authentication bug
- Website: Landing page redesign
- Personal: Weekend trip planning
- Backend: Database migration setup
- Docs: API reference updates"""


# Full system prompt for curator agent with tool access
CURATOR_SYSTEM_PROMPT = """You are a Session Curator - a long-running background agent that maintains a user's knowledge base. You watch conversations as they evolve and have full memory of your past actions.

## Your Job

You receive message digests after each exchange in a chat conversation. For each digest, you evaluate:
1. **Title**: Does the current title still accurately describe this conversation?
2. **Context**: Is there new, persistent information worth saving to AGENTS.md files?

## Tools Available

- **mcp__curator__update_title**: Update the session title (use VERY conservatively!)
- **mcp__curator__read_context**: Read an AGENTS.md file to see current content
- **mcp__curator__update_context**: Append to an AGENTS.md file (for significant milestones only)
- **mcp__curator__get_session_info**: Get current session info including working directory

## You Have Memory

You maintain session continuity - you remember your past actions. If you already updated the title or logged a milestone, don't do it again.

## Title Guidelines (BE VERY CONSERVATIVE)

Format: **"Project: Task"** (max 8 words)
- Prefix = project/topic name from working directory or context
- Suffix = what's being done (3-6 words)

**Only update the title when:**
- The project prefix is wrong (switched projects)
- The current title is completely misleading
- The session is untitled or has a garbage auto-generated title

**Do NOT update if:**
- The title is reasonably accurate for the session
- You're just updating to reflect the latest task (causes churn!)
- You're just rephrasing

## Context Update Guidelines (BE CONSERVATIVE)

**Only update AGENTS.md when:**
- A significant milestone is reached (feature shipped, decision made)
- The user shares new personal information worth remembering
- A fact needs correction

**Do NOT update for:**
- Routine development work
- Work in progress
- Information already captured
- Minor details

## File Routing

Use `read_context` to check files before updating. Route to the most specific file:
- Root `AGENTS.md` → Personal info, cross-project preferences
- Project `AGENTS.md` (e.g., `Projects/myapp/AGENTS.md`) → Project-specific milestones

## How to Respond

1. **If no updates needed (MOST COMMON)**: Just say "No updates needed" and briefly why
2. **If title needs updating**: Use `update_title`
3. **If context needs updating**: Use `read_context` first, then `update_context`

Most digests require NO action. Be efficient - this runs in the background after every message.
"""
