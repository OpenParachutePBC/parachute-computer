"""
Knowledge Graph Service for Brain

Async wrapper around TerminusDB client with WOQL-based graph traversal.
All blocking operations use asyncio.to_thread() to prevent event loop blocking.
"""

from pathlib import Path
from typing import Any, TYPE_CHECKING
import asyncio
import os
import logging
import re
import threading
from collections import deque
from terminusdb_client import WOQLClient
from terminusdb_client.errors import DatabaseError, APIError, InterfaceError

if TYPE_CHECKING:
    from .models import FieldSpec

logger = logging.getLogger(__name__)


def _format_field_for_api(
    field_def: Any,
    enum_values: dict[str, list[str]],
) -> dict[str, Any]:
    """Convert a TerminusDB field definition to Flutter-friendly format."""
    _reverse_type_map = {
        "xsd:string": "string",
        "xsd:integer": "integer",
        "xsd:boolean": "boolean",
        "xsd:dateTime": "datetime",
    }

    if isinstance(field_def, str):
        type_name = _reverse_type_map.get(field_def, field_def)
        if field_def in enum_values:
            return {"type": "enum", "required": True, "values": enum_values[field_def]}
        return {"type": type_name, "required": True}

    if not isinstance(field_def, dict):
        return {"type": "string", "required": False}

    field_type = field_def.get("@type", "")
    field_class = field_def.get("@class", "")

    if field_type == "Optional":
        type_name = _reverse_type_map.get(field_class, field_class)
        if field_class in enum_values:
            return {"type": "enum", "required": False, "values": enum_values[field_class]}
        # Link field: class is a TerminusDB type name (PascalCase)
        if field_class and field_class[0].isupper() and field_class not in _reverse_type_map:
            return {"type": "link", "required": False, "link_type": field_class}
        return {"type": type_name, "required": False}

    if field_type == "Set":
        if isinstance(field_class, str):
            item_type = _reverse_type_map.get(field_class, field_class)
        else:
            item_type = "string"
        return {"type": "array", "required": False, "items": item_type}

    # Required link field
    if field_type and field_type[0].isupper() and field_type not in _reverse_type_map:
        return {"type": "link", "required": True, "link_type": field_type}

    return {"type": "string", "required": False}


# Reserved TerminusDB names that cannot be used as type names
_RESERVED_TERMINUS_NAMES = frozenset({
    "Class", "Enum", "Set", "Optional", "TaggedUnion", "Array",
    "Sys", "xsd", "rdf", "owl", "rdfs",
})

# Allowed field types for schema creation
_ALLOWED_FIELD_TYPES = frozenset({
    "string", "integer", "boolean", "datetime", "enum", "link",
})


