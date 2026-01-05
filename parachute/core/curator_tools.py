"""
Curator Tools - Minimal Permission Tools for Background Agents.

These tools are purpose-built for the curator agent with strict security constraints:
- update_title: Can ONLY update session titles in the database
- update_context: Can ONLY append to files in Chat/contexts/
- get_session_info: Read-only access to session metadata

The curator agent has NO access to:
- General file reading/writing
- Shell commands
- Other tools from the main agent

This provides strong security isolation for background processing.
"""

import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Awaitable

from claude_code_sdk import tool, create_sdk_mcp_server, SdkMcpTool

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

    Returns:
        Tuple of (list of SdkMcpTool instances, server config dict)
    """
    contexts_dir = vault_path / "Chat" / "contexts"
    contexts_dir.mkdir(parents=True, exist_ok=True)

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
            # Update the session title in database
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

    # Tool: Append to context file
    @tool(
        "update_context",
        "Append new information to a context file. Use this to record persistent learnings about the user that should be remembered across conversations. Only add genuinely new, useful information.",
        {
            "file_name": str,  # Just the filename, not path
            "additions": str,  # Content to append
        }
    )
    async def update_context(args: dict[str, Any]) -> dict[str, Any]:
        """Append to a context file (append-only, no overwrite)."""
        file_name = args.get("file_name", "").strip()
        additions = args.get("additions", "").strip()

        if not file_name:
            return {
                "content": [{"type": "text", "text": "Error: file_name cannot be empty"}],
                "is_error": True
            }

        if not additions:
            return {
                "content": [{"type": "text", "text": "Error: additions cannot be empty"}],
                "is_error": True
            }

        # Security: validate file_name has no path components
        if "/" in file_name or "\\" in file_name or ".." in file_name:
            return {
                "content": [{"type": "text", "text": "Error: file_name cannot contain path separators"}],
                "is_error": True
            }

        # Security: must end in .md
        if not file_name.endswith(".md"):
            file_name = file_name + ".md"

        # Build safe path
        target_path = contexts_dir / file_name

        # Verify it resolves to within contexts_dir (prevent symlink attacks)
        try:
            resolved = target_path.resolve()
            if not str(resolved).startswith(str(contexts_dir.resolve())):
                return {
                    "content": [{"type": "text", "text": "Error: invalid file path"}],
                    "is_error": True
                }
        except Exception:
            return {
                "content": [{"type": "text", "text": "Error: invalid file path"}],
                "is_error": True
            }

        try:
            # Append-only operation
            timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

            # Format the addition with timestamp
            formatted_addition = f"\n\n<!-- Added by curator on {timestamp} -->\n{additions}"

            # Create file if it doesn't exist, otherwise append
            with open(target_path, "a", encoding="utf-8") as f:
                f.write(formatted_addition)

            logger.info(f"Curator appended to context file: {file_name}")
            return {
                "content": [{"type": "text", "text": f"Successfully added to {file_name}"}]
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
        {}  # No parameters needed
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
- Last Accessed: {session.last_accessed}"""

            return {
                "content": [{"type": "text", "text": info}]
            }
        except Exception as e:
            logger.error(f"Failed to get session info: {e}")
            return {
                "content": [{"type": "text", "text": f"Error getting session info: {str(e)}"}],
                "is_error": True
            }

    # Tool: List context files (read-only)
    @tool(
        "list_context_files",
        "List available context files that can be updated.",
        {}
    )
    async def list_context_files(args: dict[str, Any]) -> dict[str, Any]:
        """List context files in the contexts directory."""
        try:
            files = []
            if contexts_dir.exists():
                for f in contexts_dir.iterdir():
                    if f.is_file() and f.suffix == ".md":
                        files.append(f.name)

            if not files:
                return {
                    "content": [{"type": "text", "text": "No context files found. You can create one by using update_context with a new file_name."}]
                }

            return {
                "content": [{"type": "text", "text": f"Available context files:\n" + "\n".join(f"- {f}" for f in sorted(files))}]
            }
        except Exception as e:
            logger.error(f"Failed to list context files: {e}")
            return {
                "content": [{"type": "text", "text": f"Error listing files: {str(e)}"}],
                "is_error": True
            }

    tools = [update_title, update_context, get_session_info, list_context_files]

    # Create the MCP server config
    server_config = create_sdk_mcp_server(
        name="curator",
        version="1.0.0",
        tools=tools
    )

    return tools, server_config


