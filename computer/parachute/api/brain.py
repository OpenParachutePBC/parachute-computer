"""
Brain query API — read-only access to the shared Kuzu graph.

Endpoints:
  GET  /api/brain/schema            — all tables with column types
  GET  /api/brain/sessions          — conversation sessions (Chat)
  GET  /api/brain/sessions/{id}     — single session by ID
  GET  /api/brain/projects          — named projects
  GET  /api/brain/daily/entries     — Daily journal notes
  GET  /api/brain/memory            — unified memory feed
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


@router.get("/schema")
async def get_schema():
    """Return all node and relationship tables with their column definitions."""
    graph = _get_graph()

    tables = await graph.execute_cypher("CALL show_tables() RETURN *")

    node_tables = []
    rel_tables = []

    for t in tables:
        # KuzuDB returns: name, type, comment
        name = t.get("name", "")
        ttype = str(t.get("type", "NODE")).upper()

        try:
            col_rows = await graph.execute_cypher(f"CALL table_info('{name}') RETURN *")
            columns = []
            for c in col_rows:
                # KuzuDB row: {"property id": N, "name": ..., "type": ..., ...}
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


@router.get("/sessions")
async def list_sessions(
    module: str | None = Query(None, description="Filter by module: chat, daily"),
    limit: int = Query(20, ge=1, le=200),
    archived: bool = Query(False),
    all: bool = Query(False, description="Show all sessions (including agent runs). Default: human-initiated only."),
):
    """List conversation sessions from the graph.

    By default filters to human-initiated sessions (source=parachute, non-bridge agents).
    Pass ?all=true to see all sessions including agent runs and bot sessions.
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
        # Default: human-initiated sessions only
        where_clauses.append(
            "(s.source = 'parachute' AND (s.agent_type IS NULL OR s.agent_type = 'orchestrator'))"
        )

    where = f"WHERE {' AND '.join(where_clauses)}" if where_clauses else ""
    query = (
        f"MATCH (s:Chat) {where} "
        f"RETURN s ORDER BY s.last_accessed DESC LIMIT {limit}"
    )

    rows = await graph.execute_cypher(query, params if params else None)
    return {"sessions": rows, "count": len(rows)}


@router.get("/sessions/{session_id}")
async def get_session(session_id: str):
    """Get a single conversation session by ID."""
    graph = _get_graph()

    rows = await graph.execute_cypher(
        "MATCH (s:Chat {session_id: $session_id}) RETURN s",
        {"session_id": session_id},
    )
    if not rows:
        raise HTTPException(status_code=404, detail=f"Session not found: {session_id}")

    session = rows[0]

    # Fetch exchanges if this session has them
    try:
        exchanges = await graph.execute_cypher(
            "MATCH (s:Chat {session_id: $session_id})-[:HAS_EXCHANGE]->(e:Exchange) "
            "RETURN e ORDER BY e.exchange_number",
            {"session_id": session_id},
        )
    except Exception:
        exchanges = []

    return {"session": session, "exchanges": exchanges}


@router.get("/projects")
async def list_projects(
    limit: int = Query(20, ge=1, le=200),
):
    """List named projects."""
    graph = _get_graph()

    rows = await graph.execute_cypher(
        f"MATCH (p:Project) RETURN p ORDER BY p.created_at DESC LIMIT {limit}"
    )
    return {"projects": rows, "count": len(rows)}


@router.get("/daily/entries")
async def list_daily_entries(
    date_from: str | None = Query(None, description="YYYY-MM-DD"),
    date_to: str | None = Query(None, description="YYYY-MM-DD"),
    limit: int = Query(20, ge=1, le=200),
):
    """List daily journal notes from the graph."""
    graph = _get_graph()

    where_clauses = []
    params = {}

    if date_from:
        where_clauses.append("e.date >= $date_from")
        params["date_from"] = date_from
    if date_to:
        where_clauses.append("e.date <= $date_to")
        params["date_to"] = date_to

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
    search: str | None = Query(None, description="Search query across titles and content"),
    type: Literal["sessions", "notes"] | None = Query(None, description="Filter by type: sessions, notes"),
):
    """Unified memory feed — sessions and notes merged, sorted by time descending.

    Returns a chronological mix of conversation sessions and journal entries,
    giving a single view of everything in the brain. Fetches `limit` records
    from each type, merges, and returns the top `limit` by timestamp.
    """
    brain = _get_graph()
    items: list[dict] = []

    if type != "notes":
        # Fetch sessions
        session_where_clauses = [
            "(s.archived IS NULL OR s.archived = false)",
            "(s.source = 'parachute' AND (s.agent_type IS NULL OR s.agent_type = 'orchestrator'))",
        ]
        session_params: dict = {}
        if search:
            session_where_clauses.append("s.title CONTAINS $search")
            session_params["search"] = search
        s_where = f"WHERE {' AND '.join(session_where_clauses)}"
        session_rows = await brain.execute_cypher(
            f"MATCH (s:Chat) {s_where} RETURN s ORDER BY s.last_accessed DESC LIMIT {limit}",
            session_params or None,
        )
        for s in session_rows:
            items.append({
                "kind": "session",
                "id": s.get("session_id", ""),
                "title": s.get("title") or "Untitled conversation",
                "ts": s.get("last_accessed") or s.get("created_at") or "",
                "module": s.get("module", "chat"),
            })

    if type != "sessions":
        # Fetch notes
        note_where_clauses = []
        note_params: dict = {}
        if search:
            note_where_clauses.append("(e.content CONTAINS $search OR e.title CONTAINS $search)")
            note_params["search"] = search
        n_where = f"WHERE {' AND '.join(note_where_clauses)}" if note_where_clauses else ""
        note_rows = await brain.execute_cypher(
            f"MATCH (e:Note) {n_where} RETURN e ORDER BY e.created_at DESC LIMIT {limit}",
            note_params or None,
        )
        for e in note_rows:
            items.append({
                "kind": "note",
                "id": e.get("id", ""),
                "title": e.get("title") or e.get("snippet") or "Journal entry",
                "ts": e.get("created_at") or "",
                "date": e.get("date") or None,
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

    Intended for agents with vault/direct trust. Write queries are not blocked
    here — trust enforcement is done by the MCP server before calling this endpoint.
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
