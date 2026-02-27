"""
Brain Bridge Agent — Unified pre/post-turn context agent.

Pre-turn (enrich) — awaited before the chat agent:
  - Haiku judges: enrich / step-back / pass-through
  - If enriching: translates explicit personal references → brain queries, injects context

Post-turn (observe) — fire-and-forget after the chat agent responds:
  - Session metadata: title, summary, activity log (via MCP tools — agent-native)
  - Brain writes are intentional only — the main chat agent calls brain MCP tools directly

Key design:
- One bridge_session_id per chat session (continuity across turns)
- MCP tools for session metadata (visible as tool calls in transcripts)
- Never raises — all failures are logged and swallowed
"""

import json
import logging
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from parachute.core.claude_sdk import query_streaming

logger = logging.getLogger(__name__)

# ── Prompts ──────────────────────────────────────────────────────────────────

BRIDGE_ENRICH_PROMPT = """You are a context enrichment pre-processor. Evaluate whether the user message contains an explicit reference to a specific person, project, organization, or commitment that might be in their knowledge graph.

Make ONE judgment:
- ENRICH: The message explicitly names a person, project, org, or commitment (e.g. "Kevin", "Woven Web", "the LVB cohort"). Generate 1-2 short keyword search queries to retrieve relevant context.
- STEP_BACK: The user is explicitly asking to search or explore their brain/knowledge graph directly. The chat agent will handle this intentionally.
- PASS_THROUGH: Everything else — general conversation, coding help, questions, tasks without personal references.

When in doubt, use PASS_THROUGH. Do not enrich on vague or generic messages.

If ENRICH: provide 1-2 short keyword search queries (keyword phrases, not full sentences).
If STEP_BACK or PASS_THROUGH: provide no queries.

Respond in JSON only (no markdown fences):
{"judgment": "enrich|step_back|pass_through", "queries": ["query1", "query2"]}"""

BRIDGE_OBSERVE_PROMPT = """You are a background observer for a conversation. After each exchange, update the session metadata using your tools.

- update_title: Set a concise 3-8 word title capturing the main topic. Call when the title is not yet set, or you have a meaningfully more accurate one. Do NOT call if the title was set by the user.
- update_summary: Write 1-3 sentences summarizing what has been discussed and accomplished so far. Call when no summary exists, or the current one is outdated. Skip if already accurate.
- log_activity: Always call. Write 1-2 sentences about what happened in this specific exchange.

Be concise. If the exchange was trivial (e.g. "thanks", "ok"), a brief log entry is enough — skip title/summary updates."""

# ── Token budget ──────────────────────────────────────────────────────────────

_MAX_CONTEXT_CHARS = 6000  # ~1500 tokens for injected brain context


# ── Enrich helpers ────────────────────────────────────────────────────────────

async def _run_haiku(
    prompt: str,
    system_prompt: str,
    claude_token: Optional[str],
) -> Optional[str]:
    """Run Haiku with a text-only prompt, return the text response."""
    text_parts: list[str] = []

    async for event in query_streaming(
        prompt=prompt,
        system_prompt=system_prompt,
        model="claude-haiku-4-5-20251001",
        use_claude_code_preset=False,
        setting_sources=[],
        tools=[],
        permission_mode="bypassPermissions",
        claude_token=claude_token,
    ):
        if event.get("type") == "assistant" and event.get("message"):
            for block in event["message"].get("content", []):
                if isinstance(block, dict) and block.get("type") == "text":
                    text_parts.append(block["text"])
        elif event.get("type") == "result" and event.get("result"):
            return event["result"]

    return "".join(text_parts) or None


def _parse_haiku_json(text: Optional[str]) -> Optional[dict[str, Any]]:
    """Parse JSON from Haiku response, stripping markdown fences if present."""
    if not text:
        return None
    stripped = text.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        inner = [l for l in lines[1:] if not l.startswith("```")]
        stripped = "\n".join(inner).strip()
    try:
        return json.loads(stripped)
    except (json.JSONDecodeError, ValueError):
        logger.debug(f"Bridge: failed to parse JSON: {stripped[:200]}")
        return None


