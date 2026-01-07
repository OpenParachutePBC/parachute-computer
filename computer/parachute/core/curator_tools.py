"""
Curator Tools - Minimal Permission Tools for Background Agents.

These tools are purpose-built for the curator agent with strict security constraints:
- update_title: Can ONLY update session titles in the database
- update_context: Can ONLY append to AGENTS.md files in the context chain
- get_session_info: Read-only access to session metadata
- list_context_files: List AGENTS.md files the curator can update

The curator agent has NO access to:
- General file reading/writing (only specific AGENTS.md files)
- Shell commands
- Other tools from the main agent

This provides strong security isolation for background processing.
"""

import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Awaitable, Optional

from claude_code_sdk import tool, create_sdk_mcp_server, SdkMcpTool

from parachute.db.database import Database
from parachute.models.session import SessionUpdate

logger = logging.getLogger(__name__)


async def _trigger_bubble_for_path(
    db: Database,
    vault_path: Path,
    updated_path: str,
    source_session_id: str,
) -> list[str]:
    """
    Trigger bubbling for a context file update.

    When a context file (AGENTS.md) is updated, find all files that watch it
    and queue curator tasks for them.

    Args:
        db: Database instance
        vault_path: Path to the vault
        updated_path: The file that was updated (e.g., "Projects/parachute/AGENTS.md")
        source_session_id: The session that triggered this update

    Returns:
        List of watcher paths that were notified
    """
    try:
        from parachute.core.context_watches import ContextWatchService

        watch_service = ContextWatchService(vault_path, db)
        watchers = await watch_service.find_watchers(updated_path)

        if not watchers:
            logger.debug(f"No watchers for {updated_path}")
            return []

        # Queue curator tasks for each watcher
        notified: list[str] = []
        for target in watchers:
            logger.info(
                f"Bubbling: {updated_path} -> {target.watcher_path} (pattern: {target.watch_pattern})"
            )

            # Queue a curator task for the watching file's context
            # The curator will review if the watching file needs updates based on the change
            try:
                from parachute.core.curator_service import get_curator_service

                curator_service = await get_curator_service()

                # Extract folder from watcher path (remove /AGENTS.md)
                if target.watcher_path.endswith("/AGENTS.md"):
                    watcher_folder = target.watcher_path.rsplit("/", 1)[0]
                elif target.watcher_path == "AGENTS.md":
                    watcher_folder = ""
                else:
                    watcher_folder = target.watcher_path

                # Queue a special "bubble" task type
                await curator_service.queue_task(
                    parent_session_id=source_session_id,
                    trigger_type="bubble",
                    context_files=[watcher_folder],
                )
                notified.append(target.watcher_path)

            except RuntimeError:
                # Curator service not initialized - skip bubbling
                logger.debug("Curator service not available for bubbling")
                break

        if notified:
            logger.info(f"Bubbled to {len(notified)} watchers: {notified}")

        return notified

    except Exception as e:
        logger.warning(f"Error during bubbling for {updated_path}: {e}")
        return []


