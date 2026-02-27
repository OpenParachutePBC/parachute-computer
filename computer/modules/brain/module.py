"""
Brain Module - Graphiti + Kuzu Knowledge Graph

Provides a personal knowledge graph with LLM entity extraction, deduplication,
contradiction detection, and hybrid search. Agent-native via MCP tools.
"""

import asyncio
import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Any

from fastapi import APIRouter, HTTPException, status

from .graphiti_service import GraphitiService
from .models import (
    CreateEntityRequest,
    CreateEntityResponse,
    QueryEntitiesRequest,
    QueryEntitiesResponse,
    UpdateEntityRequest,
    DeleteEntityRequest,
    CreateRelationshipRequest,
    TraverseGraphRequest,
    SavedQueryModel,
    SavedQueryListResponse,
)

logger = logging.getLogger(__name__)


class BrainModule:
    """Brain module with Graphiti + Kuzu knowledge graph"""

    name = "brain"
    provides = ["BrainInterface"]

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path
        self.kuzu_path = vault_path / ".brain" / "kuzu"

        # Ensure required directories exist
        self.kuzu_path.mkdir(parents=True, exist_ok=True)
        (vault_path / ".brain").mkdir(parents=True, exist_ok=True)

        # Lazy-loaded service
        self._service: Optional[GraphitiService] = None
        self._init_lock = asyncio.Lock()
        self._queries_lock = asyncio.Lock()

    def _load_brain_api_keys(self) -> tuple[Optional[str], Optional[str]]:
        """Load Brain API keys from vault config.yaml under brain: namespace.

        Keys are stored in vault/.parachute/config.yaml:
            brain:
              anthropic_api_key: sk-ant-api03-...
              google_api_key: AIza...

        Deliberately does NOT fall back to ANTHROPIC_API_KEY env var to prevent
        the key from leaking into Claude CLI subprocesses (which inherit the full
        process environment) and accidentally billing API instead of Max subscription.
        """
        import yaml
        config_file = self.vault_path / ".parachute" / "config.yaml"
        if not config_file.exists():
            return None, None
        try:
            data = yaml.safe_load(config_file.read_text()) or {}
            brain_cfg = data.get("brain", {}) if isinstance(data, dict) else {}
            return brain_cfg.get("anthropic_api_key"), brain_cfg.get("google_api_key")
        except Exception as e:
            logger.warning(f"Brain: could not load config.yaml: {e}")
            return None, None

    async def _ensure_service(self) -> GraphitiService:
        """Lazy-initialize GraphitiService with race condition protection."""
        if self._service is None:
            async with self._init_lock:
                if self._service is None:
                    anthropic_key, google_key = self._load_brain_api_keys()
                    svc = GraphitiService(
                        kuzu_path=self.kuzu_path,
                        anthropic_api_key=anthropic_key,
                        google_api_key=google_key,
                    )
                    await svc.connect()
                    self._service = svc
                    logger.info("Brain: GraphitiService initialized")
        return self._service

    def get_router(self) -> APIRouter:
        """Return FastAPI router for Brain REST API routes."""
        router = APIRouter(tags=["brain"])

        # ── Episodes (new primary API) ────────────────────────────────────────

        @router.post("/episodes")
        async def add_episode(body: dict):
            """Ingest text as an episode. LLM extracts entities automatically."""
            svc = await self._ensure_service()
            name = body.get("name", "")
            episode_body = body.get("episode_body", "")
            source_description = body.get("source_description", "")
            if not name or not episode_body or not source_description:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="name, episode_body, and source_description are required",
                )
            ref_time = None
            if "reference_time" in body:
                try:
                    ref_time = datetime.fromisoformat(body["reference_time"])
                except ValueError:
                    pass
            try:
                return await svc.add_episode(
                    name=name,
                    episode_body=episode_body,
                    source_description=source_description,
                    reference_time=ref_time,
                )
            except ValueError as e:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
            except Exception as e:
                logger.error(f"add_episode error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        # ── Search ────────────────────────────────────────────────────────────

        @router.post("/search")
        async def search(body: dict):
            """Hybrid search over the knowledge graph."""
            svc = await self._ensure_service()
            query = body.get("query", "")
            if not query:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="query is required")
            num_results = min(int(body.get("num_results", 10)), 50)
            try:
                results = await svc.search(query=query, num_results=num_results)
                return {"success": True, "results": results, "count": len(results)}
            except Exception as e:
                logger.error(f"search error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        # ── Cypher ───────────────────────────────────────────────────────────

        @router.post("/cypher")
        async def cypher_query(body: dict):
            """Execute raw Cypher query."""
            svc = await self._ensure_service()
            query = body.get("query", "")
            if not query:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="query is required")
            try:
                results = await svc.execute_cypher(query=query, params=body.get("params"))
                return {"success": True, "results": results, "count": len(results)}
            except Exception as e:
                logger.error(f"cypher error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        # ── Entities ──────────────────────────────────────────────────────────

        @router.post("/entities", response_model=CreateEntityResponse, status_code=status.HTTP_201_CREATED)
        async def create_entity(request: CreateEntityRequest):
            """Create entity via synthetic episode."""
            svc = await self._ensure_service()
            entity_type = request.entity_type
            data = request.data
            name = data.get("name", "Unknown")
            fields_text = ". ".join(f"{k}: {v}" for k, v in data.items() if k != "name" and v)
            episode_body = f"New {entity_type}: {name}."
            if fields_text:
                episode_body += f" {fields_text}."
            try:
                await svc.add_episode(
                    name=f"Create {entity_type}: {name}",
                    episode_body=episode_body,
                    source_description="Manual entity creation",
                )
                return CreateEntityResponse(success=True, entity_id=name)
            except Exception as e:
                logger.error(f"create_entity error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        @router.get("/entities/by_id")
        async def get_entity_by_id(id: str):
            """Get entity by name."""
            svc = await self._ensure_service()
            try:
                entity = await svc.get_entity(id)
                if entity is None:
                    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Entity not found: {id}")
                return entity
            except HTTPException:
                raise
            except Exception as e:
                logger.error(f"get_entity error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        @router.get("/entities/{entity_type}", response_model=QueryEntitiesResponse)
        async def query_entities(entity_type: str, limit: int = 100, offset: int = 0):
            """Query entities by type with pagination."""
            svc = await self._ensure_service()
            try:
                result = await svc.query_entities(
                    entity_type=entity_type,
                    limit=min(limit, 1000),
                    offset=offset,
                )
                return QueryEntitiesResponse(success=True, **result)
            except Exception as e:
                logger.error(f"query_entities error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

        @router.put("/entities/{entity_id}", response_model=CreateEntityResponse)
        async def update_entity(entity_id: str, request: UpdateEntityRequest):
            """Update entity via episode."""
            svc = await self._ensure_service()
            fields_text = ". ".join(f"{k} is now {v}" for k, v in request.data.items() if v)
            episode_body = f"Update for {entity_id}: {fields_text}." if fields_text else f"{entity_id} updated."
            try:
                await svc.add_episode(
                    name=f"Update: {entity_id}",
                    episode_body=episode_body,
                    source_description="Manual entity update",
                )
                return CreateEntityResponse(success=True, entity_id=entity_id)
            except Exception as e:
                logger.error(f"update_entity error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        @router.delete("/entities/{entity_id}")
        async def delete_entity(entity_id: str, request: Optional[DeleteEntityRequest] = None):
            """Logically delete entity via episode."""
            svc = await self._ensure_service()
            try:
                await svc.add_episode(
                    name=f"Delete: {entity_id}",
                    episode_body=f"Aaron no longer tracks entity: {entity_id}.",
                    source_description="Logical entity deletion",
                )
                return {"success": True, "entity_id": entity_id}
            except Exception as e:
                logger.error(f"delete_entity error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        # ── Relationships + Traversal ─────────────────────────────────────────

        @router.post("/relationships")
        async def create_relationship(request: CreateRelationshipRequest):
            """Create relationship via episode."""
            svc = await self._ensure_service()
            episode_body = f"{request.from_id} {request.relationship} {request.to_id}."
            try:
                await svc.add_episode(
                    name=f"Relationship: {request.from_id} → {request.to_id}",
                    episode_body=episode_body,
                    source_description="Manual relationship creation",
                )
                return {"success": True}
            except Exception as e:
                logger.error(f"create_relationship error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

        @router.post("/traverse")
        async def traverse_graph(request: TraverseGraphRequest):
            """Traverse graph from starting entity."""
            svc = await self._ensure_service()
            try:
                results = await svc.traverse_graph(
                    start_name=request.start_id,
                    max_depth=min(request.max_depth, 5),
                )
                return {"success": True, "results": results, "count": len(results)}
            except Exception as e:
                logger.error(f"traverse_graph error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

        # ── Schema types (legacy — returns info for compatibility) ────────────

        @router.get("/schemas")
        async def list_schemas():
            """List entity schemas (Graphiti types)."""
            await self._ensure_service()
            types = self._service.list_types()
            return {"success": True, "schemas": types}

        @router.get("/types")
        async def list_schema_types():
            """List entity types with field definitions."""
            await self._ensure_service()
            return self._service.list_types()

        @router.post("/types")
        async def create_schema_type(body: dict):
            """Not supported — schema is defined in code."""
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=(
                    "Schema types are defined in code with the Graphiti backend. "
                    "Entity types: Person, Project, Area, Topic. "
                    "Use POST /episodes to contribute knowledge."
                ),
            )

        @router.put("/types/{type_name}")
        async def update_schema_type(type_name: str, body: dict):
            """Not supported — schema is defined in code."""
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Schema types are defined in code with the Graphiti backend.",
            )

        @router.delete("/types/{type_name}")
        async def delete_schema_type(type_name: str):
            """Not supported — schema is defined in code."""
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Schema types are defined in code with the Graphiti backend.",
            )

        # ── Saved queries ─────────────────────────────────────────────────────

        @router.get("/queries", response_model=SavedQueryListResponse)
        async def list_saved_queries():
            queries_path = self.vault_path / ".brain" / "queries.json"
            async with self._queries_lock:
                if queries_path.exists():
                    text = await asyncio.to_thread(queries_path.read_text)
                    data = json.loads(text)
                    return SavedQueryListResponse(queries=data.get("queries", []))
            return SavedQueryListResponse(queries=[])

        @router.post("/queries")
        async def save_query(request: SavedQueryModel):
            queries_path = self.vault_path / ".brain" / "queries.json"
            queries_path.parent.mkdir(parents=True, exist_ok=True)
            async with self._queries_lock:
                if queries_path.exists():
                    text = await asyncio.to_thread(queries_path.read_text)
                    data = json.loads(text)
                else:
                    data = {"queries": []}
                entry = request.model_dump()
                entry["id"] = entry.get("id") or str(uuid.uuid4())
                data["queries"].append(entry)
                await asyncio.to_thread(queries_path.write_text, json.dumps(data, indent=2))
            return {"success": True, "id": entry["id"]}

        @router.delete("/queries/{query_id}")
        async def delete_saved_query(query_id: str):
            queries_path = self.vault_path / ".brain" / "queries.json"
            async with self._queries_lock:
                if not queries_path.exists():
                    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Query not found")
                text = await asyncio.to_thread(queries_path.read_text)
                data = json.loads(text)
                original = len(data.get("queries", []))
                data["queries"] = [q for q in data.get("queries", []) if q.get("id") != query_id]
                if len(data["queries"]) == original:
                    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Query not found")
                await asyncio.to_thread(queries_path.write_text, json.dumps(data, indent=2))
            return {"success": True}

        return router

    def get_status(self) -> dict:
        """Get module status for /api/modules listing."""
        return {
            "module": "brain",
            "connected": self._service is not None and self._service._connected,
            "kuzu_path": str(self.kuzu_path),
            "group_id": self._service.group_id if self._service else "user-default",
        }

    def get_mcp_tools(self) -> list[dict]:
        """Return MCP tools for agent-native access."""
        from .mcp_tools import BRAIN_TOOLS, TOOL_HANDLERS

        tools = []
        for tool_def in BRAIN_TOOLS:
            tool = tool_def.copy()
            tool_name = tool["name"]
            if tool_name in TOOL_HANDLERS:
                handler = TOOL_HANDLERS[tool_name]
                tool["handler"] = lambda args, h=handler: h(self, args)
            tools.append(tool)
        return tools

    # ── BrainInterface methods ────────────────────────────────────────────────

    async def add_episode(
        self,
        name: str,
        episode_body: str,
        source_description: str,
        reference_time: datetime | None = None,
    ) -> dict[str, Any]:
        """Public interface for Daily and Chat modules to add episodes."""
        svc = await self._ensure_service()
        return await svc.add_episode(
            name=name,
            episode_body=episode_body,
            source_description=source_description,
            reference_time=reference_time,
        )

    async def search(self, query: str) -> list[dict[str, Any]]:
        """Search entities by query. Used by chat/daily integration."""
        svc = await self._ensure_service()
        results = await svc.search(query=query, num_results=20)
        # Format for BrainInterface consumers
        return [
            {
                "para_id": r.get("uuid", ""),
                "name": r.get("source_entity") or r.get("fact", "")[:50],
                "type": "EntityEdge",
                "content": r.get("fact", ""),
            }
            for r in results
        ]
