"""
Brain Module — LadybugDB + Agent-Driven Knowledge Graph (v3)

Local-first embedded graph with no LLM extraction pipeline.
Agents write structured knowledge directly via MCP tools.
Schema is defined in vault/.brain/entity_types.yaml and hot-reloadable.
"""

import asyncio
import json
import logging
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional, Any

from fastapi import APIRouter, HTTPException, status

from .ladybug_service import LadybugService
from .schema import load_entity_types, save_entity_types
from .models import (
    CreateEntityRequest,
    CreateEntityResponse,
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
    """Brain module with LadybugDB embedded knowledge graph"""

    name = "brain"
    provides = ["BrainInterface"]

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path

        # Ensure required directories exist
        (vault_path / ".brain").mkdir(parents=True, exist_ok=True)

        # Lazy-loaded service
        self._service: Optional[LadybugService] = None
        self._init_lock = asyncio.Lock()
        self._queries_lock = asyncio.Lock()

    async def _ensure_service(self) -> LadybugService:
        """Lazy-initialize LadybugService using shared GraphDB from registry."""
        if self._service is None:
            async with self._init_lock:
                if self._service is None:
                    from parachute.core.interfaces import get_registry
                    graph = get_registry().get("GraphDB")
                    if graph is None:
                        raise RuntimeError(
                            "Brain: GraphDB not found in registry. "
                            "GraphService must be initialized before Brain module loads."
                        )
                    svc = LadybugService(graph=graph, vault_path=self.vault_path)
                    await svc.init_brain_schema()
                    self._service = svc
                    logger.info("Brain: LadybugService initialized via shared GraphDB")
        return self._service

    def get_router(self) -> APIRouter:
        """Return FastAPI router for Brain REST API routes."""
        router = APIRouter(tags=["brain"])

        # ── Schema types ──────────────────────────────────────────────────────

        @router.get("/types")
        async def list_schema_types():
            """List entity types with field definitions and entity counts."""
            svc = await self._ensure_service()
            return await svc.list_types_with_counts()

        @router.get("/schemas")
        async def list_schemas():
            """List entity schemas (legacy alias for /types)."""
            svc = await self._ensure_service()
            types = await svc.list_types_with_counts()
            return {"success": True, "schemas": types}

        @router.post("/types", status_code=status.HTTP_201_CREATED)
        async def create_schema_type(body: dict):
            """Create a new entity type in entity_types.yaml."""
            svc = await self._ensure_service()
            type_name = body.get("name", "")
            fields = body.get("fields", {})
            if not type_name:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="name is required",
                )
            import re
            if not re.match(r'^[A-Za-z][A-Za-z0-9_]*$', type_name):
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=f"Type name must match [A-Za-z][A-Za-z0-9_]*, got '{type_name}'",
                )
            entity_types = load_entity_types(self.vault_path)
            if type_name in entity_types:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"Type '{type_name}' already exists. Use PUT /types/{type_name} to update.",
                )
            # Normalize fields: accept either {field: {type, description}} or {field: description}
            normalized: dict[str, Any] = {}
            for fname, fdef in fields.items():
                if isinstance(fdef, dict):
                    normalized[fname] = {
                        "type": fdef.get("type", "text"),
                        "description": fdef.get("description", ""),
                    }
                else:
                    normalized[fname] = {"type": "text", "description": str(fdef)}
            entity_types[type_name] = normalized
            save_entity_types(self.vault_path, entity_types)
            try:
                added = await svc.sync_schema()
            except Exception as e:
                logger.warning(f"create_schema_type sync_schema failed: {e}")
                added = {"added": []}
            return {
                "success": True,
                "name": type_name,
                "fields_count": len(normalized),
                "columns_added": added.get("added", []),
            }

        @router.put("/types/{type_name}")
        async def update_schema_type(type_name: str, body: dict):
            """Update fields for an entity type in entity_types.yaml."""
            svc = await self._ensure_service()
            fields = body.get("fields", {})
            entity_types = load_entity_types(self.vault_path)
            if type_name not in entity_types:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Type '{type_name}' not found. Create it first with POST /types.",
                )
            existing = entity_types[type_name]
            for fname, fdef in fields.items():
                if isinstance(fdef, dict):
                    existing[fname] = {
                        "type": fdef.get("type", "text"),
                        "description": fdef.get("description", ""),
                    }
                else:
                    existing[fname] = {"type": "text", "description": str(fdef)}
            entity_types[type_name] = existing
            save_entity_types(self.vault_path, entity_types)
            try:
                added = await svc.sync_schema()
            except Exception as e:
                logger.warning(f"update_schema_type sync_schema failed: {e}")
                added = {"added": []}
            return {
                "success": True,
                "name": type_name,
                "fields_count": len(existing),
                "columns_added": added.get("added", []),
            }

        @router.delete("/types/{type_name}")
        async def delete_schema_type(type_name: str):
            """Remove entity type from entity_types.yaml (data columns preserved)."""
            entity_types = load_entity_types(self.vault_path)
            if type_name not in entity_types:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Type '{type_name}' not found.",
                )
            del entity_types[type_name]
            save_entity_types(self.vault_path, entity_types)
            return {
                "success": True,
                "name": type_name,
                "note": "Type removed from schema. Existing entities and columns are preserved.",
            }

        # ── Episodes (compat) ─────────────────────────────────────────────────

        @router.post("/episodes")
        async def add_episode(body: dict):
            """Backward-compatible episode endpoint — maps to upsert_entity."""
            svc = await self._ensure_service()
            name = body.get("name", "")
            episode_body = body.get("episode_body", "")
            source_description = body.get("source_description", "")
            if not name or not episode_body:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="name and episode_body are required",
                )
            # Extract entity_type from name if in format "Type: name"
            entity_type = "Note"
            entity_name = name
            if ": " in name:
                parts = name.split(": ", 1)
                entity_types_known = load_entity_types(self.vault_path)
                if parts[0] in entity_types_known:
                    entity_type = parts[0]
                    entity_name = parts[1]
            try:
                result = await svc.upsert_entity(
                    entity_type=entity_type,
                    name=entity_name,
                    attributes={"description": episode_body[:500]} if entity_type == "Note" else {},
                )
                return {
                    "success": True,
                    "episode_uuid": None,
                    "nodes_created": 1,
                    "edges_created": 0,
                    "entity": result,
                }
            except Exception as e:
                logger.error(f"add_episode error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        # ── Search ────────────────────────────────────────────────────────────

        @router.post("/search")
        async def search(body: dict):
            """Text search over the knowledge graph."""
            svc = await self._ensure_service()
            query = body.get("query", "")
            if not query:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="query is required")
            num_results = min(int(body.get("num_results", 20)), 50)
            entity_type = body.get("entity_type", "")
            try:
                results = await svc.search(query=query, entity_type=entity_type, num_results=num_results)
                return {"success": True, "results": results, "count": len(results)}
            except Exception as e:
                logger.error(f"search error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        # ── Cypher ───────────────────────────────────────────────────────────

        @router.post("/cypher")
        async def cypher_query(body: dict):
            """Execute raw Cypher query against LadybugDB."""
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

        @router.post("/entities", status_code=status.HTTP_201_CREATED)
        async def create_entity(request: CreateEntityRequest):
            """Create entity directly in LadybugDB."""
            svc = await self._ensure_service()
            entity_type = request.entity_type
            data = request.data
            name = data.get("name", "")
            if not name:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="data.name is required",
                )
            attributes = {k: v for k, v in data.items() if k != "name"}
            try:
                entity = await svc.upsert_entity(entity_type=entity_type, name=name, attributes=attributes)
                return {"success": True, "entity_id": name, "entity": entity}
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

        @router.get("/entities/{entity_type}")
        async def query_entities(entity_type: str, limit: int = 100, offset: int = 0, search: str = ""):
            """Query entities by type with pagination and optional text search."""
            svc = await self._ensure_service()
            try:
                result = await svc.query_entities(
                    entity_type=entity_type,
                    limit=min(limit, 1000),
                    offset=offset,
                    search=search,
                )
                return {"success": True, **result}
            except Exception as e:
                logger.error(f"query_entities error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

        @router.put("/entities/{entity_id}")
        async def update_entity(entity_id: str, request: UpdateEntityRequest):
            """Update entity fields directly."""
            svc = await self._ensure_service()
            # Get current entity type first
            existing = await svc.get_entity(entity_id)
            if existing is None:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Entity not found: {entity_id}")
            entity_type = existing.get("entity_type", "Unknown")
            try:
                entity = await svc.upsert_entity(
                    entity_type=entity_type,
                    name=entity_id,
                    attributes=request.data,
                )
                return {"success": True, "entity_id": entity_id, "entity": entity}
            except Exception as e:
                logger.error(f"update_entity error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        @router.delete("/entities/{entity_id}")
        async def delete_entity(entity_id: str):
            """Delete entity and all its relationships."""
            svc = await self._ensure_service()
            try:
                deleted = await svc.delete_entity(entity_id)
                if not deleted:
                    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Entity not found: {entity_id}")
                return {"success": True, "entity_id": entity_id}
            except HTTPException:
                raise
            except Exception as e:
                logger.error(f"delete_entity error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))

        # ── Relationships + Traversal ─────────────────────────────────────────

        @router.post("/relationships")
        async def create_relationship(request: CreateRelationshipRequest):
            """Create relationship between two entities."""
            svc = await self._ensure_service()
            try:
                result = await svc.upsert_relationship(
                    from_name=request.from_id,
                    label=request.relationship,
                    to_name=request.to_id,
                )
                return {"success": True, **result}
            except ValueError as e:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
            except Exception as e:
                logger.error(f"create_relationship error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

        @router.post("/traverse")
        async def traverse_graph(request: TraverseGraphRequest):
            """Traverse graph from starting entity."""
            svc = await self._ensure_service()
            try:
                results = await svc.traverse(
                    start_name=request.start_id,
                    max_depth=min(request.max_depth, 5),
                )
                return {"success": True, "results": results, "count": len(results)}
            except Exception as e:
                logger.error(f"traverse_graph error: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))

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
        graph = self._service.graph if self._service else None
        return {
            "module": "brain",
            "version": "3.0.0",
            "connected": graph is not None and graph._connected,
            "db_path": str(graph.db_path) if graph else "not initialized",
            "backend": "LadybugDB",
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

    async def upsert_entity(
        self,
        entity_type: str,
        name: str,
        attributes: dict[str, Any],
    ) -> dict[str, Any]:
        """Public interface for other modules to write to Brain."""
        svc = await self._ensure_service()
        return await svc.upsert_entity(entity_type=entity_type, name=name, attributes=attributes)

    async def search(self, query: str) -> list[dict[str, Any]]:
        """Search entities by query. Used by chat/daily integration."""
        svc = await self._ensure_service()
        results = await svc.search(query=query, num_results=20)
        return [
            {
                "para_id": r.get("name", ""),
                "name": r.get("name", ""),
                "type": r.get("entity_type", ""),
                "content": " | ".join(
                    f"{k}: {v}" for k, v in r.items()
                    if k not in {"name", "entity_type", "created_at", "updated_at"} and v
                ),
            }
            for r in results
        ]

    async def recall(self, query: str, num_results: int = 5) -> dict[str, Any]:
        """
        Structured context retrieval for bridge agent use.
        Returns a bundle with query + results ready for system prompt injection.
        Uses fewer results than search() to keep context window impact low.
        """
        svc = await self._ensure_service()
        results = await svc.search(query=query, num_results=num_results)
        return {
            "query": query,
            "results": [
                {
                    "name": r.get("name", ""),
                    "type": r.get("entity_type", ""),
                    "description": r.get("description") or " | ".join(
                        f"{k}: {v}" for k, v in r.items()
                        if k not in {"name", "entity_type", "created_at", "updated_at", "description"} and v
                    ),
                }
                for r in results
            ],
            "count": len(results),
        }

    # ── Legacy BrainInterface (kept for Daily/Chat compat) ────────────────────

    async def add_episode(
        self,
        name: str,
        episode_body: str,
        source_description: str,
        reference_time: datetime | None = None,
    ) -> dict[str, Any]:
        """Legacy interface — maps to upsert_entity."""
        svc = await self._ensure_service()
        entity_type = "Note"
        entity_name = name
        if ": " in name:
            parts = name.split(": ", 1)
            entity_types_known = load_entity_types(self.vault_path)
            if parts[0] in entity_types_known:
                entity_type = parts[0]
                entity_name = parts[1]
        return await svc.upsert_entity(
            entity_type=entity_type,
            name=entity_name,
            attributes={},
        )
