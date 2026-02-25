"""
Curator — Background Context Agent

A persistent background agent (Claude Haiku) that observes each chat exchange
and updates: session title, summary, and activity log via MCP tools.

Key design:
- Per-chat-session continuity: session.curator_session_id gives the curator its
  own SDK session, 1:1 with the chat session. The curator accumulates the full
  conversation context across all runs.
- MCP writeback: the curator calls update_title / update_summary / log_activity
  as MCP tool calls — agent-native, transparent in the Flutter UI.
- Fire-and-forget: observe() never raises; all exceptions are caught.
- Runs after every exchange (no cadence gating — the curator decides internally
  whether anything needs updating).
"""

import logging
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from parachute.core.claude_sdk import query_streaming

logger = logging.getLogger(__name__)

CURATOR_SYSTEM_PROMPT = """You are a background context agent observing a conversation.

After each exchange, honestly assess whether the session context needs updating, then call the appropriate tools.

You have three tools:

- update_title: Set a concise 3-8 word title capturing the main topic.
  Call this when: the title is not yet set, or you have a meaningfully more accurate title.
  Do NOT call if the title was set by the user, or if the current AI-set title is already accurate.

- update_summary: Write 1-3 sentences summarizing what has been discussed and accomplished so far.
  Call this when: there is no summary yet, or the current summary no longer reflects the conversation.
  Skip if the summary is already up to date.

- log_activity: Append a brief note about what happened in this specific exchange.
  Always call this — it records what was worked on today within this session.
  Write 1-2 sentences about what was accomplished or discussed in this specific exchange.

Guidelines:
- Be concise and factual — focus on what matters for future context
- Do not editorialize or speculate beyond what was discussed
- If the exchange was trivial (e.g. "thanks", "ok"), a minimal log entry is fine; skip title/summary updates"""


def _summarize_tool_calls(tool_calls: list[dict]) -> str:
    """Build a readable summary of tool calls made during the exchange.

    Formats each call as 'ToolName(key_arg_preview)' — enough context for the
    curator to understand what happened without dumping full inputs.
    """
    if not tool_calls:
        return "None"

    parts = []
    for tc in tool_calls:
        name = tc.get("name", "unknown")
        # Strip mcp__ prefix if present (e.g. mcp__server__tool -> tool)
        if "__" in name:
            name = name.rsplit("__", 1)[-1]

        inp = tc.get("input") or {}
        # Pick the most meaningful argument to show as a preview
        preview = _pick_preview(name, inp)
        if preview:
            parts.append(f"{name}({preview})")
        else:
            parts.append(name)

    return ", ".join(parts)


def _pick_preview(tool_name: str, inp: dict) -> str:
    """Return a short preview string for a tool call input."""
    if not inp:
        return ""

    # Known patterns
    if tool_name in ("Read", "read"):
        path = inp.get("file_path", "")
        return _short_path(path)
    if tool_name in ("Write", "write"):
        path = inp.get("file_path", "")
        return _short_path(path)
    if tool_name in ("Edit", "edit", "MultiEdit"):
        path = inp.get("file_path", "")
        return _short_path(path)
    if tool_name in ("Bash", "bash"):
        cmd = inp.get("command", "")
        return cmd[:50] if cmd else ""
    if tool_name in ("Glob", "glob"):
        return inp.get("pattern", "")[:40]
    if tool_name in ("Grep", "grep"):
        return inp.get("pattern", "")[:40]
    if tool_name in ("WebFetch", "web_fetch"):
        url = inp.get("url", "")
        return url[:50] if url else ""

    # Generic fallback: first string value, truncated
    for v in inp.values():
        if isinstance(v, str) and v:
            return v[:40]
    return ""


def _short_path(path: str) -> str:
    """Return just the last two path components."""
    if not path:
        return ""
    parts = path.replace("\\", "/").rstrip("/").split("/")
    return "/".join(parts[-2:]) if len(parts) > 1 else parts[-1]


async def observe(
    session_id: str,
    message: str,
    result_text: str,
    tool_calls: list[dict],
    exchange_number: int,
    session_title: Optional[str],
    title_source: Optional[str],
    database: object,
    vault_path: Path,
    claude_token: Optional[str],
) -> None:
    """Fire-and-forget curator run. Never raises."""
    try:
        # Load curator session ID — 1:1 with the chat session
        session = await database.get_session(session_id)
        if session is None:
            logger.debug(f"Curator: session {session_id[:8]} not found, skipping")
            return

        curator_session_id: Optional[str] = session.curator_session_id

        # Build title note
        if title_source == "user":
            title_note = (
                f"Current title: {session_title!r} (user-set — do NOT call update_title)"
            )
        elif session_title:
            title_note = (
                f"Current title: {session_title!r} (AI-set — update only if more accurate)"
            )
        else:
            title_note = "Current title: not yet set"

        # Build current summary note
        current_summary = session.summary
        if current_summary:
            summary_note = f"Current summary: {current_summary}"
        else:
            summary_note = "Current summary: not yet set"

        # Build tool summary
        tools_str = _summarize_tool_calls(tool_calls)

        # Truncate user message and response for context
        truncated_user = message[:1000] + ("... [truncated]" if len(message) > 1000 else "")
        truncated_response = result_text[:2000] + (
            "... [truncated]" if len(result_text) > 2000 else ""
        )

        prompt = (
            f"Observe exchange #{exchange_number} and update session context.\n\n"
            f"{title_note}\n"
            f"{summary_note}\n\n"
            f"---\n"
            f"User: {truncated_user}\n\n"
            f"Tools used: {tools_str}\n"
            f"Assistant: {truncated_response}\n"
            f"---\n\n"
            f"Assess whether title/summary need updating, then call log_activity for this exchange."
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

            # Capture which MCP tools the curator called.
            # Claude Code emits tool names as mcp__<server>__<tool>, e.g.
            # mcp__curator__update_title — strip the prefix for clean storage.
            if event.get("type") == "assistant" and event.get("message"):
                for block in event["message"].get("content", []):
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_name = block.get("name", "")
                        short_name = tool_name.removeprefix("mcp__curator__") if tool_name else ""
                        if short_name:
                            tool_calls_made.append(short_name)
                            if short_name == "update_title":
                                new_title = (block.get("input") or {}).get("title")

        # Write curator_session_id (proper column) and curator_last_run (metadata JSON).
        # Re-fetch to avoid clobbering concurrent writes on metadata.
        refreshed = await database.get_session(session_id)
        if refreshed:
            from parachute.models.session import SessionUpdate

            fresh_meta = dict(refreshed.metadata or {})
            fresh_meta["curator_last_run"] = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "exchange_number": exchange_number,
                "actions": tool_calls_made,
                "new_title": new_title,
            }
            update = SessionUpdate(metadata=fresh_meta)
            if new_session_id:
                update.curator_session_id = new_session_id
            await database.update_session(session_id, update)

        logger.debug(
            f"Curator ran for {session_id[:8]}: "
            f"exchange={exchange_number}, actions={tool_calls_made}"
        )

    except Exception as e:
        logger.debug(f"Curator failed for {session_id[:8]}: {e}")
