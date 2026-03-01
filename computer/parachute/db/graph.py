"""
GraphService — Core graph database infrastructure.

Shared Kuzu/LadybugDB connection for all modules. Each module registers its
own schema segment via ensure_node_table() / ensure_rel_table() on load.

This is infrastructure, not a Brain feature. The Brain module wraps this with
brain-specific logic (BrainService). Other modules (Chat, Daily) will use
this directly to register and query their own node types.

LadybugDB quirks:
  - Parameters are positional: conn.execute(query, params_dict)
  - $param works in MATCH/MERGE node patterns and most SET clauses
  - 'desc' is a reserved keyword — use 'description'
  - DETACH DELETE works for nodes with relationships
  - RETURN e (node) returns dict with _ID, _LABEL + all columns
"""

import asyncio
import logging
from pathlib import Path
from typing import Any

import real_ladybug as lb

logger = logging.getLogger(__name__)

# Internal LadybugDB fields stripped from all API responses
_INTERNAL_FIELDS = {"_ID", "_LABEL", "_SRC", "_DST"}


def _clean_node(node: dict) -> dict:
    """Strip LadybugDB internal fields from a node dict."""
    return {k: v for k, v in node.items() if k not in _INTERNAL_FIELDS}


class GraphService:
    """
    Core graph database service. Shared infrastructure for all modules.

    Holds the single Kuzu connection (embedded database — one writer).
    Modules call ensure_node_table() / ensure_rel_table() during their init
    to register their schema segment. All modules share this connection.
    """

    def __init__(self, db_path: Path):
        self.db_path = db_path
        self._db: lb.Database | None = None
        self._conn: lb.AsyncConnection | None = None
        self._write_lock = asyncio.Lock()
        self._connected = False

    @property
    def write_lock(self) -> asyncio.Lock:
        """Serialized write access. Use: async with graph.write_lock: ..."""
        return self._write_lock

    @property
    def is_connected(self) -> bool:
        """True if the database connection is open."""
        return self._connected

    def _ensure_connected(self) -> None:
        if not self._connected or self._conn is None:
            raise RuntimeError("GraphService not connected. Call connect() first.")

    async def connect(self) -> None:
        """Open the database. Idempotent."""
        if self._connected:
            return
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._db = lb.Database(str(self.db_path))
        self._conn = lb.AsyncConnection(self._db)
        self._connected = True
        logger.info(f"GraphService connected: {self.db_path}")

    async def close(self) -> None:
        """Close the database connection."""
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception as e:
                logger.warning(f"GraphService: error closing connection: {e}")
        self._connected = False
        self._conn = None
        self._db = None

    # ── Schema registration ───────────────────────────────────────────────────

    async def ensure_node_table(
        self,
        name: str,
        columns: dict[str, str],
        primary_key: str = "name",
    ) -> None:
        """
        Create a node table if it doesn't exist. Idempotent.

        columns: {column_name: kuzu_type} e.g. {"title": "STRING", "count": "INT64"}
        The primary_key column must be included in columns.

        Example:
            await graph.ensure_node_table("Chat_Session", {
                "name": "STRING",
                "title": "STRING",
                "created_at": "STRING",
            }, primary_key="name")
        """
        self._ensure_connected()
        col_defs = ", ".join(f"{col} {typ}" for col, typ in columns.items())
        ddl = (
            f"CREATE NODE TABLE IF NOT EXISTS {name} "
            f"({col_defs}, PRIMARY KEY({primary_key}))"
        )
        async with self._write_lock:
            await self._conn.execute(ddl)
        logger.debug(f"GraphService: ensured node table {name!r}")

    async def ensure_rel_table(
        self,
        name: str,
        from_table: str,
        to_table: str,
        columns: dict[str, str] | None = None,
    ) -> None:
        """
        Create a relationship table if it doesn't exist. Idempotent.

        Example:
            await graph.ensure_rel_table(
                "HAS_EXCHANGE", "Chat_Session", "Chat_Exchange",
                {"created_at": "STRING"}
            )
        """
        self._ensure_connected()
        col_part = ""
        if columns:
            col_part = ", " + ", ".join(f"{col} {typ}" for col, typ in columns.items())
        ddl = (
            f"CREATE REL TABLE IF NOT EXISTS {name}"
            f"(FROM {from_table} TO {to_table}{col_part})"
        )
        async with self._write_lock:
            await self._conn.execute(ddl)
        logger.debug(f"GraphService: ensured rel table {name!r}")

    async def get_table_columns(self, table_name: str) -> set[str]:
        """Return existing column names for a table via CALL table_info()."""
        self._ensure_connected()
        try:
            result = await self._conn.execute(
                f"CALL table_info('{table_name}') RETURN *"
            )
            cols: set[str] = set()
            while result.has_next():
                row = result.get_next()
                # row format: [col_id, col_name, type, default, is_primary]
                if len(row) >= 2:
                    cols.add(row[1])
            return cols
        except Exception as e:
            logger.warning(f"GraphService: could not get columns for {table_name}: {e}")
            return set()

    # ── Query execution ───────────────────────────────────────────────────────

    async def _execute(
        self,
        query: str,
        params: dict[str, Any] | None = None,
    ) -> Any:
        """
        Execute a Cypher query and return the raw QueryResult for iteration.
        Internal use only — prefer execute_cypher() in module code.
        """
        self._ensure_connected()
        return await self._conn.execute(query, params or None)

    async def execute_cypher(
        self,
        query: str,
        params: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        """
        Execute a Cypher query and return results as a list of dicts.
        Single-column node returns are cleaned of internal fields.
        """
        self._ensure_connected()
        result = await self._conn.execute(query, params or None)
        col_names = result.get_column_names()
        rows: list[dict[str, Any]] = []
        while result.has_next():
            row = result.get_next()
            if len(col_names) == 1 and isinstance(row[0], dict):
                rows.append(_clean_node(row[0]))
            else:
                rows.append(dict(zip(col_names, row)))
        return rows