def _format_context_block(query_results: list[dict[str, Any]]) -> str:
    """Format brain search results as a markdown block for system prompt injection."""
    if not query_results:
        return ""

    lines = [
        "## Brain Context",
        "",
        "The following context was retrieved from your knowledge graph based on the current conversation.",
        "",
    ]

    total_count = 0
    query_count = 0

    for bundle in query_results:
        query = bundle.get("query", "")
        results = bundle.get("results", [])
        if not results:
            continue
        query_count += 1
        lines.append(f'### From query: "{query}"')
        for r in results:
            name = r.get("name", "")
            rtype = r.get("type", "")
            desc = r.get("description", "")
            if name:
                entry = f"- **{name}**"
                if rtype:
                    entry += f" ({rtype})"
                if desc:
                    entry += f": {desc[:200]}"
                lines.append(entry)
                total_count += 1
        lines.append("")

    if total_count == 0:
        return ""

    lines.append(
        f"_Context loaded: {total_count} result{'s' if total_count != 1 else ''} "
        f"from {query_count} quer{'ies' if query_count != 1 else 'y'}._"
    )

    block = "\n".join(lines)
    if len(block) > _MAX_CONTEXT_CHARS:
        block = block[:_MAX_CONTEXT_CHARS] + "\n\n_[Context truncated to stay within token budget.]_"

    return block


# ── Observe helpers ───────────────────────────────────────────────────────────

def _summarize_tool_calls(tool_calls: list[dict]) -> str:
    """Build a readable summary of tool calls made during the exchange."""
    if not tool_calls:
        return "None"
    parts = []
    for tc in tool_calls:
        name = tc.get("name", "unknown")
        if "__" in name:
            name = name.rsplit("__", 1)[-1]
        inp = tc.get("input") or {}
        preview = _pick_preview(name, inp)
        parts.append(f"{name}({preview})" if preview else name)
    return ", ".join(parts)


def _pick_preview(tool_name: str, inp: dict) -> str:
    """Return a short preview string for a tool call input."""
    if not inp:
        return ""
    if tool_name in ("Read", "read"):
        return _short_path(inp.get("file_path", ""))
    if tool_name in ("Write", "write", "Edit", "edit", "MultiEdit"):
        return _short_path(inp.get("file_path", ""))
    if tool_name in ("Bash", "bash"):
        cmd = inp.get("command", "")
        return cmd[:50] if cmd else ""
    if tool_name in ("Glob", "glob"):
        return inp.get("pattern", "")[:40]
    if tool_name in ("Grep", "grep"):
        return inp.get("pattern", "")[:40]
    if tool_name in ("WebFetch", "web_fetch"):
        return inp.get("url", "")[:50]
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




# ── Public API ────────────────────────────────────────────────────────────────

