"""
Brain Bridge Agent — Ambient context enrichment pre-hook.

Runs before the chat agent on every user message.
Makes a fast intent judgment (Haiku) and optionally injects
brain context into the chat agent's system prompt.

Post-turn write-back runs as fire-and-forget (like curator).

Three modes:
- ENRICH: Translate vague references to brain queries, inject context.
- STEP_BACK: User is explicitly querying brain — load minimal orientation only.
- PASS_THROUGH: Normal conversation, no brain involvement needed.
"""

import json
import logging
from datetime import datetime, timezone
from typing import Any, Optional

from parachute.core.claude_sdk import query_streaming

logger = logging.getLogger(__name__)

BRIDGE_ENRICH_PROMPT = """You are a context enrichment assistant. Evaluate the user message and conversation summary below.

Make ONE judgment:
- ENRICH: The user is making a request the chat agent will handle. You should translate vague references
  into specific brain search queries to load relevant context.
- STEP_BACK: The user explicitly wants to query or explore their brain/knowledge graph directly.
  The chat agent will do this intentionally. Do not pre-load context.
- PASS_THROUGH: Normal conversation with no brain involvement needed.

If ENRICH: provide 1-3 short keyword search queries (not full sentences — keyword phrases work best).
If STEP_BACK or PASS_THROUGH: provide no queries.

Respond in JSON only (no markdown fences):
{"judgment": "enrich|step_back|pass_through", "queries": ["query1", "query2"]}"""

BRIDGE_WRITEBACK_PROMPT = """You are a knowledge graph curator. Review the exchange below and decide:
1. Was anything significant said? (commitment, decision, new relationship, fact about a person/project)
2. If yes: what should be stored in the knowledge graph?

Respond in JSON only (no markdown fences):
{"should_store": true, "entities": [{"entity_type": "...", "name": "...", "description": "..."}]}

Only store clear, durable facts. Do not store conversational filler or ephemeral details."""

# Token budget for injected brain context
_MAX_CONTEXT_CHARS = 6000  # ~1500 tokens


async def _run_haiku(
    prompt: str,
    system_prompt: str,
    claude_token: Optional[str],
) -> Optional[str]:
    """Run Haiku with a simple text prompt and return the text response.

    Drains the query_streaming generator and collects all text from
    assistant message blocks. Returns None on empty response.
    """
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
            # Prefer the final result event if present
            return event["result"]

    return "".join(text_parts) or None


def _parse_haiku_json(text: Optional[str]) -> Optional[dict[str, Any]]:
    """Parse JSON from Haiku response, stripping markdown fences if present."""
    if not text:
        return None
    stripped = text.strip()
    # Strip ```json ... ``` or ``` ... ``` fences
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        inner = [l for l in lines[1:] if not l.startswith("```")]
        stripped = "\n".join(inner).strip()
    try:
        return json.loads(stripped)
    except (json.JSONDecodeError, ValueError):
        logger.debug(f"Bridge: failed to parse Haiku JSON: {stripped[:200]}")
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

    lines.append(f"_Context loaded: {total_count} result{'s' if total_count != 1 else ''} from {query_count} quer{'ies' if query_count != 1 else 'y'}._")

    block = "\n".join(lines)
    # Enforce token budget
    if len(block) > _MAX_CONTEXT_CHARS:
        block = block[:_MAX_CONTEXT_CHARS] + "\n\n_[Context truncated to stay within token budget.]_"

    return block


async def enrich(
    message: str,
    session_summary: Optional[str],
    brain: Any,
    claude_token: Optional[str],
    vault_path: object,
) -> Optional[str]:
    """Pre-hook: runs before the chat agent.

    Returns a context string to inject into the system prompt, or None.
    Never raises — bridge failure must not crash the chat flow.
    """
    if brain is None:
        return None

    try:
        # Short-circuit: skip bridge for very short messages (< 5 words)
        if len(message.split()) < 5:
            logger.debug("Bridge enrich: short message, pass-through")
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
            logger.debug("Bridge enrich: failed to parse judgment, pass-through")
            return None

        judgment = parsed.get("judgment", "pass_through")
        logger.debug(f"Bridge enrich: judgment={judgment}")

        if judgment == "pass_through":
            return None

        if judgment == "step_back":
            return "_Brain context: stepping back — you are directly querying your knowledge graph._"

        # judgment == "enrich"
        queries = parsed.get("queries", [])[:3]  # max 3 queries
        if not queries:
            return None

        query_results = []
        for q in queries:
            try:
                bundle = await brain.recall(query=q, num_results=5)
                if bundle.get("count", 0) > 0:
                    query_results.append(bundle)
            except Exception as e:
                logger.debug(f"Bridge enrich: recall failed for {q!r}: {e}")

        if not query_results:
            return None

        block = _format_context_block(query_results)
        logger.debug(f"Bridge enrich: injecting {len(block)} chars of context")
        return block or None

    except Exception as e:
        logger.debug(f"Bridge enrich failed: {e}")
        return None


async def writeback(
    session_id: str,
    message: str,
    result_text: str,
    brain: Any,
    claude_token: Optional[str],
    database: Any,
) -> None:
    """Post-turn: fire-and-forget after chat agent response.

    Stores significant facts to brain and updates bridge_context_log.
    Never raises.
    """
    if brain is None:
        return

    try:
        truncated_user = message[:800] + ("... [truncated]" if len(message) > 800 else "")
        truncated_response = result_text[:1500] + ("... [truncated]" if len(result_text) > 1500 else "")

        prompt = (
            f"User: {truncated_user}\n\n"
            f"Assistant: {truncated_response}\n\n"
            f"Should any facts from this exchange be stored in the knowledge graph?"
        )

        response_text = await _run_haiku(prompt, BRIDGE_WRITEBACK_PROMPT, claude_token)
        parsed = _parse_haiku_json(response_text)

        if not parsed or not parsed.get("should_store"):
            logger.debug(f"Bridge writeback: nothing to store for {session_id[:8]}")
            return

        entities = parsed.get("entities", [])
        stored = []

        for entity in entities:
            entity_type = entity.get("entity_type", "").strip()
            name = entity.get("name", "").strip()
            description = entity.get("description", "").strip()

            if not entity_type or not name:
                continue

            try:
                await brain.upsert_entity(
                    entity_type=entity_type,
                    name=name,
                    attributes={"description": description} if description else {},
                )
                stored.append({"type": entity_type, "name": name})
                logger.debug(f"Bridge writeback: stored {entity_type}/{name}")
            except Exception as e:
                logger.debug(f"Bridge writeback: upsert failed for {name!r}: {e}")

        if stored:
            # Append to session's bridge_context_log
            session = await database.get_session(session_id)
            if session:
                from parachute.models.session import SessionUpdate

                existing_log: list[dict] = []
                if session.bridge_context_log:
                    try:
                        existing_log = json.loads(session.bridge_context_log)
                    except (json.JSONDecodeError, ValueError):
                        pass

                existing_log.append({
                    "ts": datetime.now(timezone.utc).isoformat(),
                    "type": "writeback",
                    "stored": stored,
                })

                await database.update_session(
                    session_id,
                    SessionUpdate(bridge_context_log=json.dumps(existing_log)),
                )

        logger.debug(f"Bridge writeback: stored {len(stored)} entities for {session_id[:8]}")

    except Exception as e:
        logger.debug(f"Bridge writeback failed for {session_id[:8]}: {e}")
