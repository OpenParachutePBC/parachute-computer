"""
LadybugService — Brain-specific graph operations.

Wraps GraphService with Brain ontology logic: entity types, open-schema
columns from entity_types.yaml, BM25 text search, relationships, traversal.

This is NOT the database connection — that's GraphService (core infrastructure).
LadybugService is the brain-flavored API over the shared graph.

LadybugDB quirks discovered during development:
  - Parameters are positional: conn.execute(query, params_dict) not parameters=...
  - $param works in MATCH/MERGE node patterns and most SET clauses
  - Multi-param SET on relationship queries can fail; use f-strings with sanitized values
  - 'desc' is a reserved keyword (use 'description')
  - DETACH DELETE works for nodes with relationships
  - RETURN e (node) returns dict with _ID, _LABEL + all columns
"""

import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from parachute.db.graph import GraphService

from .schema import all_field_names, load_entity_types, to_api_schema

logger = logging.getLogger(__name__)

# Base columns always present on Brain_Entity (never schema-managed).
_BASE_COLUMNS = {"name", "entity_type", "created_at", "updated_at"}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _esc(value: str) -> str:
    """Escape a string value for safe inline use in Cypher (single-quote escape)."""
    return str(value).replace("'", "\\'")


class LadybugService:
    """Brain-specific graph operations. Wraps GraphService with brain ontology logic."""

    def __init__(self, graph: GraphService, vault_path: Path):
        self.graph = graph
        self.vault_path = vault_path

    async def init_brain_schema(self) -> None:
        """
        Ensure Brain_Entity and Brain_Relationship tables exist, then sync
        columns from entity_types.yaml. Called once by BrainModule on load.
        """
        await self.graph.ensure_node_table(
            "Brain_Entity",
            {
                "name": "STRING",
                "entity_type": "STRING",
                "description": "STRING",
                "created_at": "STRING",
                "updated_at": "STRING",
            },
            primary_key="name",
        )
        await self.graph.ensure_rel_table(
            "Brain_Relationship",
            "Brain_Entity",
            "Brain_Entity",
            {"label": "STRING", "description": "STRING", "created_at": "STRING"},
        )

        # Legacy migration: ensure 'description' column exists on older databases
        existing = await self.graph.get_table_columns("Brain_Entity")
        if "description" not in existing:
            async with self.graph.write_lock:
                await self.graph.execute(
                    "ALTER TABLE Brain_Entity ADD description STRING DEFAULT NULL"
                )
            logger.info("Brain schema: migrated — added 'description' column")

        await self.sync_schema()

    async def sync_schema(self) -> dict[str, list[str]]:
        """
        Read entity_types.yaml and ALTER TABLE Brain_Entity for any new columns.
        Returns dict with 'added' columns list.
        """
        entity_types = load_entity_types(self.vault_path)
        desired_fields = all_field_names(entity_types)
        existing = await self.graph.get_table_columns("Brain_Entity")
        new_columns = desired_fields - existing

        added = []
        async with self.graph.write_lock:
            for col in sorted(new_columns):
                try:
                    await self.graph.execute(
                        f"ALTER TABLE Brain_Entity ADD {col} STRING DEFAULT NULL"
                    )
                    added.append(col)
                    logger.info(f"Brain schema: added column '{col}' to Brain_Entity")
                except Exception as e:
                    logger.warning(f"Brain schema: could not add column '{col}': {e}")

        return {"added": added}

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
        if not name or not entity_type:
            raise ValueError("name and entity_type are required")

        now = _now()
        existing_cols = await self.graph.get_table_columns("Brain_Entity")
        valid_attrs = {
            k: v for k, v in attributes.items()
            if k in existing_cols and k not in _BASE_COLUMNS
        }

        async with self.graph.write_lock:
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
            await self.graph.execute(cypher, params)

        entity = await self.get_entity(name)
        return entity or {"name": name, "entity_type": entity_type}

    async def get_entity(self, name: str) -> dict[str, Any] | None:
        """Retrieve entity by name."""
        rows = await self.graph.execute_cypher(
            "MATCH (e:Brain_Entity {name: $name}) RETURN e LIMIT 1",
            {"name": name},
        )
        return rows[0] if rows else None

    async def query_entities(
        self,
        entity_type: str,
        limit: int = 100,
        offset: int = 0,
        search: str = "",
    ) -> dict[str, Any]:
        """List entities of a given type, optionally filtered by search text."""
        existing_cols = await self.graph.get_table_columns("Brain_Entity")
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
        rows = await self.graph.execute_cypher(cypher, params)
        return {"results": rows, "count": len(rows), "offset": offset, "limit": limit}

    async def delete_entity(self, name: str) -> bool:
        """Delete entity and all its relationships (DETACH DELETE)."""
        existing = await self.get_entity(name)
        if not existing:
            return False
        async with self.graph.write_lock:
            await self.graph.execute(
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
        """
        entity_types = load_entity_types(self.vault_path)

        counts: dict[str, int] = {}
        db_type_names: set[str] = set()
        try:
            result = await self.graph.execute(
                "MATCH (e:Brain_Entity) RETURN e.entity_type AS etype, count(*) AS cnt"
            )
            while result.has_next():
                row = result.get_next()
                if row[0]:
                    counts[row[0]] = row[1]
                    db_type_names.add(row[0])
        except Exception as e:
            logger.warning(f"Could not get entity counts: {e}")

        schema = to_api_schema(entity_types, counts)

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
        SET on relationship queries is unreliable).
        """
        if not from_name or not to_name or not label:
            raise ValueError("from_name, label, and to_name are required")

        now = _now()
        async with self.graph.write_lock:
            await self.graph.execute(
                "MATCH (a:Brain_Entity {name: $from_name}), (b:Brain_Entity {name: $to_name}) "
                "CREATE (a)-[:Brain_Relationship]->(b)",
                {"from_name": from_name, "to_name": to_name},
            )
            esc_label = _esc(label)
            esc_desc = _esc(description)
            esc_now = _esc(now)
            await self.graph.execute(
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
        if not 1 <= max_depth <= 5:
            raise ValueError("max_depth must be 1–5")

        return await self.graph.execute_cypher(
            f"MATCH (s:Brain_Entity {{name: $start}})-[*1..{max_depth}]-(n:Brain_Entity) "
            "RETURN DISTINCT n LIMIT 100",
            {"start": start_name},
        )

    # ── Search ───────────────────────────────────────────────────────────────

    async def search(
        self,
        query: str,
        entity_type: str = "",
        num_results: int = 20,
    ) -> list[dict[str, Any]]:
        """Text search across name and all text field columns."""
        if not query:
            return []

        existing_cols = await self.graph.get_table_columns("Brain_Entity")
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

        return await self.graph.execute_cypher(
            f"MATCH (e:Brain_Entity) WHERE {where} "
            f"RETURN e ORDER BY e.updated_at DESC LIMIT {min(int(num_results), 50)}",
            params,
        )

    # ── Raw Cypher (passthrough) ──────────────────────────────────────────────

    async def execute_cypher(
        self,
        query: str,
        params: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        """Execute raw Cypher. Delegates to GraphService."""
        return await self.graph.execute_cypher(query, params)
