"""
Chat memory retrieval — shared handlers for MCP tools.

Three tools for chat memory access:
- search_chats: Search across all chats by keyword, bundled with matching exchanges
- get_chat: Browse a specific chat with paginated exchanges
- get_exchange: Get full untruncated exchange content

These handlers are used by both the direct MCP server (mcp_server.py)
and the sandbox HTTP bridge (api/mcp_tools.py).
"""

from __future__ import annotations

import logging
from typing import Any

from parachute.db.brain import BrainService

logger = logging.getLogger(__name__)

# Snippet window: chars before + after the match
_SNIPPET_WINDOW = 300

# Max exchange matches to fetch per search (prevents runaway queries)
_MAX_EXCHANGE_MATCHES = 100

# Base filters: non-archived, human-initiated sessions only
_BASE_CHAT_FILTERS = (
    "(s.archived IS NULL OR s.archived = false) "
    "AND (s.source = 'parachute' AND (s.agent_type IS NULL OR s.agent_type = 'orchestrator'))"
)


def _extract_snippet(content: str, query: str, window: int = _SNIPPET_WINDOW) -> str:
    """Extract a snippet centered around the first match.

    Case-insensitive match. Falls back to the first `window` chars
    if no match is found.
    """
    if not content:
        return ""
    pos = content.lower().find(query.lower())
    if pos < 0:
        return content[:window] + ("..." if len(content) > window else "")
    half = window // 2
    start = max(0, pos - half)
    end = min(len(content), pos + len(query) + half)
    snippet = content[start:end]
    if start > 0:
        snippet = "..." + snippet
    if end < len(content):
        snippet = snippet + "..."
    return snippet


def _truncate(text: str | None, max_chars: int) -> str:
    """Truncate text to max_chars, appending '...' if cut."""
    if not text:
        return ""
    if len(text) <= max_chars:
        return text
    return text[:max_chars] + "..."


def _determine_match_field(
    query: str,
    user_message: str | None,
    ai_response: str | None,
    description: str | None,
) -> str:
    """Determine which field contains the match (case-insensitive)."""
    q = query.lower()
    # Prefer description (curated summary) > user_message > ai_response
    if description and q in description.lower():
        return "description"
    if user_message and q in user_message.lower():
        return "user_message"
    if ai_response and q in ai_response.lower():
        return "ai_response"
    return "description"  # fallback


async def search_chats(
    graph: BrainService,
    query: str,
    limit: int = 10,
    module: str | None = None,
) -> dict[str, Any]:
    """Search across all chats by keyword, returning bundled results.

    Returns chats grouped with their matching exchanges underneath.
    Each exchange includes snippets from the matching field so the caller
    can decide whether to drill deeper with get_exchange.
    """
    query = query.strip()
    if not query:
        return {"error": "Query cannot be empty"}

    limit = max(1, min(limit, 50))

    module_filter = ""
    params: dict[str, Any] = {"query": query}
    if module:
        module_filter = " AND s.module = $module"
        params["module"] = module

    # --- 1. Chat title/summary search ---
    title_rows = await graph.execute_cypher(
        f"MATCH (s:Chat) "
        f"WHERE {_BASE_CHAT_FILTERS}{module_filter} "
        f"AND (s.title CONTAINS $query "
        f"     OR (s.summary IS NOT NULL AND s.summary CONTAINS $query)) "
        f"RETURN s ORDER BY s.last_accessed DESC LIMIT {limit}",
        params,
    )

    # Build initial chat results from title/summary matches
    chats_by_sid: dict[str, dict[str, Any]] = {}
    for row in title_rows:
        sid = row.get("session_id", "")
        title = row.get("title") or "Untitled"
        summary = row.get("summary") or ""

        # Determine match_source
        q_lower = query.lower()
        if title and q_lower in title.lower():
            match_source = "title"
        else:
            match_source = "summary"

        chats_by_sid[sid] = {
            "session_id": sid,
            "title": title,
            "summary": summary,
            "module": row.get("module", "chat"),
            "last_accessed": row.get("last_accessed") or row.get("created_at") or "",
            "match_source": match_source,
            "matching_exchanges": [],
        }

    # --- 2. Exchange content search ---
    exchange_rows = await graph.execute_cypher(
        f"MATCH (s:Chat)-[:HAS_EXCHANGE]->(e:Exchange) "
        f"WHERE {_BASE_CHAT_FILTERS}{module_filter} "
        f"AND (e.user_message CONTAINS $query "
        f"     OR e.ai_response CONTAINS $query "
        f"     OR e.description CONTAINS $query) "
        f"RETURN s.session_id AS session_id, s.title AS title, "
        f"       s.summary AS summary, s.last_accessed AS last_accessed, "
        f"       s.module AS module, "
        f"       e.exchange_id AS exchange_id, "
        f"       e.exchange_number AS exchange_number, "
        f"       e.description AS description, "
        f"       e.user_message AS user_message, "
        f"       e.ai_response AS ai_response "
        f"ORDER BY s.last_accessed DESC, e.exchange_number ASC "
        f"LIMIT {_MAX_EXCHANGE_MATCHES}",
        params,
    )

    # Group exchange results by session_id and merge with title matches
    for row in exchange_rows:
        sid = row.get("session_id", "")
        user_msg = row.get("user_message") or ""
        ai_resp = row.get("ai_response") or ""
        desc = row.get("description") or ""

        match_field = _determine_match_field(query, user_msg, ai_resp, desc)

        exchange_entry = {
            "exchange_id": row.get("exchange_id", ""),
            "exchange_number": row.get("exchange_number", ""),
            "description": _truncate(desc, 200),
            "user_snippet": _extract_snippet(user_msg, query),
            "ai_snippet": _extract_snippet(ai_resp, query),
            "match_field": match_field,
        }

        if sid in chats_by_sid:
            # Chat already found via title/summary — add exchanges
            chat = chats_by_sid[sid]
            chat["matching_exchanges"].append(exchange_entry)
            # Upgrade match_source if it was title/summary only
            if chat["match_source"] in ("title", "summary"):
                chat["match_source"] = chat["match_source"]  # keep original
        else:
            # Chat found only via exchange match
            chats_by_sid[sid] = {
                "session_id": sid,
                "title": row.get("title") or "Untitled",
                "summary": row.get("summary") or "",
                "module": row.get("module", "chat"),
                "last_accessed": row.get("last_accessed") or "",
                "match_source": "exchange",
                "matching_exchanges": [exchange_entry],
            }

    # Sort by last_accessed descending, limit
    results = sorted(
        chats_by_sid.values(),
        key=lambda c: c.get("last_accessed") or "",
        reverse=True,
    )[:limit]

    return {"chats": results, "count": len(results), "query": query}


