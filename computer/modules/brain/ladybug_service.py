"""
LadybugDB Knowledge Graph Service

Thin async wrapper around real_ladybug (LadybugDB) for Brain v3.
No LLM extraction pipeline — agents write structured data directly via MCP tools.

Schema:
  Brain_Entity (name STRING PRIMARY KEY, entity_type STRING,
                description STRING,          -- always present, unstructured notes
                created_at STRING, updated_at STRING,
                [field columns from entity_types.yaml, added via ALTER TABLE...])
  Brain_Relationship (FROM Brain_Entity TO Brain_Entity,
                      label STRING, description STRING, created_at STRING)

The ontology is open-ended. Agents write any entity_type string they want.
Structured field columns are added lazily when types crystallize in entity_types.yaml.

LadybugDB quirks discovered during development:
  - Parameters are positional: conn.execute(query, params_dict) not parameters=...
  - $param works in MATCH/MERGE node patterns and most SET clauses
  - Multi-param SET on relationship queries can fail; use f-strings with sanitized values
  - 'desc' is a reserved keyword (use 'description')
  - DETACH DELETE works for nodes with relationships
  - RETURN e (node) returns dict with _ID, _LABEL + all columns
"""

import asyncio
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import real_ladybug as lb

from .schema import all_field_names, load_entity_types, to_api_schema

logger = logging.getLogger(__name__)

# Base columns always present on Brain_Entity (never schema-managed).
# Note: 'description' is intentionally NOT here — it's a base column but we want
# it searchable and writable as a regular attribute, not excluded from those paths.
_BASE_COLUMNS = {"name", "entity_type", "created_at", "updated_at"}

# Internal LadybugDB fields to strip from API responses
_INTERNAL_FIELDS = {"_ID", "_LABEL", "_SRC", "_DST"}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _clean_node(node: dict) -> dict:
    """Strip LadybugDB internal fields from a node dict."""
    return {k: v for k, v in node.items() if k not in _INTERNAL_FIELDS}


def _esc(value: str) -> str:
    """Escape a string value for safe inline use in Cypher (single-quote escape)."""
    return str(value).replace("'", "\\'")


