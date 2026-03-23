"""
Vault tools — shared MCP tool definitions and handlers.

Provides the unified set of memory/vault tools used by both:
- Direct MCP server (mcp_server.py) — stdio, local trusted sessions
- HTTP MCP bridge (api/mcp_tools.py) — sandbox Docker containers

Tools:
- search_memory: Unified search across chats, messages, and journal notes
- search_chats: Search chat conversations with matched messages inline
- list_chats: List/browse recent conversations
- list_notes: List/browse journal entries and context notes
- get_chat: Get a specific chat with paginated messages
- get_message: Get full untruncated message content
- write_note: Create or update notes (including user context notes)
"""

from __future__ import annotations

import logging
import re
from datetime import datetime, timezone
from typing import Any

from mcp.types import Tool
from parachute.db.brain import BrainService

logger = logging.getLogger(__name__)

# Snippet window: chars before + after the match
_SNIPPET_WINDOW = 300

# Max message matches to fetch per search (prevents runaway queries)
_MAX_MESSAGE_MATCHES = 100

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
    content: str | None,
    description: str | None,
) -> str:
    """Determine which field contains the match (case-insensitive)."""
    q = query.lower()
    if description and q in description.lower():
        return "description"
    if content and q in content.lower():
        return "content"
    return "unknown"


# ── search_memory ─────────────────────────────────────────────────────────────


async def search_memory(
    graph: BrainService,
    query: str,
    source: str | None = None,
    date_from: str | None = None,
    date_to: str | None = None,
    limit: int = 10,
) -> dict[str, Any]:
    """Unified search across chats, messages, and journal notes.

    Searches Chat title/summary, Message content/description, and Note content.
    Results are merged and sorted by timestamp.

    Sessions found via message match include matched_message_id for
    drill-down with get_message.
    """
    query = query.strip()
    if not query:
        return {"error": "Query cannot be empty"}

    limit = max(1, min(limit, 50))
    items: list[dict[str, Any]] = []
    seen_session_ids: set[str] = set()

    if source != "journal":
        # --- Session search (title + summary) ---
        session_params: dict[str, Any] = {"search": query}
        session_rows = await graph.execute_cypher(
            f"MATCH (s:Chat) "
            f"WHERE {_BASE_CHAT_FILTERS} "
            f"AND (s.title CONTAINS $search "
            f"     OR (s.summary IS NOT NULL AND s.summary CONTAINS $search)) "
            f"RETURN s.session_id AS session_id, s.title AS title, "
            f"       s.summary AS summary, s.last_accessed AS last_accessed, "
            f"       s.created_at AS created_at, s.module AS module "
            f"ORDER BY s.last_accessed DESC LIMIT {limit}",
            session_params,
        )
        for s in session_rows:
            sid = s.get("session_id", "")
            seen_session_ids.add(sid)
            summary = s.get("summary") or ""
            title = s.get("title") or "Untitled conversation"
            search_in = summary if summary else title
            items.append({
                "kind": "session",
                "id": sid,
                "title": title,
                "summary": summary,
                "snippet": _extract_snippet(search_in, query),
                "ts": s.get("last_accessed") or s.get("created_at") or "",
                "module": s.get("module", "chat"),
            })

        # --- Message search (content match → parent session) ---
        msg_rows = await graph.execute_cypher(
            f"MATCH (s:Chat)-[:HAS_MESSAGE]->(m:Message) "
            f"WHERE {_BASE_CHAT_FILTERS} "
            f"AND (m.content CONTAINS $search "
            f"     OR (m.description IS NOT NULL AND m.description CONTAINS $search)) "
            f"RETURN s.session_id AS session_id, s.title AS title, "
            f"       s.summary AS summary, s.last_accessed AS last_accessed, "
            f"       s.created_at AS created_at, s.module AS module, "
            f"       m.description AS matched_description, "
            f"       m.message_id AS matched_message_id "
            f"ORDER BY s.last_accessed DESC LIMIT {limit}",
            {"search": query},
        )
        for row in msg_rows:
            sid = row.get("session_id", "")
            if sid in seen_session_ids:
                continue
            seen_session_ids.add(sid)
            items.append({
                "kind": "session",
                "id": sid,
                "title": row.get("title") or "Untitled conversation",
                "summary": row.get("summary") or "",
                "snippet": row.get("matched_description") or "",
                "matched_exchange_id": row.get("matched_message_id") or "",
                "ts": row.get("last_accessed") or row.get("created_at") or "",
                "module": row.get("module") or "chat",
            })

    if source != "chat":
        # --- Note search ---
        note_where: list[str] = []
        note_params: dict[str, Any] = {}

        note_where.append("e.content CONTAINS $search")
        note_params["search"] = query

        if date_from:
            note_where.append("e.date >= $date_from")
            note_params["date_from"] = date_from
        if date_to:
            note_where.append("e.date <= $date_to")
            note_params["date_to"] = date_to

        n_where = f"WHERE {' AND '.join(note_where)}"
        note_rows = await graph.execute_cypher(
            f"MATCH (e:Note) {n_where} "
            f"RETURN e.entry_id AS entry_id, e.title AS title, "
            f"       e.content AS content, e.date AS date, "
            f"       e.note_type AS note_type, e.created_at AS created_at "
            f"ORDER BY e.created_at DESC LIMIT {limit}",
            note_params,
        )
        for e in note_rows:
            content = e.get("content") or ""
            items.append({
                "kind": "note",
                "id": e.get("entry_id", ""),
                "title": e.get("title") or "Journal entry",
                "snippet": _extract_snippet(content, query),
                "ts": e.get("created_at") or "",
                "date": e.get("date") or None,
                "note_type": e.get("note_type") or "",
            })

    items.sort(key=lambda x: x.get("ts") or "", reverse=True)
    return {"items": items[:limit]}


