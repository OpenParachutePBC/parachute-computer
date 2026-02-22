"""
Brain v2 Module - TerminusDB Knowledge Graph

Provides strongly-typed, version-controlled knowledge graph with agent-native MCP tools.
"""

import asyncio
import logging
from pathlib import Path
from typing import Optional, Any

from fastapi import APIRouter, HTTPException, status
from pydantic import ValidationError

from .knowledge_graph import KnowledgeGraphService
from .schema_compiler import SchemaCompiler
from .models import (
    CreateEntityRequest,
    CreateEntityResponse,
    QueryEntitiesRequest,
    QueryEntitiesResponse,
    UpdateEntityRequest,
    DeleteEntityRequest,
    CreateRelationshipRequest,
    TraverseGraphRequest,
)

logger = logging.getLogger(__name__)


class BrainV2Module:
    """Brain v2 module with TerminusDB knowledge graph"""

    name = "brain_v2"
    provides = ["BrainV2Interface", "BrainInterface"]  # Provides both for compatibility

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path
        self.schemas_dir = vault_path / ".brain" / "schemas"

        # Ensure directories exist
        self.schemas_dir.mkdir(parents=True, exist_ok=True)
        (vault_path / ".brain" / "data").mkdir(parents=True, exist_ok=True)
        (vault_path / ".brain" / "exports").mkdir(parents=True, exist_ok=True)

        # Lazy-loaded service
        self.kg_service: Optional[KnowledgeGraphService] = None
        self.schemas: list[dict[str, Any]] = []
        self._init_lock = asyncio.Lock()  # CRITICAL: Race condition protection

    async def _ensure_kg_service(self) -> KnowledgeGraphService:
        """Lazy-load KnowledgeGraphService with race condition protection"""
        if self.kg_service is None:
            async with self._init_lock:
                if self.kg_service is None:  # Double-check pattern
                    # Compile schemas
                    compiler = SchemaCompiler()
                    self.schemas = await compiler.compile_all_schemas(self.schemas_dir)

                    # Connect to TerminusDB
                    self.kg_service = KnowledgeGraphService(self.vault_path)
                    await self.kg_service.connect(self.schemas)
                    logger.info(f"Brain v2: Loaded {len(self.schemas)} schemas")

        return self.kg_service

    def get_router(self) -> APIRouter:
        """Return FastAPI router for Brain v2 routes"""
        router = APIRouter(tags=["brain_v2"])

        @router.post("/entities", response_model=CreateEntityResponse, status_code=status.HTTP_201_CREATED)
        async def create_entity(request: CreateEntityRequest):
            """Create new entity with schema validation"""
            kg = await self._ensure_kg_service()

            try:
                entity_id = await kg.create_entity(
                    entity_type=request.entity_type,
                    data=request.data,
                    commit_msg=request.commit_msg,
                )
                return CreateEntityResponse(success=True, entity_id=entity_id)
            except ValueError as e:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
            except Exception as e:
                logger.error(f"Error creating entity: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Internal server error")

        @router.put("/entities/{entity_id}", response_model=CreateEntityResponse)
        async def update_entity(entity_id: str, request: UpdateEntityRequest):
            """Update existing entity"""
            kg = await self._ensure_kg_service()

            try:
                await kg.update_entity(entity_id=entity_id, data=request.data, commit_msg=request.commit_msg)
                return CreateEntityResponse(success=True, entity_id=entity_id)
            except ValueError as e:
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(e))
            except Exception as e:
                logger.error(f"Error updating entity: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Internal server error")

        @router.delete("/entities/{entity_id}")
        async def delete_entity(entity_id: str, request: Optional[DeleteEntityRequest] = None):
            """Delete entity and relationships"""
            kg = await self._ensure_kg_service()

            try:
                commit_msg = request.commit_msg if request else None
                await kg.delete_entity(entity_id=entity_id, commit_msg=commit_msg)
                return {"success": True, "entity_id": entity_id}
            except ValueError as e:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(e))
            except Exception as e:
                logger.error(f"Error deleting entity: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Internal server error")

        @router.get("/entities/by_id")
        async def get_entity_by_id(id: str):
            """Get a single entity by IRI"""
            kg = await self._ensure_kg_service()

            try:
                entity = await kg.get_entity(entity_id=id)
                if entity is None:
                    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"Entity not found: {id}")
                return entity
            except HTTPException:
                raise
            except Exception as e:
                logger.error(f"Error fetching entity: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Internal server error")

        @router.get("/entities/{entity_type}", response_model=QueryEntitiesResponse)
        async def query_entities(
            entity_type: str,
            limit: int = 100,
            offset: int = 0,
        ):
            """Query entities by type with pagination"""
            kg = await self._ensure_kg_service()

            try:
                results = await kg.query_entities(
                    entity_type=entity_type,
                    limit=min(limit, 1000),  # PERFORMANCE: Cap at 1000
                    offset=offset,
                )
                return QueryEntitiesResponse(success=True, **results)
            except Exception as e:
                logger.error(f"Error querying entities: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Failed to query entities")

        @router.post("/relationships")
        async def create_relationship(request: CreateRelationshipRequest):
            """Create relationship between entities"""
            kg = await self._ensure_kg_service()

            try:
                await kg.create_relationship(
                    from_id=request.from_id,
                    relationship=request.relationship,
                    to_id=request.to_id,
                )
                return {"success": True}
            except Exception as e:
                logger.error(f"Error creating relationship: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Failed to create relationship")

        @router.post("/traverse")
        async def traverse_graph(request: TraverseGraphRequest):
            """Traverse graph from starting entity"""
            kg = await self._ensure_kg_service()

            try:
                results = await kg.traverse_graph(
                    start_id=request.start_id,
                    relationship=request.relationship,
                    max_depth=min(request.max_depth, 5),  # PERFORMANCE: Cap depth
                )
                return {"success": True, "results": results, "count": len(results)}
            except Exception as e:
                logger.error(f"Error traversing graph: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Failed to traverse graph")

        @router.get("/schemas")
        async def list_schemas():
            """List all available entity schemas"""
            kg = await self._ensure_kg_service()
            try:
                schemas = await kg.list_schemas()
                return {"success": True, "schemas": schemas}
            except Exception as e:
                logger.error(f"Error listing schemas: {e}", exc_info=True)
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Internal server error")

        return router

    def get_status(self) -> dict:
        """Get module status for /api/modules listing"""
        return {
            "module": "brain_v2",
            "connected": self.kg_service is not None and self.kg_service._connected,
            "schemas_loaded": len(self.schemas),
            "schemas_dir": str(self.schemas_dir),
        }

    def get_mcp_tools(self) -> list[dict]:
        """Return MCP tools for agent-native access to Brain v2"""
        from .mcp_tools import BRAIN_V2_TOOLS, TOOL_HANDLERS

        # Bind handlers to this module instance
        tools = []
        for tool_def in BRAIN_V2_TOOLS:
            tool = tool_def.copy()
            tool_name = tool["name"]
            if tool_name in TOOL_HANDLERS:
                # Create bound handler with module context
                handler = TOOL_HANDLERS[tool_name]
                tool["handler"] = lambda args, h=handler: h(self, args)
            tools.append(tool)

        return tools

    # --- BrainInterface compatibility methods ---

    async def search(self, query: str) -> list[dict[str, Any]]:
        """Search entities by name or content (BrainInterface compatibility).

        Provides full-text search across all entity types for chat/daily integration.
        Returns results in BrainInterface format for backwards compatibility.
        """
        kg = await self._ensure_kg_service()

        results = []
        query_lower = query.lower()

        # Search across all entity types
        # PERFORMANCE: Execute queries in parallel (not sequential)
        # Phase 2 will replace with proper WOQL full-text search
        tasks = []
        for schema in self.schemas:
            entity_type = schema.get("@id", "")
            if entity_type:
                tasks.append(kg.query_entities(entity_type, limit=100))

        # Execute all queries in parallel
        responses = await asyncio.gather(*tasks, return_exceptions=True)

        # Process results from all entity types
        for response in responses:
            if isinstance(response, Exception):
                logger.warning(f"Search query failed: {response}")
                continue

            for entity in response.get("results", []):
                    # Check if query matches any field
                    entity_id = entity.get("@id", "")
                    entity_type_name = entity.get("@type", "")

                    # Simple substring search across all string fields
                    matched = False
                    if query_lower in entity_id.lower():
                        matched = True
                    else:
                        for key, value in entity.items():
                            if key.startswith("@"):
                                continue
                            if isinstance(value, str) and query_lower in value.lower():
                                matched = True
                                break
                            elif isinstance(value, list):
                                for item in value:
                                    if isinstance(item, str) and query_lower in item.lower():
                                        matched = True
                                        break

                    if matched:
                        # Format as BrainInterface expects
                        results.append({
                            "para_id": entity_id,  # Use TerminusDB IRI as para_id
                            "name": entity.get("name", entity.get("title", entity_id)),
                            "type": entity_type_name,
                            "tags": entity.get("tags", []),
                            "content": str(entity),  # Full entity as JSON string
                        })

        return results[:20]  # Limit to top 20 results