def create_curator_tools(
    db: Database,
    vault_path: Path,
    parent_session_id: str,
    context_folders: Optional[list[str]] = None,
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create curator tools bound to a specific session context.

    Args:
        db: Database instance
        vault_path: Path to the vault
        parent_session_id: The session being curated
        context_folders: List of folder paths for the context chain (e.g., ["Projects/parachute"])

    Returns:
        Tuple of (list of SdkMcpTool instances, server config dict)
    """
    # Build the list of AGENTS.md files the curator can update
    # This includes the full parent chain for each selected folder
    from parachute.core.context_folders import ContextFolderService

    context_service = ContextFolderService(vault_path)

    # Build context chain to get all updatable files
    effective_folders = context_folders or [""]  # Root only if nothing selected
    chain = context_service.build_chain(effective_folders, max_tokens=100000)

    # Extract the file paths the curator can update
    updatable_files = [f.path for f in chain.files if f.exists]

    # Legacy support: also keep Chat/contexts/ accessible
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

    # Tool: Append to context file (AGENTS.md or legacy contexts/)
    @tool(
        "update_context",
        "Append new information to a context file. For AGENTS.md files in the context chain, use the full path (e.g., 'Projects/parachute/AGENTS.md'). For legacy files, just use the filename (e.g., 'general-context.md'). Only add genuinely new, useful information.",
        {
            "file_path": str,  # Path to AGENTS.md or filename for legacy
            "additions": str,  # Content to append
        }
    )
    async def update_context(args: dict[str, Any]) -> dict[str, Any]:
        """Append to a context file (append-only, no overwrite)."""
        file_path = args.get("file_path", "").strip()
        # Also accept file_name for backwards compatibility
        if not file_path:
            file_path = args.get("file_name", "").strip()
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

        # Determine if this is a new AGENTS.md path or legacy filename
        if "/" in file_path or file_path in ["AGENTS.md", "CLAUDE.md"]:
            # New system: path to AGENTS.md in context chain
            # Security: must be in the updatable files list
            if file_path not in updatable_files:
                return {
                    "content": [{"type": "text", "text": f"Error: {file_path} is not in the context chain. Available files: {', '.join(updatable_files)}"}],
                    "is_error": True
                }
            target_path = vault_path / file_path
        else:
            # Legacy system: filename in Chat/contexts/
            if not file_path.endswith(".md"):
                file_path = file_path + ".md"
            target_path = contexts_dir / file_path

            # Verify it resolves to within contexts_dir
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

            logger.info(f"Curator appended to context file: {file_path}")

            # Trigger bubbling: notify files that watch this one
            await _trigger_bubble_for_path(db, vault_path, file_path, parent_session_id)

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
        "List available AGENTS.md files in the context chain that can be updated.",
        {}
    )
    async def list_context_files(args: dict[str, Any]) -> dict[str, Any]:
        """List AGENTS.md files in the context chain."""
        try:
            output_lines = ["## Context Chain (AGENTS.md files you can update):\n"]

            if updatable_files:
                for f in updatable_files:
                    # Find the matching file in chain for level info
                    level = "direct"
                    for cf in chain.files:
                        if cf.path == f:
                            level = cf.level
                            break
                    output_lines.append(f"- {f} ({level})")
            else:
                output_lines.append("No AGENTS.md files in context chain.")

            # Also list legacy context files
            legacy_files = []
            if contexts_dir.exists():
                for f in contexts_dir.iterdir():
                    if f.is_file() and f.suffix == ".md":
                        legacy_files.append(f.name)

            if legacy_files:
                output_lines.append("\n## Legacy context files (Chat/contexts/):\n")
                for f in sorted(legacy_files):
                    output_lines.append(f"- {f}")

            return {
                "content": [{"type": "text", "text": "\n".join(output_lines)}]
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
CURATOR_SYSTEM_PROMPT = """You are a Session Curator - a long-running background agent that maintains a user's knowledge base. You watch conversations as they evolve and have full memory of your past actions in this curator session.

## Your Job

You receive message digests after each exchange in a chat conversation. For each digest, you evaluate:
1. **Title**: Does the current title still accurately describe this conversation?
2. **Context**: Is there new, persistent information worth saving?

## Tools Available

You have access to these tools (use them directly when needed):
- **mcp__curator__update_title**: Update the session title (use VERY conservatively!)
- **mcp__curator__update_context**: Append to a context file (for significant milestones only)
- **mcp__curator__list_context_files**: See available context files
- **mcp__curator__get_session_info**: Get current session info

## IMPORTANT: You have memory

You maintain session continuity - you can remember what updates you've already made. If you already updated the title or logged a milestone, don't do it again. Check your memory before acting.

## Title Format: "Project: Task" (max 8 words total)

Titles use a **prefix: suffix** format for easy searching and organization:
- **Prefix** = Short project/topic name (1-2 words) inferred from conversation context
- **Suffix** = What's being done (3-6 words)

Infer the prefix from:
- The working directory or codebase being discussed
- Context files that are loaded (e.g., if "myproject.md" is loaded, prefix might be "MyProject:")
- The main topic of conversation
- Use "Personal:" only for non-project conversations

Examples:
- "MyApp: Fix authentication bug"
- "Website: Landing page and funnel"
- "Personal: Movie recommendations"

## Title Update Guidelines (BE VERY CONSERVATIVE)

Titles should be **stable**. A good title set early should rarely change.

**Only update the title when:**
- The **project prefix is wrong** (e.g., switched from Parachute work to LVB work)
- The current title is **completely misleading** about the conversation's purpose
- The session is untitled or has a garbage auto-generated title

**Do NOT update if:**
- The current title is still reasonably accurate for the overall session
- You're just updating the suffix to reflect the latest task (this causes churn!)
- The conversation is continuing on related work within the same project
- You're just rephrasing (e.g., "Fix bug" → "Debug and fix bug")

**Key principle**: A session about "Parachute: Feature development" that moves from implementing file attachments to fixing audio bugs should KEEP the same title. The prefix captures the project, and the suffix should be broad enough to cover the session's scope.

## Context Update Guidelines (BE CONSERVATIVE)

Context files store **persistent information** about the user. Most messages do NOT warrant context updates.

**Only update context when:**
- A **significant milestone** is reached (feature shipped, decision made, project completed)
- The user shares **new personal information** worth remembering
- A **fact needs correction** (e.g., wrong name, outdated info)

**Do NOT update context for:**
- Routine development work (implementing features, fixing bugs, refactoring)
- Work in progress that hasn't concluded
- Information already captured in previous entries
- Minor implementation details

### Types of Updates

**1. Update Facts** - Use sparingly to correct or add important user facts
- Correct wrong information (e.g., name misspelling)
- Add significant new preferences or attributes

**2. Update Current Focus** - Use when major focus shifts
- Starting a new major project
- Completing/abandoning a previous focus

**3. Append to History** - Use for significant milestones only
- Major feature completions
- Important decisions
- Project launches or completions
- NOT for incremental progress updates

**Key principle**: If you already logged something similar recently, don't log it again. One entry per milestone is enough.

## Context Chain & File Routing

The session has a context chain of AGENTS.md files from the vault root down to the specific project.
Use `mcp__curator__list_context_files` to see available files, then route updates to the MOST SPECIFIC file:

**Hierarchy example for Projects/parachute:**
- `AGENTS.md` (root) - Personal info spanning all projects
- `Projects/AGENTS.md` (parent) - Overview of all projects
- `Projects/parachute/AGENTS.md` (direct) - Parachute-specific context

**Routing guidance:**
- User facts, preferences, identity → Root `AGENTS.md`
- Project milestones, decisions → Most specific project AGENTS.md
- Cross-project info → Parent-level AGENTS.md

**Legacy support:**
- Files in `Chat/contexts/` (e.g., `general-context.md`) still work with just the filename

## How to Respond

1. **If no updates needed (MOST COMMON)**: Just say "No updates needed" and briefly explain why
2. **If title needs updating**: Use `mcp__curator__update_title` with the new title
3. **If context needs updating**: Use `mcp__curator__update_context` with file_name and content

### Examples

**No updates needed:**
"No updates needed - title is accurate and this is routine development work, not a milestone."

**Title needs updating (RARE):**
Use `mcp__curator__update_title` with new_title="LVB: Course content planning"
(because conversation shifted from Parachute to LVB project)

**Significant milestone (RARE):**
Use `mcp__curator__update_context` with file_name="parachute.md" and content="- Shipped v1.0 to App Store"
(because a major milestone was reached)

## Remember

- You have MEMORY of your past actions - check what you've already done before acting
- Be efficient - this runs in the background after every message
- **Most digests require NO action** - only use tools when truly necessary
- When no action is needed, just respond with a brief explanation
"""
