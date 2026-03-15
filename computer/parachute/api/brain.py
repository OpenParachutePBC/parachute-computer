"""
Brain query API — read-only access to the shared Kuzu graph.

Endpoints:
  GET  /api/brain/schema            — all tables with column types
  GET  /api/brain/chats             — conversation chats, supports ?search=
  GET  /api/brain/chats/{id}        — single chat + exchanges (brain_get_chat)
  GET  /api/brain/exchanges         — single exchange by ?id= (brain_get_exchange)
  GET  /api/brain/containers         — container environments
  GET  /api/brain/daily/entries     — Daily journal notes (brain_list_notes), supports ?search=
  GET  /api/brain/memory            — unified memory search across chats, notes, and exchanges
  POST /api/brain/query             — read-only Cypher passthrough
  POST /api/brain/execute           — write Cypher passthrough (auth required)
"""

import logging
from typing import Any, Literal

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/brain", tags=["brain"])


def _get_graph():
    from parachute.core.interfaces import get_registry
    graph = get_registry().get("BrainDB")
    if graph is None:
        raise HTTPException(status_code=503, detail="BrainDB not available")
    return graph


def _extract_snippet(content: str, query: str, window: int = 200) -> str:
    """Extract a snippet of up to `window` chars centered around the first match.

    If no match is found, returns the first `window` chars.
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


@router.get("/schema")
async def get_schema():
    """Return all node and relationship tables with their column definitions."""
    graph = _get_graph()

    tables = await graph.execute_cypher("CALL show_tables() RETURN *")

    node_tables = []
    rel_tables = []

    for t in tables:
        name = t.get("name", "")
        ttype = str(t.get("type", "NODE")).upper()

        try:
            col_rows = await graph.execute_cypher(f"CALL table_info('{name}') RETURN *")
            columns = []
            for c in col_rows:
                col_name = c.get("name", "")
                col_type = c.get("type", "")
                is_pk = c.get("is primary key", False)
                columns.append({"name": col_name, "type": col_type, "primary_key": bool(is_pk)})
        except Exception as e:
            logger.warning(f"brain/schema: could not introspect {name}: {e}")
            columns = []

        entry = {"name": name, "columns": columns}
        if "REL" in ttype:
            rel_tables.append(entry)
        else:
            node_tables.append(entry)

    return {
        "node_tables": sorted(node_tables, key=lambda x: x["name"]),
        "rel_tables": sorted(rel_tables, key=lambda x: x["name"]),
    }


@router.get("/chats")
async def list_chats(
    module: str | None = Query(None, description="Filter by module: chat, daily"),
    limit: int = Query(20, ge=1, le=200),
    archived: bool = Query(False),
    all: bool = Query(False, description="Show all chats (including agent runs). Default: human-initiated only."),
    search: str | None = Query(None, description="Search in chat title and summary"),
):
    """List chats from the graph.

    By default filters to human-initiated chats. Pass ?search= to filter by title or summary.
    """
    graph = _get_graph()

    where_clauses = []
    params = {}

    if not archived:
        where_clauses.append("(s.archived IS NULL OR s.archived = false)")
    if module:
        where_clauses.append("s.module = $module")
        params["module"] = module
    if not all:
        where_clauses.append(
            "(s.source = 'parachute' AND (s.agent_type IS NULL OR s.agent_type = 'orchestrator'))"
        )
    if search:
        where_clauses.append(
            "(s.title CONTAINS $search OR (s.summary IS NOT NULL AND s.summary CONTAINS $search))"
        )
        params["search"] = search

    where = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
    query = (
        f"MATCH (s:Chat) {where} "
        f"RETURN s ORDER BY s.last_accessed DESC LIMIT {limit}"
    )

    rows = await graph.execute_cypher(query, params if params else None)
    return {"chats": rows, "count": len(rows)}


@router.get("/chats/{session_id}")
async def get_chat(
    session_id: str,
    exchange_limit: int = Query(25, ge=1, le=200, description="Max exchanges to return (default 25, most recent first)"),
    max_chars: int = Query(2000, ge=100, le=50000, description="Max chars per message field before truncation"),
):
    """Get a single chat by ID with its exchanges.

    Exchanges are returned most-recent-first up to exchange_limit, then reversed to
    chronological order. Long user_message/ai_response fields are truncated at max_chars.
    For full content of a specific exchange, use GET /exchanges?id=...
    """
    graph = _get_graph()

    rows = await graph.execute_cypher(
        "MATCH (s:Chat {session_id: $session_id}) RETURN s",
        {"session_id": session_id},
    )
    if not rows:
        raise HTTPException(status_code=404, detail=f"Chat not found: {session_id}")

    session = rows[0]

    # Fetch most recent N exchanges, then reverse to chronological order
    try:
        exchange_rows = await graph.execute_cypher(
            "MATCH (s:Chat {session_id: $session_id})-[:HAS_EXCHANGE]->(e:Exchange) "
            f"RETURN e ORDER BY e.exchange_number DESC LIMIT {exchange_limit}",
            {"session_id": session_id},
        )
        # Reverse to chronological order
        exchange_rows = list(reversed(exchange_rows))
        # Truncate long message fields
        exchanges = []
        for e in exchange_rows:
            e["user_message"] = _truncate(e.get("user_message"), max_chars)
            e["ai_response"] = _truncate(e.get("ai_response"), max_chars)
            exchanges.append(e)
    except Exception:
        logger.exception("Failed to fetch exchanges for session %s", session_id)
        exchanges = []

    return {"chat": session, "exchanges": exchanges, "exchange_count": len(exchanges)}


@router.get("/exchanges")
async def get_exchange(
    exchange_id: str = Query(..., alias="id", description="Exchange ID (e.g. session_id:ex:N)"),
):
    """Get a single exchange by ID with full message content.

    Use after search_memory or brain_get_chat identifies a specific exchange of interest.
    Returns full user_message and ai_response without truncation.
    """
    graph = _get_graph()

    rows = await graph.execute_cypher(
        "MATCH (e:Exchange {exchange_id: $exchange_id}) RETURN e",
        {"exchange_id": exchange_id},
    )
    if not rows:
        raise HTTPException(status_code=404, detail=f"Exchange not found: {exchange_id}")

    return {"exchange": rows[0]}


@router.get("/containers")
async def list_containers(
    limit: int = Query(20, ge=1, le=200),
):
    """List container environments."""
    graph = _get_graph()

    rows = await graph.execute_cypher(
        f"MATCH (c:Container) RETURN c ORDER BY c.created_at DESC LIMIT {limit}"
    )
    return {"containers": rows, "count": len(rows)}


@router.get("/daily/entries")
async def list_daily_entries(
    date_from: str | None = Query(None, description="YYYY-MM-DD"),
    date_to: str | None = Query(None, description="YYYY-MM-DD"),
    limit: int = Query(20, ge=1, le=200),
    search: str | None = Query(None, description="Search in note content"),
    note_type: str | None = Query(None, description="Filter by note_type (e.g. 'journal')"),
):
    """List notes from the graph (brain_list_notes).

    Pass ?search= to filter by content. Pass ?note_type=journal for Daily journal entries.
    Pass ?date_from and/or ?date_to (YYYY-MM-DD) to scope by date.
    """
    graph = _get_graph()

    where_clauses = []
    params = {}

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
    query = (
        f"MATCH (e:Note) {where} "
        f"RETURN e ORDER BY e.created_at DESC LIMIT {limit}"
    )

    rows = await graph.execute_cypher(query, params if params else None)
    return {"entries": rows, "count": len(rows)}


@router.get("/memory")
async def get_memory(
    limit: int = Query(50, ge=1, le=200),
    search: str | None = Query(None, description="Search query across session summaries, note content, and exchange messages"),
    type: Literal["chats", "notes"] | None = Query(None, description="Filter by type: chats, notes"),
    date_from: str | None = Query(None, description="YYYY-MM-DD — filter notes by date (start)"),
    date_to: str | None = Query(None, description="YYYY-MM-DD — filter notes by date (end)"),
    note_type: str | None = Query(None, description="Filter notes by note_type (e.g. 'journal')"),
):
    """Unified memory search — sessions, notes, and exchanges merged, sorted by time descending.

    When search is provided:
    - Matches Chat.summary + Chat.title for sessions
    - Matches Exchange.user_message + Exchange.ai_response + Exchange.description for exchanges
      (returns parent Chat session with matched exchange description as snippet)
    - Matches Note.content for notes

    Sessions found via exchange match include matched_exchange_id for follow-up with brain_get_exchange.
    Results are deduplicated: a session appears once even if multiple exchanges match.
    """
    brain = _get_graph()
    items: list[dict] = []
    seen_session_ids: set[str] = set()

    if type != "notes":
        # --- Session search (title + summary) ---
        session_where_clauses = [
            "(s.archived IS NULL OR s.archived = false)",
            "(s.source = 'parachute' AND (s.agent_type IS NULL OR s.agent_type = 'orchestrator'))",
        ]
        session_params: dict = {}
        if search:
            session_where_clauses.append(
                "(s.title CONTAINS $search OR (s.summary IS NOT NULL AND s.summary CONTAINS $search))"
            )
            session_params["search"] = search
        s_where = f"WHERE {' AND '.join(session_where_clauses)}"
        session_rows = await brain.execute_cypher(
            f"MATCH (s:Chat) {s_where} RETURN s ORDER BY s.last_accessed DESC LIMIT {limit}",
            session_params or None,
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
                "snippet": _extract_snippet(search_in, search) if search else "",
                "ts": s.get("last_accessed") or s.get("created_at") or "",
                "module": s.get("module", "chat"),
            })

        # --- Exchange search (full content, returns parent session + description as snippet) ---
        if search:
            exchange_where_clauses = [
                "(s.archived IS NULL OR s.archived = false)",
                "(s.source = 'parachute' AND (s.agent_type IS NULL OR s.agent_type = 'orchestrator'))",
                "(e.user_message CONTAINS $search OR e.ai_response CONTAINS $search "
                "OR e.description CONTAINS $search)",
            ]
            ex_rows = await brain.execute_cypher(
                f"MATCH (s:Chat)-[:HAS_EXCHANGE]->(e:Exchange) "
                f"WHERE {' AND '.join(exchange_where_clauses)} "
                f"RETURN s.session_id AS session_id, s.title AS title, s.summary AS summary, "
                f"s.last_accessed AS last_accessed, s.created_at AS created_at, s.module AS module, "
                f"e.description AS matched_description, e.exchange_id AS matched_exchange_id "
                f"ORDER BY s.last_accessed DESC LIMIT {limit}",
                {"search": search},
            )
            for row in ex_rows:
                sid = row.get("session_id", "")
                if sid in seen_session_ids:
                    continue  # already found via session summary search
                seen_session_ids.add(sid)
                items.append({
                    "kind": "session",
                    "id": sid,
                    "title": row.get("title") or "Untitled conversation",
                    "summary": row.get("summary") or "",
                    "snippet": row.get("matched_description") or "",
                    "matched_exchange_id": row.get("matched_exchange_id") or "",
                    "ts": row.get("last_accessed") or row.get("created_at") or "",
                    "module": row.get("module") or "chat",
                })

    if type != "chats":
        # --- Note search ---
        note_where_clauses = []
        note_params: dict = {}
        if search:
            note_where_clauses.append("e.content CONTAINS $search")
            note_params["search"] = search
        if note_type:
            note_where_clauses.append("e.note_type = $note_type")
            note_params["note_type"] = note_type
        if date_from:
            note_where_clauses.append("e.date >= $date_from")
            note_params["date_from"] = date_from
        if date_to:
            note_where_clauses.append("e.date <= $date_to")
            note_params["date_to"] = date_to
        n_where = f"WHERE {' AND '.join(note_where_clauses)}" if note_where_clauses else ""
        note_rows = await brain.execute_cypher(
            f"MATCH (e:Note) {n_where} RETURN e ORDER BY e.created_at DESC LIMIT {limit}",
            note_params or None,
        )
        for e in note_rows:
            content = e.get("content") or ""
            items.append({
                "kind": "note",
                "id": e.get("entry_id", ""),
                "title": e.get("title") or e.get("snippet") or "Journal entry",
                "snippet": _extract_snippet(content, search) if search else "",
                "ts": e.get("created_at") or "",
                "date": e.get("date") or None,
                "note_type": e.get("note_type") or "",
            })

    # Merge and return top `limit` by timestamp descending
    items.sort(key=lambda x: x.get("ts") or "", reverse=True)
    return {"items": items[:limit]}


# ── Cypher passthrough ────────────────────────────────────────────────────────

class CypherRequest(BaseModel):
    query: str
    params: dict[str, Any] | None = None


@router.post("/query")
async def cypher_query(body: CypherRequest):
    """Execute a read-only Cypher query against the brain (MATCH/RETURN).

    Intended for power users and debugging. Prefer search_memory, brain_list_chats,
    brain_list_notes, and brain_get_chat for common use cases.
    """
    brain = _get_graph()
    rows = await brain.execute_cypher(body.query, body.params or None)
    return {"rows": rows, "count": len(rows)}


@router.post("/execute")
async def cypher_execute(body: CypherRequest):
    """Execute a write Cypher mutation against the brain (MERGE/CREATE/SET/DELETE).

    Acquires write_lock to serialize mutations. Trust enforcement is done by
    the MCP server before calling this endpoint.
    """
    brain = _get_graph()
    async with brain.write_lock:
        rows = await brain.execute_cypher(body.query, body.params or None)
    return {"ok": True, "rows": rows, "count": len(rows)}
