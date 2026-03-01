"""
Brain Bridge Agent — Unified pre/post-turn context agent.

Pre-turn (enrich) — currently paused, returns None immediately.

Post-turn (observe) — fire-and-forget after the chat agent responds:
  - Haiku analyzes the exchange via structured JSON output (no MCP subprocess)
  - Python handles all side effects: activity log, SQLite session updates,
    LadybugDB exchange storage

Key design:
- One bridge_session_id per chat session (Haiku continuity across turns)
- Structured output for Haiku → Python side effects (not MCP tools)
- Never raises — all failures are logged and swallowed
"""

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

from parachute.core.claude_sdk import query_streaming

logger = logging.getLogger(__name__)

# ── Exchange storage limits ───────────────────────────────────────────────────
# Full messages are stored (voice transcripts can be 7000+ chars).
# Only the description field (BM25 search target) is truncated.

_DESC_USER_LIMIT = 300       # chars of user message in description (search target)
_DESC_AI_LIMIT = 500         # chars of AI response in description (search target)

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

BRIDGE_OBSERVE_PROMPT = """You are a background observer for a chat conversation. After each exchange, analyze what happened and return structured metadata.

Your response will be used to:
1. Update the session title and summary in the database
2. Log what happened to a daily activity journal
3. Store a searchable record of this exchange in the knowledge graph

Guidelines:
- activity: ALWAYS provide. 1-2 sentences about what happened in this specific exchange.
- exchange_description: A concise description of this exchange suitable for search retrieval. What was discussed, decided, or accomplished.
- title: Set a concise 3-8 word title capturing the main topic. Set to null if the current title is already accurate.
- summary: 1-3 sentences summarizing the FULL conversation so far (not just this exchange). Set to null if the current summary is still accurate.

Be concise. For trivial exchanges ("thanks", "ok"), a brief activity entry is enough — leave title and summary as null."""

# JSON schema for structured output from observe
OBSERVE_OUTPUT_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {
            "type": ["string", "null"],
            "description": "New session title (3-8 words), or null to keep current",
        },
        "summary": {
            "type": ["string", "null"],
            "description": "Updated conversation summary (1-3 sentences), or null to keep current",
        },
        "activity": {
            "type": "string",
            "description": "What happened in this specific exchange (1-2 sentences)",
        },
        "exchange_description": {
            "type": "string",
            "description": "Concise description of this exchange for search retrieval",
        },
    },
    "required": ["activity", "exchange_description"],
}

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



def _write_activity_log(
    vault_path: Path,
    session_id: str,
    session_title: Optional[str],
    exchange_number: int,
    summary: str,
) -> None:
    """Append a JSONL entry to the daily activity log.

    File: vault/Daily/.activity/{YYYY-MM-DD}.jsonl
    Synchronous I/O — fast enough for a single line append.
    """
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    log_dir = vault_path / "Daily" / ".activity"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / f"{today}.jsonl"

    entry = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "session_id": session_id,
        "session_title": session_title,
        "exchange_number": exchange_number,
        "summary": summary,
    }
    with open(log_file, "a") as f:
        f.write(json.dumps(entry) + "\n")


# ── Exchange storage ─────────────────────────────────────────────────────────

async def _store_exchange(
    session_id: str,
    exchange_number: int,
    message: str,
    result_text: str,
    tool_calls: list[dict],
    brain: Any,
    activity_summary: Optional[str] = None,
    session_summary: Optional[str] = None,
    session_title: Optional[str] = None,
) -> None:
    """Write this exchange to LadybugDB for long-term retrieval.

    Stores full user message and AI response (no truncation — voice transcripts
    can be 7000+ chars and contain high-fidelity information).

    The description uses Haiku's log_activity summary when available (already
    generated during observe — no extra LLM call). Falls back to truncated
    snippets if Haiku didn't produce a summary.

    The context field captures the session summary at time of exchange, giving
    each exchange a "what was happening when this was said" anchor. Without it,
    "User: Yes | AI: [detailed plan]" is meaningless.

    Skips trivial exchanges (very short user message AND very short AI response).
    """
    if len(message.split()) < 3 and len(result_text.split()) < 10:
        logger.debug("Bridge: skipping trivial exchange for storage")
        return

    exchange_name = f"{session_id[:8]}:ex:{exchange_number}"

    # Prefer Haiku's curated summary; fall back to truncated snippets
    if activity_summary:
        description = activity_summary
    else:
        user_snippet = message[:_DESC_USER_LIMIT]
        ai_snippet = result_text[:_DESC_AI_LIMIT]
        description = f"User: {user_snippet} | AI: {ai_snippet}"

    attrs: dict[str, Any] = {
        "description": description,
        "session_id": session_id,
        "exchange_number": str(exchange_number),
        "user_message": message,
        "ai_response": result_text,
    }

    if session_summary:
        attrs["context"] = session_summary
    if session_title:
        attrs["session_title"] = session_title

    tools_summary = _summarize_tool_calls(tool_calls)
    if tools_summary and tools_summary != "None":
        attrs["tools_used"] = tools_summary

    await brain.upsert_entity(
        entity_type="Chat_Exchange",
        name=exchange_name,
        attributes=attrs,
    )
    logger.debug(f"Bridge: stored exchange {exchange_name}")


