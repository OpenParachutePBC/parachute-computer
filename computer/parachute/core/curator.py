"""
Curator — Background Context Agent

Replaces session_summarizer.py. A persistent background agent (Claude Haiku)
that observes each chat exchange and updates: session title, summary, and
activity log via MCP tools.

Key design:
- Per-chat-session continuity: session.metadata["curator_session_id"] gives
  the curator its own SDK session, 1:1 with the chat session. The curator
  accumulates the full conversation context across all cadence exchanges.
- MCP writeback: the curator calls update_title / update_summary / log_activity
  as MCP tool calls — agent-native, transparent in the Flutter UI.
- Fire-and-forget: observe() never raises; all exceptions are caught.
"""

import logging
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from parachute.core.claude_sdk import query_streaming

logger = logging.getLogger(__name__)

# Cadence: always run on {1, 3, 5}, then every 10th exchange
_CURATOR_EXCHANGES = {1, 3, 5}
_CURATOR_INTERVAL = 10

CURATOR_SYSTEM_PROMPT = """You are a background context agent observing a conversation.

After each exchange, use your tools to keep the session context current.

You have three tools:
- update_title: Set a concise 3-8 word title capturing the main topic
- update_summary: Write 1-3 sentences summarizing what has been discussed so far
- log_activity: Append a brief note about what happened in this specific exchange

Guidelines:
- If told the title was set by the user, do NOT call update_title
- Always call update_summary and log_activity on every observation
- Be concise and factual — focus on what matters for future context
- Do not editorialize or speculate beyond what was discussed"""


def _should_update(exchange_number: int) -> bool:
    """Return True if this exchange warrants a curator run."""
    return (
        exchange_number in _CURATOR_EXCHANGES
        or (exchange_number > 5 and exchange_number % _CURATOR_INTERVAL == 0)
    )


async def observe(
    session_id: str,
    message: str,
    result_text: str,
    tool_calls: list[str],
    exchange_number: int,
    session_title: Optional[str],
    title_source: Optional[str],
    database: object,
    vault_path: Path,
    claude_token: Optional[str],
) -> None:
    """Fire-and-forget curator run. Never raises."""
    try:
        if not _should_update(exchange_number):
            return

        # Load curator session ID — 1:1 with the chat session
        session = await database.get_session(session_id)
        if session is None:
            logger.debug(f"Curator: session {session_id[:8]} not found, skipping")
            return

        curator_session_id: Optional[str] = (session.metadata or {}).get("curator_session_id")

        # Build the per-exchange prompt
        tools_str = ", ".join(tool_calls) if tool_calls else "None"
        truncated_user = message[:1000] + ("... [truncated]" if len(message) > 1000 else "")
        truncated_response = result_text[:2000] + (
            "... [truncated]" if len(result_text) > 2000 else ""
        )

        if title_source == "user":
            title_note = (
                f"Current title: {session_title!r} (user-set — do NOT call update_title)"
            )
        elif session_title:
            title_note = (
                f"Current title: {session_title!r} (AI-set — update if more accurate)"
            )
        else:
            title_note = "Current title: not yet set"

        prompt = (
            f"Observe exchange #{exchange_number} and update session context.\n\n"
            f"{title_note}\n\n"
            f"---\n"
            f"User: {truncated_user}\n\n"
            f"Tools used in this exchange: {tools_str}\n"
            f"Assistant: {truncated_response}\n"
            f"---\n\n"
            f"Call your tools to update the session context."
        )

        # Scoped MCP server for this curator run — bakes in the session ID
        mcp_servers = {
            "curator": {
                "command": sys.executable,
                "args": [
                    "-m", "parachute.core.curator_mcp",
                    "--session-id", session_id,
                    "--vault-path", str(vault_path),
                ],
                "env": {},
            }
        }

        new_session_id: Optional[str] = None
        tool_calls_made: list[str] = []
        new_title: Optional[str] = None

        async for event in query_streaming(
            prompt=prompt,
            system_prompt=CURATOR_SYSTEM_PROMPT,
            model="claude-haiku-4-5-20251001",
            use_claude_code_preset=False,
            resume=curator_session_id,
            mcp_servers=mcp_servers,
            setting_sources=[],
            tools=[],
            permission_mode="bypassPermissions",
            claude_token=claude_token,
        ):
            # Capture new SDK session ID on the first run (no resume yet)
            if (
                event.get("type") == "system"
                and event.get("session_id")
                and not curator_session_id
            ):
                new_session_id = event["session_id"]

            # Capture which MCP tools the curator called
            if event.get("type") == "assistant" and event.get("message"):
                for block in event["message"].get("content", []):
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_name = block.get("name", "")
                        if tool_name:
                            tool_calls_made.append(tool_name)
                            if tool_name == "update_title":
                                new_title = (block.get("input") or {}).get("title")

        # Write curator_session_id and curator_last_run to session metadata.
        # Re-fetch to avoid clobbering concurrent writes.
        refreshed = await database.get_session(session_id)
        if refreshed:
            from parachute.models.session import SessionUpdate

            fresh_meta = dict(refreshed.metadata or {})
            if new_session_id:
                fresh_meta["curator_session_id"] = new_session_id
            fresh_meta["curator_last_run"] = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "exchange_number": exchange_number,
                "actions": tool_calls_made,
                "new_title": new_title,
            }
            await database.update_session(session_id, SessionUpdate(metadata=fresh_meta))

        logger.debug(
            f"Curator ran for {session_id[:8]}: "
            f"exchange={exchange_number}, actions={tool_calls_made}"
        )

    except Exception as e:
        logger.debug(f"Curator failed for {session_id[:8]}: {e}")
