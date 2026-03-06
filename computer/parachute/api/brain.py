"""
Brain query API — read-only access to the shared Kuzu graph.

Endpoints:
  GET /api/brain/schema            — all tables with column types
  GET /api/brain/sessions          — conversation sessions (Chat)
  GET /api/brain/sessions/{id}     — single session by ID
  GET /api/brain/projects          — named projects
  GET /api/brain/daily/entries     — Daily journal notes
"""

import logging

from fastapi import APIRouter, HTTPException, Query

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/brain")


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
