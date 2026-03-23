"""
Brain query API — access to the shared Kuzu graph.

Endpoints:
  GET  /api/brain/schema            — all tables with column types
  GET  /api/brain/chats             — conversation chats, supports ?search=
  GET  /api/brain/chats/{id}        — single chat + messages
  GET  /api/brain/chats/search      — search chats with matched messages inline
  GET  /api/brain/messages          — single message by ?id=
  GET  /api/brain/exchanges         — (compat) alias for /messages
  GET  /api/brain/containers        — container environments
  GET  /api/brain/daily/entries     — notes and journal entries, supports ?search=
  GET  /api/brain/memory            — unified memory search across chats, notes, and messages
  POST /api/brain/notes             — create or update a note
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


@router.get("/chats/search")
async def search_chats(
    query: str = Query(..., description="Keyword or phrase to search for"),
    limit: int = Query(10, ge=1, le=50),
    module: str | None = Query(None, description="Filter by module: chat, daily"),
):
    """Search chats by keyword with matched messages bundled inline.

    Returns chats grouped with their matching messages underneath.
    Each message includes snippets from the matching field.
    """
    from parachute.core.vault_tools import search_chats as _search_chats

    graph = _get_graph()
    result = await _search_chats(graph, query=query, limit=limit, module=module)
    return result


@router.get("/chats/{session_id}")
async def get_chat(
    session_id: str,
    exchange_limit: int = Query(25, ge=1, le=200, description="Max messages to return (default 25, most recent first)"),
    max_chars: int = Query(2000, ge=100, le=50000, description="Max chars per message field before truncation"),
):
    """Get a single chat by ID with its messages.

    Messages are returned in chronological order up to exchange_limit pairs.
    Long content fields are truncated at max_chars.
    For full content of a specific message, use GET /messages?id=...
    """
    from parachute.core.vault_tools import get_chat as _get_chat

    graph = _get_graph()
    result = await _get_chat(graph, session_id=session_id, exchange_limit=exchange_limit, max_chars=max_chars)
    if "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])
    return result


@router.get("/messages")
async def get_message(
    id: str = Query(..., description="Message ID (e.g. session_id:msg:N)"),
):
    """Get a single message by ID with full content.

    Use after search_memory or brain_get_chat identifies a specific message of interest.
    Returns full content without truncation.
    """
    from parachute.core.vault_tools import get_message as _get_message

    graph = _get_graph()
    result = await _get_message(graph, message_id=id)
    if "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])
    return result


@router.get("/exchanges")
async def get_exchange_compat(
    exchange_id: str = Query(..., alias="id", description="Message/Exchange ID"),
):
    """Backward-compatible alias for /messages."""
    from parachute.core.vault_tools import get_message as _get_message

    graph = _get_graph()
    result = await _get_message(graph, message_id=exchange_id)
    if "error" in result:
        raise HTTPException(status_code=404, detail=result["error"])
    return result


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
    search: str | None = Query(None, description="Search query across session summaries, note content, and messages"),
    type: Literal["chats", "notes"] | None = Query(None, description="Filter by type: chats, notes"),
    date_from: str | None = Query(None, description="YYYY-MM-DD — filter notes by date (start)"),
    date_to: str | None = Query(None, description="YYYY-MM-DD — filter notes by date (end)"),
    note_type: str | None = Query(None, description="Filter notes by note_type (e.g. 'journal')"),
):
    """Unified memory search — sessions, notes, and messages merged, sorted by time descending.

    When search is provided:
    - Matches Chat.summary + Chat.title for sessions
    - Matches Message.content + Message.description for messages
      (returns parent Chat session with matched message description as snippet)
    - Matches Note.content for notes

    Sessions found via message match include matched_exchange_id for follow-up with get_message.
    Results are deduplicated: a session appears once even if multiple messages match.
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

        # --- Message search (content match → parent session) ---
        if search:
            msg_where_clauses = [
                "(s.archived IS NULL OR s.archived = false)",
                "(s.source = 'parachute' AND (s.agent_type IS NULL OR s.agent_type = 'orchestrator'))",
                "(m.content CONTAINS $search "
                "OR (m.description IS NOT NULL AND m.description CONTAINS $search))",
            ]
            msg_rows = await brain.execute_cypher(
                f"MATCH (s:Chat)-[:HAS_MESSAGE]->(m:Message) "
                f"WHERE {' AND '.join(msg_where_clauses)} "
                f"RETURN s.session_id AS session_id, s.title AS title, s.summary AS summary, "
                f"s.last_accessed AS last_accessed, s.created_at AS created_at, s.module AS module, "
                f"m.description AS matched_description, m.message_id AS matched_message_id "
                f"ORDER BY s.last_accessed DESC LIMIT {limit}",
                {"search": search},
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


# ── Notes ─────────────────────────────────────────────────────────────────────


class WriteNoteRequest(BaseModel):
    note_type: str
    title: str
    content: str
    date: str | None = None


@router.post("/notes")
async def write_note(body: WriteNoteRequest):
    """Create or update a note.

    For context notes (note_type='context'), merges on title so there is
    exactly one note per title. For other note types, creates a new note.
    """
    from parachute.core.vault_tools import write_note as _write_note

    graph = _get_graph()
    async with graph.write_lock:
        result = await _write_note(
            graph,
            note_type=body.note_type,
            title=body.title,
            content=body.content,
            date=body.date,
        )
    if "error" in result:
        raise HTTPException(status_code=400, detail=result["error"])
    return result


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
