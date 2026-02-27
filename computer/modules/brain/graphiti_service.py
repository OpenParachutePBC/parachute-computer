"""
Graphiti + Kuzu Knowledge Graph Service

Replaces knowledge_graph.py (TerminusDB). All writes are serialized via
asyncio.Lock since Kuzu is embedded (single-process, single-writer).
"""

import asyncio
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Default number of search results
_DEFAULT_SEARCH_LIMIT = 10
# Retry delays for add_episode LLM errors (seconds)
_RETRY_DELAYS = [5, 15, 45]


class GraphitiService:
    """Async wrapper around Graphiti + Kuzu."""

    def __init__(
        self,
        kuzu_path: Path,
        group_id: str = "user-default",
        anthropic_api_key: str | None = None,
        google_api_key: str | None = None,
    ):
        self.kuzu_path = kuzu_path
        self.group_id = group_id
        # Keys must be passed explicitly — no env var fallback.
        # Falling back to ANTHROPIC_API_KEY would cause it to leak into the
        # Claude CLI subprocess environment and bill all chat inference to the
        # API key instead of the Claude Max subscription.
        self._anthropic_api_key = anthropic_api_key
        self._google_api_key = google_api_key

        self._graphiti = None
        self._driver = None
        self._connected = False
        self._write_lock = asyncio.Lock()

    def _ensure_connected(self) -> None:
        if not self._connected or self._graphiti is None:
            raise RuntimeError("GraphitiService not connected. Call connect() first.")

    async def connect(self) -> None:
        """Initialize Graphiti + Kuzu. Idempotent — safe to call multiple times."""
        if self._connected:
            return

        # Validate required API keys
        if not self._anthropic_api_key:
            raise ValueError(
                "Brain module requires an Anthropic API key for LLM entity extraction. "
                "Add it to vault/.parachute/config.yaml:\n"
                "  brain:\n"
                "    anthropic_api_key: sk-ant-api03-..."
            )
        if not self._google_api_key:
            raise ValueError(
                "Brain module requires a Google API key for Gemini embeddings. "
                "Get one free at aistudio.google.com, then add it to "
                "vault/.parachute/config.yaml:\n"
                "  brain:\n"
                "    google_api_key: AIza..."
            )

        from graphiti_core import Graphiti
        from graphiti_core.driver.kuzu_driver import KuzuDriver
        from graphiti_core.llm_client.anthropic_client import AnthropicClient
        from graphiti_core.llm_client import LLMConfig
        from graphiti_core.embedder.gemini import GeminiEmbedder, GeminiEmbedderConfig

        # Ensure kuzu directory exists
        self.kuzu_path.mkdir(parents=True, exist_ok=True)

        # LLM client: Anthropic (claude-haiku-4-5-latest for cost efficiency)
        llm_config = LLMConfig(
            api_key=self._anthropic_api_key,
            model="claude-haiku-4-5-20251001",
        )
        llm_client = AnthropicClient(config=llm_config)

        # Embedder: Gemini text-embedding-004 (fast, free tier available)
        embedder_config = GeminiEmbedderConfig(
            api_key=self._google_api_key,
            embedding_model="text-embedding-004",
        )
        embedder = GeminiEmbedder(config=embedder_config)

        # Kuzu embedded database
        self._driver = KuzuDriver(db=str(self.kuzu_path))

        # Graphiti instance
        self._graphiti = Graphiti(
            graph_driver=self._driver,
            llm_client=llm_client,
            embedder=embedder,
        )

        # Initialize schema (idempotent — safe to call on existing db)
        await self._graphiti.build_indices_and_constraints()
        self._connected = True
        logger.info(f"GraphitiService connected: kuzu at {self.kuzu_path}, group={self.group_id}")

    async def add_episode(
        self,
        name: str,
        episode_body: str,
        source_description: str,
        reference_time: datetime | None = None,
        entity_types: dict | None = None,
    ) -> dict[str, Any]:
        """
        Ingest text as an episode. LLM extracts entities and relationships.

        Serialized via write lock — callers queue transparently.
        Retries on LLM errors with exponential backoff.
        """
        self._ensure_connected()
        if reference_time is None:
            reference_time = datetime.now(timezone.utc)

        from .entities import ENTITY_TYPES
        types = entity_types or ENTITY_TYPES

        last_exc = None
        for attempt, delay in enumerate([0] + _RETRY_DELAYS):
            if delay:
                logger.warning(f"add_episode retry {attempt}/{len(_RETRY_DELAYS)} after {delay}s")
                await asyncio.sleep(delay)
            try:
                async with self._write_lock:
                    result = await self._graphiti.add_episode(
                        name=name,
                        episode_body=episode_body,
                        source_description=source_description,
                        reference_time=reference_time,
                        group_id=self.group_id,
                        entity_types=types,
                    )

                episode_uuid = getattr(result, "episode_uuid", None)
                nodes = getattr(result, "nodes", []) or []
                edges = getattr(result, "edges", []) or []
                logger.info(
                    f"Episode added: {name!r}, nodes={len(nodes)}, edges={len(edges)}"
                )
                return {
                    "success": True,
                    "episode_uuid": str(episode_uuid) if episode_uuid else None,
                    "nodes_created": len(nodes),
                    "edges_created": len(edges),
                }
            except Exception as e:
                last_exc = e
                logger.warning(f"add_episode attempt {attempt + 1} failed: {e}")

        logger.error("add_episode failed after all retries", exc_info=last_exc)
        raise last_exc

    async def search(
        self,
        query: str,
        num_results: int = _DEFAULT_SEARCH_LIMIT,
    ) -> list[dict[str, Any]]:
        """Hybrid search (semantic + BM25) over the knowledge graph."""
        self._ensure_connected()

        results = await self._graphiti.search(
            query=query,
            group_ids=[self.group_id],
            num_results=num_results,
        )

        formatted = []
        for edge in results or []:
            source_name = None
            target_name = None
            if hasattr(edge, "source_node") and edge.source_node:
                source_name = getattr(edge.source_node, "name", None)
            if hasattr(edge, "target_node") and edge.target_node:
                target_name = getattr(edge.target_node, "name", None)
            formatted.append({
                "fact": getattr(edge, "fact", str(edge)),
                "source_entity": source_name,
                "target_entity": target_name,
                "relationship": getattr(edge, "name", None),
                "uuid": str(getattr(edge, "uuid", "")),
                "created_at": str(getattr(edge, "created_at", "")),
                "valid_at": str(getattr(edge, "valid_at", "") or ""),
                "invalid_at": str(getattr(edge, "invalid_at", "") or ""),
            })
        return formatted

    async def execute_cypher(
        self,
        query: str,
        params: dict[str, Any] | None = None,
    ) -> list[dict[str, Any]]:
        """Execute raw Cypher via the Kuzu driver."""
        self._ensure_connected()

        driver = self._graphiti.driver
        try:
            # execute_query(cypher_query_, **kwargs) → (list[dict] | list[list[dict]], None, None)
            result_tuple = await driver.execute_query(query, **(params or {}))
            rows = result_tuple[0] if isinstance(result_tuple, tuple) else result_tuple
            if rows is None:
                return []
            # rows is list[dict] or list[list[dict]] (multiple result sets)
            formatted: list[dict[str, Any]] = []
            for row in rows:
                if isinstance(row, dict):
                    formatted.append(row)
                elif isinstance(row, list):
                    formatted.extend(r for r in row if isinstance(r, dict))
                else:
                    formatted.append({"result": str(row)})
            return formatted
        except Exception as e:
            logger.error(f"Cypher query failed: {e}", exc_info=True)
            raise

    async def query_entities(
        self,
        entity_type: str,
        limit: int = 100,
        offset: int = 0,
    ) -> dict[str, Any]:
        """List entities of a given type via Cypher."""
        self._ensure_connected()

        # Kuzu: list_contains checks if the labels array includes the entity type
        cypher = (
            "MATCH (n:Entity) "
            "WHERE n.group_id = $group_id AND list_contains(n.labels, $etype) "
            "RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, "
            "n.labels AS labels "
            f"SKIP {int(offset)} LIMIT {min(int(limit), 1000)}"
        )
        try:
            rows = await self.execute_cypher(cypher, {
                "group_id": self.group_id,
                "etype": entity_type,
            })
            return {"results": rows, "count": len(rows), "offset": offset, "limit": limit}
        except Exception as e:
            logger.warning(f"query_entities Cypher failed, returning empty: {e}")
            return {"results": [], "count": 0, "offset": offset, "limit": limit}

    async def get_entity(self, name: str) -> dict[str, Any] | None:
        """Retrieve entity by name via Cypher."""
        self._ensure_connected()

        cypher = (
            "MATCH (n:Entity {name: $name, group_id: $group_id}) "
            "RETURN n.uuid AS uuid, n.name AS name, n.summary AS summary, "
            "n.labels AS labels "
            "LIMIT 1"
        )
        try:
            rows = await self.execute_cypher(cypher, {
                "name": name,
                "group_id": self.group_id,
            })
            return rows[0] if rows else None
        except Exception as e:
            logger.warning(f"get_entity Cypher failed: {e}")
            return None

    async def traverse_graph(
        self,
        start_name: str,
        max_depth: int = 2,
    ) -> list[dict[str, Any]]:
        """Traverse entity graph from a starting entity name."""
        self._ensure_connected()

        if max_depth < 1 or max_depth > 5:
            raise ValueError(f"max_depth must be 1-5, got {max_depth}")

        cypher = (
            f"MATCH (s:Entity {{name: $start, group_id: $group_id}})"
            f"-[*1..{max_depth}]-(n:Entity) "
            "WHERE n.group_id = $group_id "
            "RETURN DISTINCT n.uuid AS uuid, n.name AS name, "
            "n.summary AS summary, n.labels AS labels "
            "LIMIT 100"
        )
        try:
            return await self.execute_cypher(cypher, {
                "start": start_name,
                "group_id": self.group_id,
            })
        except Exception as e:
            logger.warning(f"traverse_graph Cypher failed: {e}")
            return []

    def list_types(self) -> list[dict[str, Any]]:
        """Return the 4 hardcoded entity types with field descriptions."""
        from .entities import ENTITY_TYPES

        types = []
        for name, model in ENTITY_TYPES.items():
            fields = []
            for field_name, field_info in model.model_fields.items():
                fields.append({
                    "name": field_name,
                    "type": "string",
                    "required": False,
                    "description": str(field_info.description) if field_info.description else None,
                })
            types.append({
                "name": name,
                "description": (
                    f"{name} entity — auto-extracted by LLM from episodes. "
                    "Use brain_add_episode to contribute knowledge."
                ),
                "fields": fields,
                "entity_count": -1,
            })
        return types

    async def close(self) -> None:
        """Shut down Graphiti cleanly."""
        if self._graphiti is not None:
            try:
                await self._graphiti.close()
            except Exception as e:
                logger.warning(f"Error closing Graphiti: {e}")
        self._connected = False
        self._graphiti = None
        self._driver = None