# ── Public API ────────────────────────────────────────────────────────────────

async def enrich(
    message: str,
    session_summary: Optional[str],
    brain: Any,
    claude_token: Optional[str],
    vault_path: object,
) -> Optional[str]:
    """Pre-hook: runs before the chat agent. Returns context string or None.

    Currently paused — returns None immediately. The enrich concept (pre-turn
    brain context injection) needs more thought on when and how to trigger it
    without adding latency to every exchange.

    Never raises — bridge failure must not crash the chat flow.
    """
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

    Uses structured output (JSON schema) instead of MCP tools. Haiku analyzes
    the exchange and returns a structured response. Python handles all side
    effects: SQLite session updates, activity log JSONL, brain exchange storage.

    The long-running session context (resume) gives Haiku memory across exchanges
    so it can make better judgments about title/summary updates.

    Never raises.
    """
    try:
        session = await database.get_session(session_id)
        if session is None:
            logger.debug(f"Bridge observe: session {session_id[:8]} not found, skipping")
            return

        bridge_session_id: Optional[str] = session.bridge_session_id
        current_summary = session.summary

        # Build context notes for the prompt
        if title_source == "user":
            title_note = f"Current title: {session_title!r} (user-set — do NOT update)"
        elif session_title:
            title_note = f"Current title: {session_title!r} (AI-set — update only if more accurate)"
        else:
            title_note = "Current title: not yet set"

        summary_note = (
            f"Current summary: {current_summary}" if current_summary else "Current summary: not yet set"
        )

        # Build the full exchange context
        tools_str = _summarize_tool_calls(tool_calls)
        prompt = (
            f"Observe exchange #{exchange_number} and return structured metadata.\n\n"
            f"{title_note}\n"
            f"{summary_note}\n\n"
            f"---\n"
            f"User: {message}\n\n"
            f"Tools used: {tools_str}\n\n"
            f"Assistant: {result_text}\n"
            f"---"
        )

        # Call Haiku with structured output — no MCP subprocess needed
        new_session_id: Optional[str] = None
        structured_data: Optional[dict[str, Any]] = None

        async for event in query_streaming(
            prompt=prompt,
            system_prompt=BRIDGE_OBSERVE_PROMPT,
            model="claude-haiku-4-5-20251001",
            use_claude_code_preset=False,
            resume=bridge_session_id,
            setting_sources=[],
            tools=[],
            permission_mode="bypassPermissions",
            claude_token=claude_token,
            output_format={"type": "json_schema", "schema": OBSERVE_OUTPUT_SCHEMA},
        ):
            if (
                event.get("type") == "system"
                and event.get("session_id")
                and not bridge_session_id
            ):
                new_session_id = event["session_id"]

            if event.get("type") == "result":
                structured_data = event.get("structured_output")

        # ── Side effects: all handled in Python ──────────────────────────

        new_title: Optional[str] = None
        activity_summary: Optional[str] = None
        actions: list[str] = []

        if structured_data:
            activity_summary = structured_data.get("activity")
            new_title = structured_data.get("title")
            new_summary = structured_data.get("summary")

            # 1. Activity log (JSONL append)
            if activity_summary:
                actions.append("log_activity")
                _write_activity_log(
                    vault_path=vault_path,
                    session_id=session_id,
                    session_title=session_title,
                    exchange_number=exchange_number,
                    summary=activity_summary,
                )

            # 2. Session title/summary updates (SQLite)
            from parachute.models.session import SessionUpdate
            session_update = SessionUpdate()
            needs_update = False

            if new_title and title_source != "user":
                session_update.title = new_title
                actions.append("update_title")
                needs_update = True

            if new_summary:
                session_update.summary = new_summary
                actions.append("update_summary")
                needs_update = True

            if needs_update:
                await database.update_session(session_id, session_update)

        # 3. Persist bridge_session_id and bridge_last_run metadata
        refreshed = await database.get_session(session_id)
        if refreshed:
            fresh_meta = dict(refreshed.metadata or {})
            fresh_meta["bridge_last_run"] = {
                "ts": datetime.now(timezone.utc).isoformat(),
                "exchange_number": exchange_number,
                "actions": actions,
                "new_title": new_title,
            }
            meta_update = SessionUpdate(metadata=fresh_meta)
            if new_session_id:
                meta_update.bridge_session_id = new_session_id

            await database.update_session(session_id, meta_update)

        logger.info(
            f"Bridge observe ran for {session_id[:8]}: "
            f"exchange={exchange_number}, actions={actions}"
        )

        # 4. Store exchange in LadybugDB for long-term retrieval
        try:
            from parachute.core.interfaces import get_registry
            brain = get_registry().get("BrainInterface")
            if brain:
                await _store_exchange(
                    session_id=session_id,
                    exchange_number=exchange_number,
                    message=message,
                    result_text=result_text,
                    tool_calls=tool_calls,
                    brain=brain,
                    activity_summary=(
                        structured_data.get("exchange_description")
                        if structured_data else None
                    ),
                    session_summary=current_summary,
                    session_title=session_title,
                )
        except Exception as store_err:
            logger.debug(f"Bridge: exchange store failed (non-fatal): {store_err}")

    except Exception as e:
        logger.warning(f"Bridge observe failed for {session_id[:8]}: {e}")