class KnowledgeGraphService:
    """Async wrapper around TerminusDB client"""

    def __init__(
        self,
        vault_path: Path,
        server_url: str = "http://localhost:6363",
        db_name: str = "parachute_brain",
    ):
        # SECURITY: Validate vault_path early
        if not vault_path.exists():
            raise ValueError(f"Vault path does not exist: {vault_path}")
        if not vault_path.is_dir():
            raise ValueError(f"Vault path is not a directory: {vault_path}")

        self.vault_path = vault_path
        self.server_url = server_url
        self.db_name = db_name
        self.client: WOQLClient | None = None
        self._connected = False
        # WOQLClient uses requests.Session which is not thread-safe.
        # All client calls from asyncio.to_thread() must acquire this lock.
        self._client_lock = threading.Lock()

    def _ensure_connected(self) -> None:
        """Raise RuntimeError if not connected to TerminusDB."""
        if not self._connected:
            raise RuntimeError("Not connected. Call connect() first.")

    async def connect(self, schemas: list[dict[str, Any]]) -> None:
        """
        Connect to TerminusDB and initialize database with schemas.

        Uses asyncio.to_thread() to wrap blocking terminusdb-client calls.
        CRITICAL: Never use subprocess.run() or blocking calls in async context!
        """
        def _connect_sync():
            password: str | None = os.getenv("TERMINUSDB_ADMIN_PASS")
            if not password:
                raise ValueError(
                    "TERMINUSDB_ADMIN_PASS environment variable required. "
                    "Generate with: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
                )

            client = WOQLClient(self.server_url)
            client.connect(
                team="admin",
                user="admin",
                key=password,
            )

            # Create database if not exists
            try:
                client.connect(db=self.db_name, team="admin", user="admin", key=password)
                logger.info(f"Connected to existing database: {self.db_name}")
            except (DatabaseError, InterfaceError):
                # Database doesn't exist, create it
                client.create_database(
                    dbid=self.db_name,
                    team="admin",
                    label="Parachute Brain Knowledge Graph",
                    description="Brain entities and relationships",
                    include_schema=True,
                )
                client.connect(db=self.db_name, team="admin", user="admin", key=password)
                logger.info(f"Created new database: {self.db_name}")

            # Additive-only: only insert seed types that don't already exist.
            # User-created types (via API) must survive server restarts.
            existing_docs = list(client.get_all_documents(graph_type="schema"))
            existing_ids = {d.get("@id") for d in existing_docs}
            new_schemas = [
                s for s in schemas
                if s.get("@id") not in existing_ids
            ]
            if new_schemas:
                client.insert_document(
                    new_schemas,
                    graph_type="schema",
                    commit_msg="Bootstrap seed schemas",
                )
                logger.info(f"Inserted {len(new_schemas)} new seed schemas into TerminusDB")
            else:
                logger.info("All seed schemas already present — no changes needed")

            return client

        # CRITICAL PATTERN: Use asyncio.to_thread() for blocking client calls
        # Never use subprocess.run() in async context (freezes event loop)
        new_client = await asyncio.to_thread(_connect_sync)

        # Atomic update
        self.client = new_client
        self._connected = True

    async def create_entity(
        self,
        entity_type: str,
        data: dict[str, Any],
        commit_msg: str | None = None,
    ) -> str:
        """Create entity, returns IRI"""
        self._ensure_connected()

        logger.info(f"Creating {entity_type} entity", extra={"entity_type": entity_type})

        def _create_sync():
            doc = {"@type": entity_type, **data}
            result = self.client.insert_document(
                doc,
                commit_msg=commit_msg or f"Create {entity_type}",
            )
            # TerminusDB returns list of IRIs — extract first one
            entity_id = result[0] if isinstance(result, list) else result
            logger.debug(f"Created entity: {entity_id}")
            return entity_id

        try:
            return await asyncio.to_thread(_create_sync)
        except (DatabaseError, APIError) as e:
            logger.error(f"TerminusDB error creating {entity_type}", exc_info=True)
            raise
        except Exception as e:
            logger.exception(f"Unexpected error creating {entity_type}")
            raise

    async def query_entities(
        self,
        entity_type: str,
        filters: dict[str, Any] | None = None,
        limit: int = 100,
        offset: int = 0,
    ) -> dict[str, Any]:
        """Query entities by type and optional filters

        PERFORMANCE: Added pagination to prevent OOM on large result sets
        """
        self._ensure_connected()

        logger.info(
            f"Querying {entity_type} entities",
            extra={"entity_type": entity_type, "limit": limit, "offset": offset}
        )

        def _query_sync():
            template = {"@type": entity_type}
            if filters:
                template.update(filters)

            # CRITICAL: Use limit for memory safety (cap at 1000)
            results = list(self.client.query_document(
                template,
                skip=offset,
                count=min(limit, 1000),
            ))

            logger.debug(f"Query returned {len(results)} results")

            return {
                "results": results,
                "count": len(results),
                "offset": offset,
                "limit": limit,
            }

        try:
            return await asyncio.to_thread(_query_sync)
        except (DatabaseError, APIError) as e:
            logger.error(f"Query failed for {entity_type}", exc_info=True)
            raise

    async def get_entity(self, entity_id: str) -> dict[str, Any] | None:
        """Retrieve single entity by IRI"""
        self._ensure_connected()

        def _get_sync():
            try:
                return self.client.get_document(entity_id)
            except (DatabaseError, APIError) as e:
                logger.warning(f"Entity not found: {entity_id}", exc_info=True)
                return None
            except Exception:
                return None

        return await asyncio.to_thread(_get_sync)

    async def update_entity(
        self,
        entity_id: str,
        data: dict[str, Any],
        commit_msg: str | None = None,
    ) -> None:
        """Update entity fields"""
        self._ensure_connected()

        logger.info(f"Updating entity: {entity_id}")

        def _update_sync():
            # Get current document
            doc = self.client.get_document(entity_id)

            # Apply updates
            doc.update(data)

            # Save
            self.client.update_document(
                doc,
                commit_msg=commit_msg or f"Update {entity_id}",
            )

        try:
            await asyncio.to_thread(_update_sync)
        except (DatabaseError, APIError) as e:
            logger.error(f"Failed to update {entity_id}", exc_info=True)
            raise

    async def delete_entity(
        self,
        entity_id: str,
        commit_msg: str | None = None,
    ) -> None:
        """Delete entity from knowledge graph"""
        self._ensure_connected()

        logger.info(f"Deleting entity: {entity_id}")

        def _delete_sync():
            self.client.delete_document({"@id": entity_id})

        try:
            await asyncio.to_thread(_delete_sync)
        except (DatabaseError, APIError) as e:
            logger.error(f"Failed to delete {entity_id}", exc_info=True)
            raise

    async def list_schemas(self) -> list[dict[str, Any]]:
        """List all available entity schemas with field definitions"""
        self._ensure_connected()

        def _list_sync():
            # Query TerminusDB schema graph
            schema_docs = self.client.query_document(
                {"@type": "Class"},
                graph_type="schema"
            )
            return schema_docs

        try:
            return await asyncio.to_thread(_list_sync)
        except (DatabaseError, APIError) as e:
            logger.error("Failed to list schemas", exc_info=True)
            raise

    async def count_entities(self, entity_type: str) -> int:
        """Count entities of a given type."""
        self._ensure_connected()

        def _count_sync():
            with self._client_lock:
                results = self.client.query_document({"@type": entity_type}, count=100)
                return len(list(results))

        try:
            return await asyncio.to_thread(_count_sync)
        except Exception:
            return 0

    async def list_schema_types_with_counts(self) -> list[dict[str, Any]]:
        """List all schema types with entity counts.

        Uses asyncio.gather() for concurrent count queries (O(1) parallel latency).
        If > 20 types, skips counts (returns -1) to avoid too many connections.
        """
        self._ensure_connected()

        def _list_schema_docs_sync() -> tuple[list[dict[str, Any]], dict[str, list[str]]]:
            with self._client_lock:
                all_docs = list(self.client.get_all_documents(graph_type="schema"))
            class_docs = [d for d in all_docs if d.get("@type") == "Class"]
            enum_map = {
                d["@id"]: d.get("@value", [])
                for d in all_docs if d.get("@type") == "Enum"
            }
            return class_docs, enum_map

        class_docs, enum_values = await asyncio.to_thread(_list_schema_docs_sync)

        # Format class docs to Flutter-friendly field list
        types: list[dict[str, Any]] = []
        for doc in class_docs:
            type_id = doc.get("@id", "")
            if not type_id:
                continue
            key_config = doc.get("@key", {})
            documentation = doc.get("@documentation", {})
            fields = []
            for key, value in doc.items():
                if key.startswith("@"):
                    continue
                field_info = _format_field_for_api(value, enum_values)
                field_info["name"] = key
                fields.append(field_info)
            types.append({
                "name": type_id,
                "description": documentation.get("@comment") if isinstance(documentation, dict) else None,
                "key_strategy": key_config.get("@type") if isinstance(key_config, dict) else None,
                "fields": fields,
                "entity_count": -1,  # filled below
            })

        # Fetch entity counts concurrently (skip if > 20 types)
        if len(types) <= 20:
            async def get_count(type_name: str) -> int:
                def _count():
                    with self._client_lock:
                        results = self.client.query_document({"@type": type_name}, count=100)
                        return len(list(results))
                return await asyncio.to_thread(_count)

            counts = await asyncio.gather(
                *[get_count(t["name"]) for t in types],
                return_exceptions=True,
            )
            for t, count in zip(types, counts):
                t["entity_count"] = count if isinstance(count, int) else -1

        return types

    async def list_all_schema_docs(self) -> list[dict[str, Any]]:
        """Return all schema graph documents (Enums + Classes) for cache reload."""
        self._ensure_connected()

        def _fetch():
            with self._client_lock:
                all_docs = list(self.client.get_all_documents(graph_type="schema"))
            return all_docs

        return await asyncio.to_thread(_fetch)

    def _validate_type_name(self, name: str) -> None:
        """Raise ValueError if name is reserved or malformed."""
        if not re.match(r'^[A-Za-z][A-Za-z0-9_]*$', name):
            raise ValueError(
                f"Type name must match ^[A-Za-z][A-Za-z0-9_]*$, got '{name}'"
            )
        if name in _RESERVED_TERMINUS_NAMES:
            raise ValueError(
                f"Type name '{name}' is reserved by TerminusDB and cannot be used."
            )

    def _compile_field_from_spec(
        self,
        field_spec: "FieldSpec",
        class_name: str,
        field_name: str,
        enum_docs: list[dict[str, Any]],
    ) -> "str | dict[str, Any]":
        """Convert FieldSpec Pydantic model to TerminusDB field definition.

        Bridge to SchemaCompiler._compile_field() which expects a dict.
        """
        if field_spec.type not in _ALLOWED_FIELD_TYPES:
            raise ValueError(f"Unknown field type '{field_spec.type}'")

        if field_spec.type == "link":
            if not field_spec.link_type:
                raise ValueError("link field requires link_type")
            if not re.match(r'^[A-Za-z][A-Za-z0-9_]*$', field_spec.link_type):
                raise ValueError(f"Invalid link_type '{field_spec.link_type}'")
            spec_dict: dict[str, Any] = {
                "type": field_spec.link_type,
                "required": field_spec.required,
            }
        else:
            spec_dict = {
                "type": field_spec.type,
                "required": field_spec.required,
                "values": field_spec.values or [],
            }

        from .schema_compiler import SchemaCompiler
        compiler = SchemaCompiler()
        return compiler._compile_field(spec_dict, class_name, field_name, enum_docs)

    async def create_schema_type(
        self,
        name: str,
        fields: dict[str, Any],
        key_strategy: str = "Random",
        description: str | None = None,
    ) -> None:
        """Insert a new Class document into the TerminusDB schema graph.

        Enum documents MUST be inserted before the Class document (TerminusDB v12).
        """
        self._validate_type_name(name)

        from .models import FieldSpec
        enum_docs: list[dict[str, Any]] = []
        compiled_fields: dict[str, Any] = {}

        for field_name, field_data in fields.items():
            if isinstance(field_data, dict):
                field_spec = FieldSpec.model_validate(field_data)
            else:
                field_spec = field_data
            compiled_fields[field_name] = self._compile_field_from_spec(
                field_spec, name, field_name, enum_docs
            )

        from .schema_compiler import SchemaCompiler
        compiler = SchemaCompiler()
        key_doc = compiler._build_key_strategy({"key_strategy": key_strategy})

        class_doc: dict[str, Any] = {
            "@type": "Class",
            "@id": name,
            "@key": key_doc,
            **compiled_fields,
        }
        if description:
            class_doc["@documentation"] = {"@comment": description}

        def _insert_sync():
            with self._client_lock:
                if enum_docs:
                    self.client.insert_document(
                        enum_docs, graph_type="schema",
                        commit_msg=f"Add enums for {name}",
                    )
                self.client.insert_document(
                    class_doc, graph_type="schema",
                    commit_msg=f"Create type {name}",
                )

        await asyncio.to_thread(_insert_sync)

    async def update_schema_type(
        self,
        name: str,
        fields: dict[str, Any],
    ) -> None:
        """Replace a Class document in the TerminusDB schema graph.

        Field additions are safe. Field type changes with existing data may raise
        DatabaseError (strengthening constraint) — caught and re-raised as ValueError.
        """
        self._ensure_connected()

        from .models import FieldSpec
        enum_docs: list[dict[str, Any]] = []
        compiled_fields: dict[str, Any] = {}

        for field_name, field_data in fields.items():
            if isinstance(field_data, dict):
                field_spec = FieldSpec.model_validate(field_data)
            else:
                field_spec = field_data
            compiled_fields[field_name] = self._compile_field_from_spec(
                field_spec, name, field_name, enum_docs
            )

        class_doc: dict[str, Any] = {
            "@type": "Class",
            "@id": name,
            **compiled_fields,
        }

        def _replace_sync():
            with self._client_lock:
                if enum_docs:
                    self.client.replace_document(
                        enum_docs, graph_type="schema",
                        create=True, commit_msg=f"Update enums for {name}",
                    )
                try:
                    self.client.replace_document(
                        class_doc, graph_type="schema",
                        commit_msg=f"Update type {name}",
                    )
                except Exception as e:
                    raise ValueError(f"Schema update rejected by TerminusDB: {e}") from e

        await asyncio.to_thread(_replace_sync)

    async def delete_schema_type(self, name: str) -> None:
        """Delete a Class and its Enum documents from the schema graph.

        Uses batch delete_document call for efficiency.
        Caller must verify entity count = 0 before calling this.
        """
        self._ensure_connected()

        def _delete_sync():
            with self._client_lock:
                # Fetch class doc to find associated enum IDs
                try:
                    class_doc = self.client.get_document(name, graph_type="schema")
                    # Enum IDs follow the pattern {TypeName}_{fieldName}
                    enum_ids = [
                        v for v in class_doc.values()
                        if isinstance(v, str) and v.startswith(f"{name}_")
                    ]
                except Exception:
                    enum_ids = []

                # Batch delete: class + all its enums in one call
                ids_to_delete: list[str] = [name] + enum_ids
                self.client.delete_document(
                    ids_to_delete,
                    graph_type="schema",
                    commit_msg=f"Delete type {name}",
                )

        await asyncio.to_thread(_delete_sync)

    async def create_relationship(
        self,
        from_id: str,
        relationship: str,
        to_id: str,
        commit_msg: str | None = None,
    ) -> None:
        """
        Create relationship between entities.

        Adds to_id to from_entity's relationship field (array).
        Creates bidirectional link if schema defines inverse.
        """
        self._ensure_connected()

        logger.info(f"Creating relationship: {from_id} --[{relationship}]--> {to_id}")

        def _create_rel_sync():
            # Get source entity
            from_doc = self.client.get_document(from_id)

            # Add relationship
            if relationship not in from_doc:
                from_doc[relationship] = []
            if to_id not in from_doc[relationship]:
                from_doc[relationship].append(to_id)

            # Update
            self.client.update_document(
                from_doc,
                commit_msg=commit_msg or f"Link {from_id} -> {to_id} via {relationship}",
            )

        try:
            await asyncio.to_thread(_create_rel_sync)
        except (DatabaseError, APIError) as e:
            logger.error(f"Failed to create relationship", exc_info=True)
            raise

    async def traverse_graph(
        self,
        start_id: str,
        relationship: str,
        max_depth: int = 2,
    ) -> list[dict[str, Any]]:
        """
        Traverse graph from starting entity following relationship.

        PERFORMANCE: Uses WOQL path query for server-side traversal (not N+1)
        Returns list of connected entities up to max_depth hops.
        """
        self._ensure_connected()

        # SECURITY: Enforce max_depth ceiling
        if max_depth < 1 or max_depth > 5:
            raise ValueError(f"max_depth must be 1-5, got {max_depth}")

        logger.info(
            f"Traversing graph from {start_id} via {relationship} (depth={max_depth})"
        )

        def _traverse_woql():
            """PERFORMANCE FIX: Use WOQL for server-side traversal (not BFS)"""
            from terminusdb_client.woqlquery import WOQLQuery as Q

            try:
                # Single WOQL query replaces N individual gets
                query = Q().path(
                    start_id,
                    f"({relationship})*",  # Kleene star for recursive traversal
                    "v:Target",
                    path="v:Path",
                ).limit(1000)  # Safety limit

                results = self.client.query(query)

                # Filter by max_depth in Python (WOQL doesn't have depth limit)
                filtered = [r for r in results if len(r.get("Path", [])) <= max_depth]

                logger.debug(f"Traversal found {len(filtered)} entities")

                return filtered
            except Exception as e:
                # Fallback to BFS if WOQL path query not supported
                logger.warning(f"WOQL path query failed, using BFS fallback: {e}")
                return self._traverse_bfs(start_id, relationship, max_depth)

        return await asyncio.to_thread(_traverse_woql)

    def _traverse_bfs(
        self, start_id: str, relationship: str, max_depth: int
    ) -> list[dict[str, Any]]:
        """
        Fallback BFS traversal (OPTIMIZED with safety limits)

        SECURITY: Prevents DoS via deep traversal or queue explosion
        """
        MAX_QUEUE_SIZE = 10000  # Prevent queue explosion
        MAX_RESULTS = 1000  # Prevent memory exhaustion

        visited = set()
        results = []
        queue = deque([(start_id, 0)])  # PERFORMANCE: Use deque (O(1) popleft)

        while queue:
            # SECURITY: Check queue size before pop
            if len(queue) > MAX_QUEUE_SIZE:
                logger.warning(f"Traversal queue exceeded {MAX_QUEUE_SIZE}, stopping early")
                break

            if len(results) >= MAX_RESULTS:
                logger.warning(f"Traversal results exceeded {MAX_RESULTS}, stopping early")
                break

            entity_id, depth = queue.popleft()  # PERFORMANCE: O(1) with deque

            # SECURITY: Check depth BEFORE processing
            if depth > max_depth:
                continue

            if entity_id in visited:
                continue

            visited.add(entity_id)

            # Get entity
            try:
                entity = self.client.get_document(entity_id)
            except Exception as e:
                logger.warning(f"Failed to fetch entity {entity_id}: {e}")
                continue

            if not entity:
                continue

            results.append(entity)

            # Follow relationships only if not at max depth
            if depth < max_depth and relationship in entity:
                related_ids = entity[relationship]
                if not isinstance(related_ids, list):
                    related_ids = [related_ids]

                for related_id in related_ids:
                    if related_id not in visited:
                        queue.append((related_id, depth + 1))

        return results

    async def export_to_rdf(self, output_path: Path) -> None:
        """Export current graph state to RDF/Turtle format"""
        # TODO: Phase 2 - implement RDF export
        pass