# System prompt for curator agent - used for simple title-only generation
CURATOR_TITLE_PROMPT = """You are a title generator. Given a conversation, respond with ONLY a concise title (2-8 words) that captures the main topic. No explanation, no punctuation at the end, just the title itself.

Examples of good titles:
- Fix React useState infinite loop
- Planning weekend trip to Portland
- Debugging Python import errors
- Setting up Kubernetes cluster
- Discussing project architecture"""


# Full system prompt for curator agent with JSON-based actions
CURATOR_SYSTEM_PROMPT = """You are a Session Curator - a background agent that maintains a user's knowledge base by keeping session titles accurate and context files updated.

## Your Job

After messages in a chat conversation, you evaluate:
1. **Title**: Does the current title still accurately describe this conversation?
2. **Context**: Is there new, persistent information worth saving?

You're given the current title, available context files, and recent messages.

## Title Update Guidelines (BE CONSERVATIVE)

Titles should be **stable**. Only update when:
- The conversation has **meaningfully shifted direction** (not just continued on the same topic)
- The current title is **clearly wrong or misleading** about what's being discussed
- A **much better, more specific** title is now obvious

Do NOT update if:
- The current title is still reasonably accurate
- The conversation is just continuing on the same topic
- You're just rephrasing (e.g., "Python decorators" → "Understanding Python decorators")

## Context Update Guidelines

Context files store **persistent information** about the user. You have three types of updates:

### 1. Update Facts (can modify existing facts)
Use `update_facts` when you need to:
- Add a new fact about the user
- Correct an outdated fact
- Remove obsolete information

Facts are stored as bullet points and can be replaced entirely.

### 2. Update Current Focus (what's active now)
Use `update_focus` when:
- The user mentions a new active project or goal
- A previous focus is completed or abandoned

### 3. Append to History (append-only)
Use `append_history` when:
- Something notable happened that should be remembered
- A decision was made
- A milestone was reached

History is append-only - use this for temporal events.

## File Routing

You'll see a list of available context files. Route updates to the MOST SPECIFIC file:
- **Project-specific files** (e.g., `parachute.md`, `woven-web.md`) - for project context
- **general-context.md** - for personal info that spans projects

If no existing file fits and the topic is significant enough, you can create a new file.

## Response Format (IMPORTANT)

Respond with ONLY a JSON object:

```json
{
  "update_title": null,
  "context_actions": [],
  "reasoning": "Brief explanation"
}
```

### Context Actions

Each action in `context_actions` is an object with `action` and relevant fields:

**Update facts (replaces the Facts section):**
```json
{"action": "update_facts", "file": "parachute.md", "facts": ["Fact 1", "Fact 2"]}
```

**Update current focus:**
```json
{"action": "update_focus", "file": "general-context.md", "focus": ["Working on X", "Planning Y"]}
```

**Append to history:**
```json
{"action": "append_history", "file": "parachute.md", "entry": "- Completed feature X"}
```

**Create new context file:**
```json
{"action": "create_file", "file": "new-project.md", "name": "New Project", "description": "Brief description", "facts": ["Initial fact"]}
```

### Examples

No updates needed:
```json
{
  "update_title": null,
  "context_actions": [],
  "reasoning": "Title accurate, no new persistent info"
}
```

Update a fact in existing file:
```json
{
  "update_title": null,
  "context_actions": [
    {"action": "update_facts", "file": "general-context.md", "facts": ["Prefers TypeScript over JavaScript", "Uses neovim as primary editor"]}
  ],
  "reasoning": "User mentioned switching from vim to neovim"
}
```

Record milestone in project history:
```json
{
  "update_title": "Parachute v1.0 Launch Planning",
  "context_actions": [
    {"action": "append_history", "file": "parachute.md", "entry": "- Decided to target January 2026 for v1.0 launch"}
  ],
  "reasoning": "Significant project decision made"
}
```

Remember: Respond with ONLY the JSON object. Be efficient - this runs in the background.
"""