class LadybugService:
    """Async LadybugDB wrapper for Brain v3."""

    def __init__(self, db_path: Path, vault_path: Path):
        self.db_path = db_path
        self.vault_path = vault_path
        self._db: lb.Database | None = None
        self._conn: lb.AsyncConnection | None = None
        self._write_lock = asyncio.Lock()
        self._connected = False

    def _ensure_connected(self) -> None:
        if not self._connected or self._conn is None:
            raise RuntimeError("LadybugService not connected. Call connect() first.")

    async def connect(self) -> None:
        """Open database, initialize schema, sync columns from entity_types.yaml."""
        if self._connected:
            return
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._db = lb.Database(str(self.db_path))
        self._conn = lb.AsyncConnection(self._db)

        # Initialize base tables
        await self._conn.execute(
            "CREATE NODE TABLE IF NOT EXISTS Brain_Entity("
            "name STRING, entity_type STRING, description STRING, "
            "created_at STRING, updated_at STRING, "
            "PRIMARY KEY(name))"
        )
        await self._conn.execute(
            "CREATE REL TABLE IF NOT EXISTS Brain_Relationship("
            "FROM Brain_Entity TO Brain_Entity, "
            "label STRING, description STRING, created_at STRING)"
        )

        self._connected = True
        logger.info(f"LadybugService connected: {self.db_path}")

        # Ensure 'description' column exists on databases created before this field was added
        existing = await self._get_table_columns("Brain_Entity")
        if "description" not in existing:
            await self._conn.execute(
                "ALTER TABLE Brain_Entity ADD description STRING DEFAULT NULL"
            )
            logger.info("Brain schema: migrated — added 'description' column to Brain_Entity")

        # Sync schema columns from entity_types.yaml
        await self.sync_schema()

    async def close(self) -> None:
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception as e:
                logger.warning(f"Error closing LadybugDB connection: {e}")
        self._connected = False
        self._conn = None
        self._db = None

    async def sync_schema(self) -> dict[str, list[str]]:
        """
        Read entity_types.yaml and ALTER TABLE Brain_Entity for any new columns.
        Returns dict with 'added' columns list.
        """
        self._ensure_connected()
        entity_types = load_entity_types(self.vault_path)
        desired_fields = all_field_names(entity_types)

        # Get current columns from the database
        existing = await self._get_table_columns("Brain_Entity")
        new_columns = desired_fields - existing

        added = []
        async with self._write_lock:
            for col in sorted(new_columns):
                try:
                    await self._conn.execute(
                        f"ALTER TABLE Brain_Entity ADD {col} STRING DEFAULT NULL"
                    )
                    added.append(col)
                    logger.info(f"Brain schema: added column '{col}' to Brain_Entity")
                except Exception as e:
                    logger.warning(f"Brain schema: could not add column '{col}': {e}")

        return {"added": added}

    async def _get_table_columns(self, table_name: str) -> set[str]:
        """Get existing column names for a table via CALL table_info()."""
        try:
            result = await self._conn.execute(
                f"CALL table_info('{table_name}') RETURN *"
            )
            cols = set()
            while result.has_next():
                row = result.get_next()
                # row format: [col_id, col_name, type, default, is_primary]
                if len(row) >= 2:
                    cols.add(row[1])
            return cols
        except Exception as e:
            logger.warning(f"Could not get table columns for {table_name}: {e}")
            return set()

    # ── Entity CRUD ──────────────────────────────────────────────────────────

    async def upsert_entity(
        self,
        entity_type: str,
        name: str,
        attributes: dict[str, Any],
    ) -> dict[str, Any]:
        """
        Create or update an entity. Merges by name (PRIMARY KEY).
        Unknown field columns are silently ignored.
        """
        self._ensure_connected()
        if not name or not entity_type:
            raise ValueError("name and entity_type are required")

        now = _now()

        # Filter attributes to known columns only
        existing_cols = await self._get_table_columns("Brain_Entity")
        valid_attrs = {k: v for k, v in attributes.items() if k in existing_cols and k not in _BASE_COLUMNS}

        async with self._write_lock:
            set_clauses = [
                "e.entity_type = $entity_type",
                "e.updated_at = $updated_at",
            ]
            params: dict[str, Any] = {
                "name": name,
                "entity_type": entity_type,
                "updated_at": now,
            }
            for key, val in valid_attrs.items():
                set_clauses.append(f"e.{key} = ${key}")
                params[key] = str(val) if val is not None else None

            set_str = ", ".join(set_clauses)
            cypher = (
                f"MERGE (e:Brain_Entity {{name: $name}}) "
                f"ON CREATE SET e.created_at = $updated_at "
                f"SET {set_str}"
            )
            await self._conn.execute(cypher, params)

        entity = await self.get_entity(name)
        return entity or {"name": name, "entity_type": entity_type}

    async def get_entity(self, name: str) -> dict[str, Any] | None:
        """Retrieve entity by name."""
        self._ensure_connected()
        result = await self._conn.execute(
            "MATCH (e:Brain_Entity {name: $name}) RETURN e LIMIT 1",
            {"name": name},
        )
        if result.has_next():
            row = result.get_next()
            return _clean_node(row[0])
        return None

    async def query_entities(
        self,
        entity_type: str,
        limit: int = 100,
        offset: int = 0,
        search: str = "",
    ) -> dict[str, Any]:
        """List entities of a given type, optionally filtered by search text."""
        self._ensure_connected()

        # Get all text columns for search
        existing_cols = await self._get_table_columns("Brain_Entity")
        text_cols = existing_cols - _BASE_COLUMNS - {"name"}

        if search:
            search_conditions = ["toLower(e.name) CONTAINS toLower($q)"]
            for col in sorted(text_cols):
                search_conditions.append(
                    f"(e.{col} IS NOT NULL AND toLower(e.{col}) CONTAINS toLower($q))"
                )
            where_search = " OR ".join(search_conditions)
            where = f"e.entity_type = $etype AND ({where_search})"
            params: dict[str, Any] = {"etype": entity_type, "q": search}
        else:
            where = "e.entity_type = $etype"
            params = {"etype": entity_type}

        cypher = (
            f"MATCH (e:Brain_Entity) WHERE {where} "
            f"RETURN e ORDER BY e.updated_at DESC "
            f"SKIP {int(offset)} LIMIT {min(int(limit), 1000)}"
        )
        result = await self._conn.execute(cypher, params)
        rows = []
        while result.has_next():
            row = result.get_next()
            rows.append(_clean_node(row[0]))

        return {"results": rows, "count": len(rows), "offset": offset, "limit": limit}

    async def delete_entity(self, name: str) -> bool:
        """Delete entity and all its relationships (DETACH DELETE)."""
        self._ensure_connected()
        # Check existence first
        existing = await self.get_entity(name)
        if not existing:
            return False
        async with self._write_lock:
            await self._conn.execute(
                "MATCH (e:Brain_Entity {name: $name}) DETACH DELETE e",
                {"name": name},
            )
        return True

    # ── Schema management ────────────────────────────────────────────────────

    def list_types(self) -> list[dict]:
        """Return schema from entity_types.yaml in API format."""
        entity_types = load_entity_types(self.vault_path)
        return to_api_schema(entity_types)

    async def list_types_with_counts(self) -> list[dict]:
        """
        Return schema with live entity counts.

        Combines YAML-defined types (with structured field definitions) and any
        entity_type values that exist in the DB but haven't been crystallized yet.
        This makes the open ontology visible — agents can write any type string,
        and the UI will surface it without requiring prior schema definition.
        """
        self._ensure_connected()
        entity_types = load_entity_types(self.vault_path)

        counts: dict[str, int] = {}
        db_type_names: set[str] = set()
        try:
            result = await self._conn.execute(
                "MATCH (e:Brain_Entity) RETURN e.entity_type AS etype, count(*) AS cnt"
            )
            while result.has_next():
                row = result.get_next()
                if row[0]:
                    counts[row[0]] = row[1]
                    db_type_names.add(row[0])
        except Exception as e:
            logger.warning(f"Could not get entity counts: {e}")

        # Start with YAML-defined types (have structured field definitions)
        schema = to_api_schema(entity_types, counts)

        # Append discovered types — exist in DB but not yet crystallized in YAML
        yaml_type_names = set(entity_types.keys())
        for type_name in sorted(db_type_names - yaml_type_names):
            schema.append({
                "name": type_name,
                "description": f"{type_name} (no schema defined)",
                "fields": [],
                "entity_count": counts.get(type_name, 0),
            })

        return schema

    # ── Relationships ────────────────────────────────────────────────────────

    async def upsert_relationship(
        self,
        from_name: str,
        label: str,
        to_name: str,
        description: str = "",
    ) -> dict[str, Any]:
        """
        Create a relationship between two entities.
        Uses f-string formatting for rel properties (LadybugDB quirk: multi-param
        SET on relationship queries is unreliable; single-param SET works fine).
        """
        self._ensure_connected()
        if not from_name or not to_name or not label:
            raise ValueError("from_name, label, and to_name are required")

        now = _now()
        async with self._write_lock:
            # Step 1: Verify both entities exist and create the relationship
            await self._conn.execute(
                "MATCH (a:Brain_Entity {name: $from_name}), (b:Brain_Entity {name: $to_name}) "
                "CREATE (a)-[:Brain_Relationship]->(b)",
                {"from_name": from_name, "to_name": to_name},
            )
            # Step 2: Set relationship properties using inline values (LadybugDB quirk)
            # Single-param SET on rels works; use safe f-string for label/description
            esc_label = _esc(label)
            esc_desc = _esc(description)
            esc_now = _esc(now)
            await self._conn.execute(
                f"MATCH (a:Brain_Entity {{name: '{_esc(from_name)}'}})-[r:Brain_Relationship]->"
                f"(b:Brain_Entity {{name: '{_esc(to_name)}'}}) "
                f"SET r.label = '{esc_label}', r.description = '{esc_desc}', r.created_at = '{esc_now}'"
            )

        return {
            "from": from_name,
            "label": label,
            "to": to_name,
            "description": description,
        }

    async def traverse(self, start_name: str, max_depth: int = 2) -> list[dict[str, Any]]:
        """Traverse graph from a starting entity."""
        self._ensure_connected()
        if not 1 <= max_depth <= 5:
            raise ValueError("max_depth must be 1–5")

        result = await self._conn.execute(
            f"MATCH (s:Brain_Entity {{name: $start}})-[*1..{max_depth}]-(n:Brain_Entity) "
            "RETURN DISTINCT n LIMIT 100",
            {"start": start_name},
        )
        rows = []
        while result.has_next():
            row = result.get_next()
            rows.append(_clean_node(row[0]))
        return rows

    # ── Search ───────────────────────────────────────────────────────────────

    async def search(
        self,
        query: str,
        entity_type: str = "",
        num_results: int = 20,
    ) -> list[dict[str, Any]]:
        """Text search across name and all text field columns."""
        self._ensure_connected()
        if not query:
            return []

        existing_cols = await self._get_table_columns("Brain_Entity")
        text_cols = existing_cols - _BASE_COLUMNS - {"name"}

        search_conditions = ["toLower(e.name) CONTAINS toLower($q)"]
        for col in sorted(text_cols):
            search_conditions.append(
                f"(e.{col} IS NOT NULL AND toLower(e.{col}) CONTAINS toLower($q))"
            )
        where_search = " OR ".join(search_conditions)

        if entity_type:
            where = f"e.entity_type = $etype AND ({where_search})"
            params: dict[str, Any] = {"q": query, "etype": entity_type}
        else:
            where = f"({where_search})"
            params = {"q": query}

        result = await self._conn.execute(
            f"MATCH (e:Brain_Entity) WHERE {where} "
            f"RETURN e ORDER BY e.updated_at DESC LIMIT {min(int(num_results), 50)}",
            params,
        )
        rows = []
        while result.has_next():
            row = result.get_next()
            rows.append(_clean_node(row[0]))
        return rows

    # ── Raw Cypher ───────────────────────────────────────────────────────────

    async def execute_cypher(
        self,
        query: str,
        params: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        """Execute raw Cypher. Returns list of dicts keyed by column name."""
        self._ensure_connected()
        result = await self._conn.execute(query, params or None)
        col_names = result.get_column_names()
        rows = []
        while result.has_next():
            row = result.get_next()
            if len(col_names) == 1 and isinstance(row[0], dict):
                # Single node/rel return — clean internal fields
                rows.append(_clean_node(row[0]))
            else:
                rows.append(dict(zip(col_names, row)))
        return rows