async def enrich(
    message: str,
    session_summary: Optional[str],
    brain: Any,
    claude_token: Optional[str],
    vault_path: object,
) -> Optional[str]:
    """Pre-hook: runs before the chat agent. Returns context string or None.

    Never raises — bridge failure must not crash the chat flow.
    """
    if brain is None:
        return None

    try:
        if len(message.split()) < 5:
            logger.info("Bridge enrich: short message, skipping")
            return None

        summary_section = f"\nConversation summary: {session_summary}" if session_summary else ""
        prompt = (
            f"User message: {message[:500]}"
            f"{summary_section}\n\n"
            f"Make your judgment."
        )

        response_text = await _run_haiku(prompt, BRIDGE_ENRICH_PROMPT, claude_token)
        parsed = _parse_haiku_json(response_text)

        if not parsed:
            logger.warning("Bridge enrich: failed to parse Haiku judgment, pass-through")
            return None

        judgment = parsed.get("judgment", "pass_through")
        logger.info(f"Bridge enrich: judgment={judgment}")

        if judgment == "pass_through":
            return None

        if judgment == "step_back":
            logger.info("Bridge enrich: step-back — chat agent will query brain directly")
            return "_Brain context: stepping back — you are directly querying your knowledge graph._"

        # judgment == "enrich"
        queries = parsed.get("queries", [])[:3]
        if not queries:
            return None

        query_results = []
        for q in queries:
            try:
                bundle = await brain.recall(query=q, num_results=5)
                count = bundle.get("count", 0)
                logger.info(f"Bridge enrich: query={q!r} -> {count} results")
                if count > 0:
                    query_results.append(bundle)
            except Exception as e:
                logger.warning(f"Bridge enrich: recall failed for {q!r}: {e}")

        if not query_results:
            logger.info("Bridge enrich: no results found, pass-through")
            return None

        block = _format_context_block(query_results)
        logger.info(f"Bridge enrich: injecting {len(block)} chars of brain context")
        return block or None

    except Exception as e:
        logger.warning(f"Bridge enrich failed (non-fatal): {e}")
        return None


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
    """Fire-and-forget post-turn observer.

    Handles session metadata (title, summary, activity log) via MCP tools.
    Brain writes are intentional only — the main chat agent calls brain MCP tools directly.

    Never raises.
    """
    try:
        session = await database.get_session(session_id)
        if session is None:
            logger.debug(f"Bridge observe: session {session_id[:8]} not found, skipping")
            return

        bridge_session_id: Optional[str] = session.bridge_session_id

        # Build title / summary notes
        if title_source == "user":
            title_note = f"Current title: {session_title!r} (user-set — do NOT call update_title)"
        elif session_title:
            title_note = f"Current title: {session_title!r} (AI-set — update only if more accurate)"
        else:
            title_note = "Current title: not yet set"

        current_summary = session.summary
        summary_note = (
            f"Current summary: {current_summary}" if current_summary else "Current summary: not yet set"
        )

        tools_str = _summarize_tool_calls(tool_calls)
        truncated_user = message[:1000] + ("... [truncated]" if len(message) > 1000 else "")
        truncated_response = result_text[:2000] + ("... [truncated]" if len(result_text) > 2000 else "")

        prompt = (
            f"Observe exchange #{exchange_number} and update session context.\n\n"
            f"{title_note}\n"
            f"{summary_note}\n\n"
            f"---\n"
            f"User: {truncated_user}\n\n"
            f"Tools used: {tools_str}\n"
            f"Assistant: {truncated_response}\n"
            f"---\n\n"
            f"Call log_activity for this exchange, update title/summary if needed, "
            f"then output a BRAIN_FACTS JSON block."
        )

        # MCP server for session metadata tools
        mcp_servers = {
            "bridge": {
                "command": sys.executable,
                "args": [
                    "-m", "parachute.core.bridge_mcp",
                    "--session-id", session_id,
                    "--vault-path", str(vault_path),
                ],
            }
        }

        new_session_id: Optional[str] = None
        tool_calls_made: list[str] = []
        new_title: Optional[str] = None
        text_parts: list[str] = []

        async for event in query_streaming(
            prompt=prompt,
            system_prompt=BRIDGE_OBSERVE_PROMPT,
            model="claude-haiku-4-5-20251001",
            use_claude_code_preset=False,
            resume=bridge_session_id,
            mcp_servers=mcp_servers,
            setting_sources=[],
            tools=[],
            permission_mode="bypassPermissions",
            claude_token=claude_token,
        ):
            if (
                event.get("type") == "system"
                and event.get("session_id")
                and not bridge_session_id
            ):
                new_session_id = event["session_id"]

            if event.get("type") == "assistant" and event.get("message"):
                for block in event["message"].get("content", []):
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_name = block.get("name", "")
                        # Strip mcp__bridge__ prefix
                        short_name = tool_name.removeprefix("mcp__bridge__") if tool_name else ""
                        if short_name:
                            tool_calls_made.append(short_name)
                            if short_name == "update_title":
                                new_title = (block.get("input") or {}).get("title")
                    elif isinstance(block, dict) and block.get("type") == "text":
                        text_parts.append(block["text"])

            elif event.get("type") == "result" and event.get("result"):
                text_parts.append(event["result"])

        # Persist bridge_session_id and bridge_last_run metadata
        refreshed = await database.get_session(session_id)
        if refreshed:
            from parachute.models.session import SessionUpdate

            fresh_meta = dict(refreshed.metadata or {})
            fresh_meta["bridge_last_run"] = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "exchange_number": exchange_number,
                "actions": tool_calls_made,
                "new_title": new_title,
            }
            update = SessionUpdate(metadata=fresh_meta)
            if new_session_id:
                update.bridge_session_id = new_session_id

            await database.update_session(session_id, update)

        logger.info(
            f"Bridge observe ran for {session_id[:8]}: "
            f"exchange={exchange_number}, actions={tool_calls_made}"
        )

    except Exception as e:
        logger.warning(f"Bridge observe failed for {session_id[:8]}: {e}")