# ── search_chats ──────────────────────────────────────────────────────────────


async def search_chats(
    graph: BrainService,
    query: str,
    limit: int = 10,
    module: str | None = None,
) -> dict[str, Any]:
    """Search across all chats by keyword, returning bundled results.

    Returns chats grouped with their matching messages underneath.
    Each message includes snippets from the matching field so the caller
    can decide whether to drill deeper with get_message.
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
        f"RETURN s.session_id AS session_id, s.title AS title, s.summary AS summary, "
        f"       s.module AS module, s.last_accessed AS last_accessed, s.created_at AS created_at "
        f"ORDER BY s.last_accessed DESC LIMIT {limit}",
        params,
    )

    chats_by_sid: dict[str, dict[str, Any]] = {}
    for row in title_rows:
        sid = row.get("session_id", "")
        title = row.get("title") or "Untitled"
        summary = row.get("summary") or ""

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

    # --- 2. Message content search ---
    message_rows = await graph.execute_cypher(
        f"MATCH (s:Chat)-[:HAS_MESSAGE]->(m:Message) "
        f"WHERE {_BASE_CHAT_FILTERS}{module_filter} "
        f"AND (m.content CONTAINS $query "
        f"     OR (m.description IS NOT NULL AND m.description CONTAINS $query)) "
        f"RETURN s.session_id AS session_id, s.title AS title, "
        f"       s.summary AS summary, s.last_accessed AS last_accessed, "
        f"       s.module AS module, "
        f"       m.message_id AS message_id, "
        f"       m.sequence AS sequence, "
        f"       m.role AS role, "
        f"       m.description AS description, "
        f"       m.content AS content "
        f"ORDER BY s.last_accessed DESC, m.sequence ASC "
        f"LIMIT {_MAX_MESSAGE_MATCHES}",
        params,
    )

    for row in message_rows:
        sid = row.get("session_id", "")
        content = row.get("content") or ""
        desc = row.get("description") or ""

        match_field = _determine_match_field(query, content, desc)

        exchange_entry = {
            "exchange_id": row.get("message_id", ""),
            "exchange_number": str(row.get("sequence", "")),
            "description": _truncate(desc, 200),
            "user_snippet": _extract_snippet(content, query) if row.get("role") == "human" else "",
            "ai_snippet": _extract_snippet(content, query) if row.get("role") == "machine" else "",
            "match_field": match_field,
        }

        if sid in chats_by_sid:
            chats_by_sid[sid]["matching_exchanges"].append(exchange_entry)
        else:
            chats_by_sid[sid] = {
                "session_id": sid,
                "title": row.get("title") or "Untitled",
                "summary": row.get("summary") or "",
                "module": row.get("module", "chat"),
                "last_accessed": row.get("last_accessed") or "",
                "match_source": "message",
                "matching_exchanges": [exchange_entry],
            }

    results = sorted(
        chats_by_sid.values(),
        key=lambda c: c.get("last_accessed") or "",
        reverse=True,
    )[:limit]

    return {"chats": results, "count": len(results), "query": query}


# ── list_chats ────────────────────────────────────────────────────────────────


async def list_chats(
    graph: BrainService,
    module: str | None = None,
    limit: int = 20,
    archived: bool = False,
    search: str | None = None,
) -> dict[str, Any]:
    """List recent chat conversations.

    Filters to human-initiated, non-archived chats by default.
    Supports filtering by module and keyword search in title/summary.
    """
    limit = max(1, min(limit, 200))

    where_clauses = []
    params: dict[str, Any] = {}

    if not archived:
        where_clauses.append("(s.archived IS NULL OR s.archived = false)")

    where_clauses.append(
        "(s.source = 'parachute' AND (s.agent_type IS NULL OR s.agent_type = 'orchestrator'))"
    )

    if module:
        where_clauses.append("s.module = $module")
        params["module"] = module

    if search:
        where_clauses.append(
            "(s.title CONTAINS $search OR (s.summary IS NOT NULL AND s.summary CONTAINS $search))"
        )
        params["search"] = search

    where = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
    rows = await graph.execute_cypher(
        f"MATCH (s:Chat) {where} "
        f"RETURN s.session_id AS session_id, s.title AS title, "
        f"       s.summary AS summary, s.module AS module, "
        f"       s.created_at AS created_at, s.last_accessed AS last_accessed, "
        f"       s.message_count AS message_count "
        f"ORDER BY s.last_accessed DESC LIMIT {limit}",
        params or None,
    )

    chats = []
    for row in rows:
        chats.append({
            "session_id": row.get("session_id", ""),
            "title": row.get("title") or "Untitled",
            "summary": row.get("summary") or "",
            "module": row.get("module", "chat"),
            "created_at": row.get("created_at") or "",
            "last_accessed": row.get("last_accessed") or "",
            "message_count": row.get("message_count", 0),
        })

    return {"chats": chats, "count": len(chats)}


# ── list_notes ────────────────────────────────────────────────────────────────


async def list_notes(
    graph: BrainService,
    date_from: str | None = None,
    date_to: str | None = None,
    limit: int = 20,
    note_type: str | None = None,
    search: str | None = None,
) -> dict[str, Any]:
    """List journal entries and notes.

    Supports filtering by date range, note type, and keyword search.
    """
    limit = max(1, min(limit, 200))

    where_clauses: list[str] = []
    params: dict[str, Any] = {}

    if date_from:
        where_clauses.append("e.date >= $date_from")
        params["date_from"] = date_from
    if date_to:
        where_clauses.append("e.date <= $date_to")
        params["date_to"] = date_to
    if search:
        where_clauses.append("e.content CONTAINS $search")
        params["search"] = search
    if note_type:
        where_clauses.append("e.note_type = $note_type")
        params["note_type"] = note_type

    where = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
    rows = await graph.execute_cypher(
        f"MATCH (e:Note) {where} "
        f"RETURN e.entry_id AS entry_id, e.title AS title, "
        f"       e.content AS content, e.date AS date, "
        f"       e.note_type AS note_type, e.created_at AS created_at "
        f"ORDER BY e.created_at DESC LIMIT {limit}",
        params or None,
    )

    entries = []
    for row in rows:
        entries.append({
            "entry_id": row.get("entry_id", ""),
            "date": row.get("date", ""),
            "content": row.get("content", ""),
            "title": row.get("title", ""),
            "note_type": row.get("note_type", ""),
            "created_at": row.get("created_at", ""),
        })

    return {"entries": entries, "count": len(entries)}


# ── get_chat ──────────────────────────────────────────────────────────────────


async def get_chat(
    graph: BrainService,
    session_id: str,
    exchange_limit: int = 25,
    max_chars: int = 2000,
) -> dict[str, Any]:
    """Get a specific chat with its messages (paginated, truncated).

    Returns the most recent messages in chronological order.
    Content is truncated to `max_chars`. Includes `has_more` flag when
    there are earlier messages not returned.

    Returns data in exchange-compatible shape for backward compat:
    pairs of consecutive human+machine messages are grouped as exchanges.
    """
    session_id = session_id.strip()
    if not session_id:
        return {"error": "session_id is required"}

    # exchange_limit refers to exchanges (pairs), so fetch 2x messages
    msg_limit = max(1, min(exchange_limit, 200)) * 2
    max_chars = max(100, min(max_chars, 50000))

    chat_rows = await graph.execute_cypher(
        "MATCH (s:Chat {session_id: $session_id}) "
        "RETURN s.session_id AS session_id, s.title AS title, s.summary AS summary, "
        "       s.module AS module, s.created_at AS created_at, "
        "       s.last_accessed AS last_accessed, s.message_count AS message_count",
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

    count_rows = await graph.execute_cypher(
        "MATCH (s:Chat {session_id: $session_id})-[:HAS_MESSAGE]->(m:Message) "
        "RETURN count(m) AS total",
        {"session_id": session_id},
    )
    total_messages = count_rows[0].get("total", 0) if count_rows else 0

    message_rows = await graph.execute_cypher(
        f"MATCH (s:Chat {{session_id: $session_id}})-[:HAS_MESSAGE]->(m:Message) "
        f"RETURN m.message_id AS message_id, m.sequence AS sequence, "
        f"       m.role AS role, m.content AS content, "
        f"       m.description AS description, m.tools_used AS tools_used, "
        f"       m.status AS status, m.created_at AS created_at "
        f"ORDER BY m.sequence DESC LIMIT {msg_limit}",
        {"session_id": session_id},
    )

    # Build exchange-compatible pairs from messages (for backward compat)
    messages_chrono = list(reversed(message_rows))
    exchanges = []
    i = 0
    while i < len(messages_chrono):
        msg = messages_chrono[i]
        if msg.get("role") == "human":
            user_msg = _truncate(msg.get("content"), max_chars)
            ai_resp = ""
            tools = ""
            desc = msg.get("description") or ""
            exchange_id = msg.get("message_id", "")
            created = msg.get("created_at") or ""
            # Look for paired machine message
            if i + 1 < len(messages_chrono) and messages_chrono[i + 1].get("role") == "machine":
                machine = messages_chrono[i + 1]
                ai_resp = _truncate(machine.get("content"), max_chars)
                tools = machine.get("tools_used") or ""
                desc = desc or machine.get("description") or ""
                i += 2
            else:
                i += 1
            exchanges.append({
                "exchange_id": exchange_id,
                "exchange_number": str(msg.get("sequence", "")),
                "description": desc,
                "user_message": user_msg,
                "ai_response": ai_resp,
                "tools_used": tools,
                "created_at": created,
            })
        else:
            # Standalone machine message (no preceding human)
            exchanges.append({
                "exchange_id": msg.get("message_id", ""),
                "exchange_number": str(msg.get("sequence", "")),
                "description": msg.get("description") or "",
                "user_message": "",
                "ai_response": _truncate(msg.get("content"), max_chars),
                "tools_used": msg.get("tools_used") or "",
                "created_at": msg.get("created_at") or "",
            })
            i += 1

    exchange_count = total_messages // 2  # approximate

    return {
        "chat": chat_meta,
        "exchanges": exchanges,
        "exchange_count": exchange_count,
        "has_more": total_messages > msg_limit,
    }


# ── get_exchange / get_message ────────────────────────────────────────────────


async def get_exchange(
    graph: BrainService,
    exchange_id: str,
) -> dict[str, Any]:
    """Get a single message with full untruncated content.

    Accepts either a Message ID (new) or legacy Exchange ID.
    Returns exchange-compatible shape for backward compat.
    """
    return await get_message(graph, exchange_id)


async def get_message(
    graph: BrainService,
    message_id: str,
) -> dict[str, Any]:
    """Get a single message with full untruncated content."""
    message_id = message_id.strip()
    if not message_id:
        return {"error": "message_id is required"}

    rows = await graph.execute_cypher(
        "MATCH (m:Message {message_id: $message_id}) "
        "RETURN m.message_id AS message_id, m.session_id AS session_id, "
        "       m.sequence AS sequence, m.role AS role, "
        "       m.content AS content, m.description AS description, "
        "       m.context AS context, m.tools_used AS tools_used, "
        "       m.thinking AS thinking, m.status AS status, "
        "       m.created_at AS created_at",
        {"message_id": message_id},
    )
    if not rows:
        return {"error": f"Message not found: {message_id}"}

    m = rows[0]
    # Return exchange-compatible shape for backward compat
    return {
        "exchange": {
            "exchange_id": m.get("message_id", ""),
            "session_id": m.get("session_id", ""),
            "exchange_number": str(m.get("sequence", "")),
            "description": m.get("description") or "",
            "user_message": m.get("content") or "" if m.get("role") == "human" else "",
            "ai_response": m.get("content") or "" if m.get("role") == "machine" else "",
            "context": m.get("context") or "",
            "tools_used": m.get("tools_used") or "",
            "created_at": m.get("created_at") or "",
        },
    }


# ── write_note ────────────────────────────────────────────────────────────────

# Max content size for notes
_MAX_NOTE_CONTENT = 10_000


async def write_note(
    graph: BrainService,
    note_type: str,
    title: str,
    content: str,
    date: str | None = None,
) -> dict[str, Any]:
    """Create or update a note.

    For context notes (note_type='context'), merges on note_type + title
    so there is always exactly one note per context title (e.g., "Profile",
    "Now", "Preferences"). For other note types, creates a new note with
    a generated entry_id.

    Args:
        graph: BrainService instance
        note_type: Type of note ("context", "journal", "reference", etc.)
        title: Note title (required)
        content: Markdown content
        date: Optional date in YYYY-MM-DD format (required for journals)
    """
    note_type = note_type.strip().lower()
    title = title.strip()
    content = content.strip()

    if not note_type:
        return {"error": "note_type is required"}
    if not title:
        return {"error": "title is required"}
    if not content:
        return {"error": "content is required"}
    if len(content) > _MAX_NOTE_CONTENT:
        return {"error": f"Content too large ({len(content)} chars, max {_MAX_NOTE_CONTENT})"}

    if date and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        return {"error": "Invalid date format. Use YYYY-MM-DD"}

    now = datetime.now(timezone.utc).isoformat()

    if note_type == "context":
        # Context notes: MERGE on note_type + title (one per title)
        # Use a deterministic entry_id so MERGE is idempotent
        entry_id = f"context:{title.lower().replace(' ', '-')}"
        # Upsert content fields + updated_at
        await graph.execute_cypher(
            "MERGE (n:Note {entry_id: $entry_id}) "
            "SET n.note_type = $note_type, "
            "    n.title = $title, "
            "    n.content = $content, "
            "    n.snippet = $snippet, "
            "    n.status = 'active', "
            "    n.updated_at = $now",
            {
                "entry_id": entry_id,
                "note_type": note_type,
                "title": title,
                "content": content,
                "snippet": content[:200],
                "now": now,
            },
        )
        # Set created_at/created_by only if not already set (new node).
        # Separate query due to Kuzu limitation: COALESCE + other SET
        # fields in the same statement fails on existing nodes (#311).
        await graph.execute_cypher(
            "MATCH (n:Note {entry_id: $entry_id}) "
            "WHERE n.created_at = '' OR n.created_at IS NULL "
            "SET n.created_at = $now, n.created_by = 'agent'",
            {"entry_id": entry_id, "now": now},
        )
        return {
            "entry_id": entry_id,
            "note_type": note_type,
            "title": title,
            "status": "updated",
        }
    else:
        # Other notes: CREATE with generated entry_id
        ts = datetime.now(timezone.utc)
        entry_id = ts.strftime("%Y-%m-%d-%H-%M-%S-%f")
        effective_date = date or ts.strftime("%Y-%m-%d")

        await graph.execute_cypher(
            "MERGE (n:Note {entry_id: $entry_id}) "
            "SET n.note_type = $note_type, "
            "    n.title = $title, "
            "    n.content = $content, "
            "    n.snippet = $snippet, "
            "    n.date = $date, "
            "    n.status = 'active', "
            "    n.created_by = 'agent', "
            "    n.created_at = $now, "
            "    n.updated_at = $now, "
            "    n.entry_type = 'text'",
            {
                "entry_id": entry_id,
                "note_type": note_type,
                "title": title,
                "content": content,
                "snippet": content[:200],
                "date": effective_date,
                "now": now,
            },
        )
        return {
            "entry_id": entry_id,
            "note_type": note_type,
            "title": title,
            "date": effective_date,
            "status": "created",
        }


# ── Tool Definitions ─────────────────────────────────────────────────────────
# Registered in both the direct MCP server (mcp_server.py)
# and the sandbox HTTP bridge (mcp_tools.py).

VAULT_TOOLS = [
    Tool(
        name="search_memory",
        description=(
            "Search all memory — chat sessions, conversation messages, and journal entries — by keyword. "
            "Returns ranked results with summaries and matched snippets. "
            "Sessions matched via message content include matched_exchange_id for follow-up with get_exchange. "
            "By default searches everything; use 'source' to narrow to 'journal' or 'chat'. "
            "Use date_from/date_to (YYYY-MM-DD) to scope journal results by date."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Keyword or phrase to search across all memory",
                },
                "source": {
                    "type": "string",
                    "description": "Optional: 'journal' to search only journal entries, 'chat' for sessions only",
                },
                "date_from": {
                    "type": "string",
                    "description": "Optional: YYYY-MM-DD — scope journal results from this date",
                },
                "date_to": {
                    "type": "string",
                    "description": "Optional: YYYY-MM-DD — scope journal results to this date",
                },
                "limit": {
                    "type": "number",
                    "description": "Maximum number of results (default: 10)",
                    "default": 10,
                },
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="search_chats",
        description=(
            "Search across all past chat conversations by keyword. "
            "Returns chats with matching messages bundled underneath — "
            "shows what was actually said, not just chat-level pointers. "
            "Each matching message includes user/AI snippets for quick review. "
            "Use get_exchange to drill into full content of a specific message."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Keyword or phrase to search for",
                },
                "limit": {
                    "type": "integer",
                    "description": "Max chats to return (default: 10)",
                    "default": 10,
                },
                "module": {
                    "type": "string",
                    "description": "Optional: filter by module (e.g. 'chat', 'daily')",
                },
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="list_chats",
        description=(
            "List recent chat conversations. Use when browsing recent activity "
            "rather than searching for something specific. "
            "Filter by module (chat, daily) or search by title/summary keyword."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "module": {
                    "type": "string",
                    "description": "Filter by module: chat, daily",
                },
                "limit": {
                    "type": "integer",
                    "description": "Max results (default 20)",
                    "default": 20,
                },
                "archived": {
                    "type": "boolean",
                    "description": "Include archived (default false)",
                    "default": False,
                },
                "search": {
                    "type": "string",
                    "description": "Optional: filter by title or summary keyword",
                },
            },
        },
    ),
    Tool(
        name="list_notes",
        description=(
            "List journal entries and notes. Use date_from/date_to to scope by date. "
            "Use note_type='journal' for Daily journal entries."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "date_from": {
                    "type": "string",
                    "description": "YYYY-MM-DD",
                },
                "date_to": {
                    "type": "string",
                    "description": "YYYY-MM-DD",
                },
                "limit": {
                    "type": "integer",
                    "description": "Max results (default 20)",
                    "default": 20,
                },
                "note_type": {
                    "type": "string",
                    "description": "Filter by note_type (e.g. 'journal')",
                },
                "search": {
                    "type": "string",
                    "description": "Optional: filter by content keyword",
                },
            },
        },
    ),
    Tool(
        name="get_chat",
        description=(
            "Browse a specific chat conversation. Returns chat metadata "
            "plus its messages (most recent N, truncated). Use get_exchange "
            "to see full untruncated content of any specific message."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "session_id": {
                    "type": "string",
                    "description": "The chat's session_id",
                },
                "exchange_limit": {
                    "type": "integer",
                    "description": "Max exchanges to return (default: 25, most recent)",
                    "default": 25,
                },
                "max_chars": {
                    "type": "integer",
                    "description": "Max chars per message before truncation (default: 2000)",
                    "default": 2000,
                },
            },
            "required": ["session_id"],
        },
    ),
    Tool(
        name="get_exchange",
        description=(
            "Get a single message with full untruncated content. "
            "Use after search_chats or get_chat identifies a specific message "
            "of interest."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "exchange_id": {
                    "type": "string",
                    "description": "The exchange's exchange_id",
                },
            },
            "required": ["exchange_id"],
        },
    ),
    Tool(
        name="write_note",
        description=(
            "Create or update a note. For context notes (note_type='context'), "
            "merges on title so there is exactly one per title — use to save "
            "user profile, preferences, current focus, orientation, etc. "
            "Context notes are automatically loaded into every session. "
            "For other note types, creates a new note."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "note_type": {
                    "type": "string",
                    "description": (
                        "Type of note: 'context' for persistent user context, "
                        "'journal' for daily entries, 'reference' for reference material"
                    ),
                },
                "title": {
                    "type": "string",
                    "description": "Note title (e.g. 'Profile', 'Now', 'Preferences')",
                },
                "content": {
                    "type": "string",
                    "description": "Markdown content of the note",
                },
                "date": {
                    "type": "string",
                    "description": "Optional date in YYYY-MM-DD format",
                },
            },
            "required": ["note_type", "title", "content"],
        },
    ),
]
