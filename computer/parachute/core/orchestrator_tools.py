"""
Orchestrator Session Tools.

Tools for the daily orchestrator agent to manage and coordinate sessions:
- read_activity_log: Read today's activity log
- list_active_sessions: List active sessions with filtering
- get_session_summary: Get summary of a specific session
- create_session: Create a new session with a specific agent type
- add_session_reference: Link related sessions together

Uses the claude-agent-sdk's in-process MCP server.
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from claude_agent_sdk import tool, create_sdk_mcp_server, SdkMcpTool

logger = logging.getLogger(__name__)


def create_orchestrator_tools(
    vault_path: Path,
    database: Any,  # Database instance
) -> tuple[list[SdkMcpTool], dict[str, Any]]:
    """
    Create tools for the orchestrator agent.

    Args:
        vault_path: Path to the vault
        database: Database instance for session queries

    Returns:
        Tuple of (list of SdkMcpTool instances, server config dict)
    """
    activity_dir = vault_path / "Daily" / ".activity"

    @tool(
        "read_activity_log",
        "Read the activity log for a given date. Shows summaries of all conversation exchanges that happened.",
        {"date": str}
    )
    async def read_activity_log(args: dict[str, Any]) -> dict[str, Any]:
        """Read activity log entries for a date."""
        date_str = args.get("date", "").strip()

        if not date_str:
            # Default to today
            date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")

        log_file = activity_dir / f"{date_str}.jsonl"

        if not log_file.exists():
            return {
                "content": [{"type": "text", "text": f"No activity log found for {date_str}"}]
            }

        try:
            entries = []
            for line in log_file.read_text().strip().split("\n"):
                if line.strip():
                    entries.append(json.loads(line))

            if not entries:
                return {
                    "content": [{"type": "text", "text": f"Activity log for {date_str} is empty"}]
                }

            # Format entries for display
            formatted = f"# Activity Log for {date_str}\n\n"
            for entry in entries:
                ts = entry.get("ts", "")[:19]  # Truncate to datetime
                session_title = entry.get("session_title") or "Untitled"
                agent_type = entry.get("agent_type") or "unknown"
                summary = entry.get("summary", "")
                exchange_num = entry.get("exchange_number", 0)

                formatted += f"**{ts}** | {session_title} ({agent_type}) | Exchange #{exchange_num}\n"
                formatted += f"> {summary}\n\n"

            return {
                "content": [{"type": "text", "text": formatted}]
            }
        except Exception as e:
            logger.error(f"Error reading activity log: {e}")
            return {
                "content": [{"type": "text", "text": f"Error reading activity log: {e}"}],
                "is_error": True
            }

    @tool(
        "list_active_sessions",
        "List active (non-archived) sessions. Optionally filter by agent_type or module.",
        {"agent_type": str, "module": str, "limit": int}
    )
    async def list_active_sessions(args: dict[str, Any]) -> dict[str, Any]:
        """List active sessions with optional filtering."""
        agent_type = args.get("agent_type", "").strip() or None
        module = args.get("module", "").strip() or None
        limit = args.get("limit", 20)

        try:
            sessions = await database.list_sessions(
                agent_type=agent_type,
                module=module,
                archived=False,
                limit=limit,
            )

            if not sessions:
                return {
                    "content": [{"type": "text", "text": "No active sessions found"}]
                }

            # Format for display
            formatted = "# Active Sessions\n\n"
            for s in sessions:
                title = s.title or "Untitled"
                at = s.get_agent_type() or "unknown"
                msg_count = s.message_count
                last = s.last_accessed.strftime("%Y-%m-%d %H:%M")

                formatted += f"- **{title}** ({at})\n"
                formatted += f"  - ID: `{s.id[:8]}...`\n"
                formatted += f"  - Messages: {msg_count} | Last: {last}\n"
                formatted += f"  - Module: {s.module}\n\n"

            return {
                "content": [{"type": "text", "text": formatted}]
            }
        except Exception as e:
            logger.error(f"Error listing sessions: {e}")
            return {
                "content": [{"type": "text", "text": f"Error listing sessions: {e}"}],
                "is_error": True
            }

    @tool(
        "get_session_summary",
        "Get a summary of a specific session including recent activity.",
        {"session_id": str}
    )
    async def get_session_summary(args: dict[str, Any]) -> dict[str, Any]:
        """Get summary of a session."""
        session_id = args.get("session_id", "").strip()

        if not session_id:
            return {
                "content": [{"type": "text", "text": "Error: session_id is required"}],
                "is_error": True
            }

        try:
            session = await database.get_session(session_id)
            if not session:
                return {
                    "content": [{"type": "text", "text": f"Session not found: {session_id}"}]
                }

            # Get recent activity for this session
            recent_activity = []
            today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            log_file = activity_dir / f"{today}.jsonl"
            if log_file.exists():
                for line in log_file.read_text().strip().split("\n"):
                    if line.strip():
                        entry = json.loads(line)
                        if entry.get("session_id") == session_id:
                            recent_activity.append(entry)

            # Get references from metadata
            references = []
            if session.metadata:
                references = session.metadata.get("references", [])

            # Format output
            formatted = f"# Session: {session.title or 'Untitled'}\n\n"
            formatted += f"- **ID**: `{session.id}`\n"
            formatted += f"- **Agent Type**: {session.get_agent_type() or 'unknown'}\n"
            formatted += f"- **Module**: {session.module}\n"
            formatted += f"- **Messages**: {session.message_count}\n"
            formatted += f"- **Created**: {session.created_at.strftime('%Y-%m-%d %H:%M')}\n"
            formatted += f"- **Last Accessed**: {session.last_accessed.strftime('%Y-%m-%d %H:%M')}\n"

            if references:
                formatted += f"\n## References\n"
                for ref in references:
                    ref_id = ref.get("session_id", "")[:8]
                    ref_type = ref.get("type", "related")
                    ref_note = ref.get("note", "")
                    formatted += f"- `{ref_id}...` ({ref_type})"
                    if ref_note:
                        formatted += f": {ref_note}"
                    formatted += "\n"

            if recent_activity:
                formatted += f"\n## Recent Activity (today)\n"
                for entry in recent_activity[-5:]:
                    ts = entry.get("ts", "")[:19]
                    summary = entry.get("summary", "")
                    formatted += f"- {ts}: {summary}\n"

            return {
                "content": [{"type": "text", "text": formatted}]
            }
        except Exception as e:
            logger.error(f"Error getting session summary: {e}")
            return {
                "content": [{"type": "text", "text": f"Error getting session summary: {e}"}],
                "is_error": True
            }

    @tool(
        "add_session_reference",
        "Add a reference from one session to another to track relationships.",
        {"from_session_id": str, "to_session_id": str, "reference_type": str, "note": str}
    )
    async def add_session_reference(args: dict[str, Any]) -> dict[str, Any]:
        """Add a reference from one session to another."""
        from_id = args.get("from_session_id", "").strip()
        to_id = args.get("to_session_id", "").strip()
        ref_type = args.get("reference_type", "related").strip()
        note = args.get("note", "").strip()

        if not from_id or not to_id:
            return {
                "content": [{"type": "text", "text": "Error: from_session_id and to_session_id are required"}],
                "is_error": True
            }

        try:
            from parachute.models.session import SessionUpdate

            session = await database.get_session(from_id)
            if not session:
                return {
                    "content": [{"type": "text", "text": f"Session not found: {from_id}"}]
                }

            # Get existing references or create new list
            metadata = dict(session.metadata) if session.metadata else {}
            references = metadata.get("references", [])

            # Add new reference
            references.append({
                "session_id": to_id,
                "type": ref_type,
                "note": note,
                "added_at": datetime.now(timezone.utc).isoformat(),
            })

            metadata["references"] = references
            await database.update_session(from_id, SessionUpdate(metadata=metadata))

            return {
                "content": [{"type": "text", "text": f"Added {ref_type} reference from {from_id[:8]}... to {to_id[:8]}..."}]
            }
        except Exception as e:
            logger.error(f"Error adding session reference: {e}")
            return {
                "content": [{"type": "text", "text": f"Error adding session reference: {e}"}],
                "is_error": True
            }

    # Create the MCP server with all tools
    tools = [read_activity_log, list_active_sessions, get_session_summary, add_session_reference]
    server, server_config = create_sdk_mcp_server("orchestrator-tools", tools)

    return tools, server_config