async def get_chat(
    graph: BrainService,
    session_id: str,
    exchange_limit: int = 25,
    max_chars: int = 2000,
) -> dict[str, Any]:
    """Get a specific chat with its exchanges (paginated, truncated).

    Returns the most recent `exchange_limit` exchanges in chronological order.
    Messages are truncated to `max_chars`. Includes `has_more` flag when
    there are earlier exchanges not returned.
    """
    session_id = session_id.strip()
    if not session_id:
        return {"error": "session_id is required"}

    exchange_limit = max(1, min(exchange_limit, 200))
    max_chars = max(100, min(max_chars, 50000))

    # Fetch chat node
    chat_rows = await graph.execute_cypher(
        "MATCH (s:Chat {session_id: $session_id}) RETURN s",
        {"session_id": session_id},
    )
    if not chat_rows:
        return {"error": f"Chat not found: {session_id}"}

    chat = chat_rows[0]
    chat_meta = {
        "session_id": chat.get("session_id", ""),
        "title": chat.get("title") or "Untitled",
        "summary": chat.get("summary") or "",
        "module": chat.get("module", "chat"),
        "created_at": chat.get("created_at") or "",
        "last_accessed": chat.get("last_accessed") or "",
        "message_count": chat.get("message_count", 0),
    }

    # Count total exchanges
    count_rows = await graph.execute_cypher(
        "MATCH (s:Chat {session_id: $session_id})-[:HAS_EXCHANGE]->(e:Exchange) "
        "RETURN count(e) AS total",
        {"session_id": session_id},
    )
    total = count_rows[0].get("total", 0) if count_rows else 0

    # Fetch most recent N exchanges (DESC to get most recent, then reverse)
    exchange_rows = await graph.execute_cypher(
        f"MATCH (s:Chat {{session_id: $session_id}})-[:HAS_EXCHANGE]->(e:Exchange) "
        f"RETURN e ORDER BY e.exchange_number DESC LIMIT {exchange_limit}",
        {"session_id": session_id},
    )

    # Reverse to chronological order, truncate messages
    exchanges = []
    for row in reversed(exchange_rows):
        exchanges.append({
            "exchange_id": row.get("exchange_id", ""),
            "exchange_number": row.get("exchange_number", ""),
            "description": row.get("description") or "",
            "user_message": _truncate(row.get("user_message"), max_chars),
            "ai_response": _truncate(row.get("ai_response"), max_chars),
            "tools_used": row.get("tools_used") or "",
            "created_at": row.get("created_at") or "",
        })

    return {
        "chat": chat_meta,
        "exchanges": exchanges,
        "exchange_count": total,
        "has_more": total > exchange_limit,
    }


async def get_exchange(
    graph: BrainService,
    exchange_id: str,
) -> dict[str, Any]:
    """Get a single exchange with full untruncated content.

    Use after search_chats or get_chat identifies a specific exchange
    of interest.
    """
    exchange_id = exchange_id.strip()
    if not exchange_id:
        return {"error": "exchange_id is required"}

    rows = await graph.execute_cypher(
        "MATCH (e:Exchange {exchange_id: $exchange_id}) RETURN e",
        {"exchange_id": exchange_id},
    )
    if not rows:
        return {"error": f"Exchange not found: {exchange_id}"}

    ex = rows[0]
    return {
        "exchange": {
            "exchange_id": ex.get("exchange_id", ""),
            "session_id": ex.get("session_id", ""),
            "exchange_number": ex.get("exchange_number", ""),
            "description": ex.get("description") or "",
            "user_message": ex.get("user_message") or "",
            "ai_response": ex.get("ai_response") or "",
            "context": ex.get("context") or "",
            "tools_used": ex.get("tools_used") or "",
            "created_at": ex.get("created_at") or "",
        },
    }
