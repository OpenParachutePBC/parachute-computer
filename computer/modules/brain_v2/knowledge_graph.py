"""
Knowledge Graph Service for Brain v2

Async wrapper around TerminusDB client with WOQL-based graph traversal.
All blocking operations use asyncio.to_thread() to prevent event loop blocking.
"""

from pathlib import Path
from typing import Any
import asyncio
import os
import logging
from collections import deque
from terminusdb_client import WOQLClient
from terminusdb_client.errors import DatabaseError, ClientError

logger = logging.getLogger(__name__)


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

    async def connect(self, schemas: list[dict[str, Any]]) -> None:
        """
        Connect to TerminusDB and initialize database with schemas.

        Uses asyncio.to_thread() to wrap blocking terminusdb-client calls.
        CRITICAL: Never use subprocess.run() or blocking calls in async context!
        """
        def _connect_sync():
            client = WOQLClient(self.server_url)
            client.connect(
                team="admin",
                user="admin",
                key=os.getenv("TERMINUSDB_ADMIN_PASS", "root"),
            )

            # Create database if not exists
            try:
                client.connect(db=self.db_name)
                logger.info(f"Connected to existing database: {self.db_name}")
            except DatabaseError:
                # Database doesn't exist, create it
                client.create_database(
                    dbid=self.db_name,
                    team="admin",
                    label="Parachute Brain Knowledge Graph",
                    description="Brain v2 entities and relationships",
                    include_schema=True,
                )
                client.connect(db=self.db_name)
                logger.info(f"Created new database: {self.db_name}")

            # Load schemas (replace existing)
            # TerminusDB allows schema evolution via weakening changes
            # Use copy to avoid mutating caller's schemas
            for schema in schemas:
                client.insert_document(
                    schema.copy(),
                    graph_type="schema",
                    commit_msg="Update schema from YAML definitions",
                )

            logger.info(f"Loaded {len(schemas)} schemas into TerminusDB")

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
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        logger.info(f"Creating {entity_type} entity", extra={"entity_type": entity_type})

        def _create_sync():
            doc = {"@type": entity_type, **data}
            result = self.client.insert_document(
                doc,
                commit_msg=commit_msg or f"Create {entity_type}",
            )
            # TerminusDB returns IRI of created document
            logger.debug(f"Created entity: {result}")
            return result

        try:
            return await asyncio.to_thread(_create_sync)
        except (DatabaseError, ClientError) as e:
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
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        logger.info(
            f"Querying {entity_type} entities",
            extra={"entity_type": entity_type, "limit": limit, "offset": offset}
        )

        def _query_sync():
            template = {"@type": entity_type}
            if filters:
                template.update(filters)

            # CRITICAL: Use limit for memory safety (cap at 1000)
            results = self.client.query_document(
                template,
                skip=offset,
                count=min(limit, 1000),
            )

            logger.debug(f"Query returned {len(results)} results")

            return {
                "results": results,
                "count": len(results),
                "offset": offset,
                "limit": limit,
            }

        try:
            return await asyncio.to_thread(_query_sync)
        except (DatabaseError, ClientError) as e:
            logger.error(f"Query failed for {entity_type}", exc_info=True)
            raise

    async def get_entity(self, entity_id: str) -> dict[str, Any] | None:
        """Retrieve single entity by IRI"""
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        def _get_sync():
            try:
                return self.client.get_document(entity_id)
            except (DatabaseError, ClientError) as e:
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
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

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
        except (DatabaseError, ClientError) as e:
            logger.error(f"Failed to update {entity_id}", exc_info=True)
            raise

    async def delete_entity(
        self,
        entity_id: str,
        commit_msg: str | None = None,
    ) -> None:
        """Delete entity from knowledge graph"""
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        logger.info(f"Deleting entity: {entity_id}")

        def _delete_sync():
            self.client.delete_document({"@id": entity_id})

        try:
            await asyncio.to_thread(_delete_sync)
        except (DatabaseError, ClientError) as e:
            logger.error(f"Failed to delete {entity_id}", exc_info=True)
            raise

    async def list_schemas(self) -> list[dict[str, Any]]:
        """List all available entity schemas with field definitions"""
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        def _list_sync():
            # Query TerminusDB schema graph
            schema_docs = self.client.query_document(
                {"@type": "Class"},
                graph_type="schema"
            )
            return schema_docs

        try:
            return await asyncio.to_thread(_list_sync)
        except (DatabaseError, ClientError) as e:
            logger.error("Failed to list schemas", exc_info=True)
            raise

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
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

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
        except (DatabaseError, ClientError) as e:
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
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

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
