"""
Brain MCP Tools

Provides agent-native access to the knowledge graph via MCP tools.
All 7 CRUD operations exposed for full agent autonomy.
"""

import logging
from typing import Any

logger = logging.getLogger(__name__)


# MCP Tool Definitions for Brain
BRAIN_TOOLS = [
    {
        "name": "brain_create_entity",
        "description": "Create a new entity in the knowledge graph with schema validation. Returns the entity IRI.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_type": {
                    "type": "string",
                    "description": "Entity type matching schema name (e.g., 'Person', 'Project', 'Note')",
                },
                "data": {
                    "type": "object",
                    "description": "Entity fields as key-value pairs",
                },
                "commit_msg": {
                    "type": "string",
                    "description": "Optional commit message for version history",
                },
            },
            "required": ["entity_type", "data"],
        },
    },
    {
        "name": "brain_query_entities",
        "description": "Query entities by type with optional filtering and pagination. Returns list of matching entities.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_type": {
                    "type": "string",
                    "description": "Entity type to query (e.g., 'Person', 'Project')",
                },
                "filters": {
                    "type": "object",
                    "description": "Optional field filters as key-value pairs",
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum results to return (1-1000, default 100)",
                    "minimum": 1,
                    "maximum": 1000,
                },
                "offset": {
                    "type": "integer",
                    "description": "Number of results to skip (for pagination)",
                    "minimum": 0,
                },
            },
            "required": ["entity_type"],
        },
    },
    {
        "name": "brain_get_entity",
        "description": "Retrieve a specific entity by its IRI. Returns the complete entity with all fields.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_id": {
                    "type": "string",
                    "description": "Entity IRI (e.g., 'Person/john_doe')",
                },
            },
            "required": ["entity_id"],
        },
    },
    {
        "name": "brain_update_entity",
        "description": "Update an existing entity's fields. Performs partial update (only specified fields changed).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_id": {
                    "type": "string",
                    "description": "Entity IRI to update",
                },
                "data": {
                    "type": "object",
                    "description": "Fields to update as key-value pairs",
                },
                "commit_msg": {
                    "type": "string",
                    "description": "Optional commit message for version history",
                },
            },
            "required": ["entity_id", "data"],
        },
    },
    {
        "name": "brain_delete_entity",
        "description": "Delete an entity from the knowledge graph. Removes all relationships to/from this entity.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_id": {
                    "type": "string",
                    "description": "Entity IRI to delete",
                },
                "commit_msg": {
                    "type": "string",
                    "description": "Optional commit message for version history",
                },
            },
            "required": ["entity_id"],
        },
    },
    {
        "name": "brain_create_relationship",
        "description": "Create a relationship between two entities. Links source entity to target via named relationship.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "from_id": {
                    "type": "string",
                    "description": "Source entity IRI",
                },
                "relationship": {
                    "type": "string",
                    "description": "Relationship name (must match schema field)",
                },
                "to_id": {
                    "type": "string",
                    "description": "Target entity IRI",
                },
            },
            "required": ["from_id", "relationship", "to_id"],
        },
    },
    {
        "name": "brain_traverse_graph",
        "description": "Traverse the knowledge graph from a starting entity following relationships. Returns connected entities up to max_depth hops.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "start_id": {
                    "type": "string",
                    "description": "Starting entity IRI",
                },
                "relationship": {
                    "type": "string",
                    "description": "Relationship name to follow",
                },
                "max_depth": {
                    "type": "integer",
                    "description": "Maximum traversal depth (1-5, default 2)",
                    "minimum": 1,
                    "maximum": 5,
                },
            },
            "required": ["start_id", "relationship"],
        },
    },
    {
        "name": "brain_list_schemas",
        "description": "List all available entity schemas. Returns schema definitions with field types and descriptions.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
]


# Tool handler implementations
async def handle_create_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_create_entity tool call"""
    kg = await module._ensure_kg_service()

    entity_type = arguments["entity_type"]
    data = arguments["data"]
    commit_msg = arguments.get("commit_msg")

    try:
        entity_id = await kg.create_entity(
            entity_type=entity_type,
            data=data,
            commit_msg=commit_msg,
        )
        return {
            "success": True,
            "entity_id": entity_id,
            "message": f"Created {entity_type} entity: {entity_id}",
        }
    except Exception as e:
        logger.error(f"Failed to create entity: {e}", exc_info=True)
        return {
            "success": False,
            "error": str(e),
        }


async def handle_query_entities(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_query_entities tool call"""
    kg = await module._ensure_kg_service()

    entity_type = arguments["entity_type"]
    filters = arguments.get("filters")
    limit = arguments.get("limit", 100)
    offset = arguments.get("offset", 0)

    try:
        results = await kg.query_entities(
            entity_type=entity_type,
            filters=filters,
            limit=min(limit, 1000),
            offset=offset,
        )
        return {
            "success": True,
            **results,
        }
    except Exception as e:
        logger.error(f"Failed to query entities: {e}", exc_info=True)
        return {
            "success": False,
            "error": str(e),
        }


async def handle_get_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_get_entity tool call"""
    kg = await module._ensure_kg_service()

    entity_id = arguments["entity_id"]

    try:
        entity = await kg.get_entity(entity_id)
        if entity is None:
            return {
                "success": False,
                "error": f"Entity not found: {entity_id}",
            }
        return {
            "success": True,
            "entity": entity,
        }
    except Exception as e:
        logger.error(f"Failed to get entity: {e}", exc_info=True)
        return {
            "success": False,
            "error": str(e),
        }


async def handle_update_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_update_entity tool call"""
    kg = await module._ensure_kg_service()

    entity_id = arguments["entity_id"]
    data = arguments["data"]
    commit_msg = arguments.get("commit_msg")

    try:
        await kg.update_entity(
            entity_id=entity_id,
            data=data,
            commit_msg=commit_msg,
        )
        return {
            "success": True,
            "entity_id": entity_id,
            "message": f"Updated entity: {entity_id}",
        }
    except Exception as e:
        logger.error(f"Failed to update entity: {e}", exc_info=True)
        return {
            "success": False,
            "error": str(e),
        }


async def handle_delete_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_delete_entity tool call"""
    kg = await module._ensure_kg_service()

    entity_id = arguments["entity_id"]
    commit_msg = arguments.get("commit_msg")

    try:
        await kg.delete_entity(
            entity_id=entity_id,
            commit_msg=commit_msg,
        )
        return {
            "success": True,
            "entity_id": entity_id,
            "message": f"Deleted entity: {entity_id}",
        }
    except Exception as e:
        logger.error(f"Failed to delete entity: {e}", exc_info=True)
        return {
            "success": False,
            "error": str(e),
        }


async def handle_create_relationship(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_create_relationship tool call"""
    kg = await module._ensure_kg_service()

    from_id = arguments["from_id"]
    relationship = arguments["relationship"]
    to_id = arguments["to_id"]

    try:
        await kg.create_relationship(
            from_id=from_id,
            relationship=relationship,
            to_id=to_id,
        )
        return {
            "success": True,
            "message": f"Created relationship: {from_id} --[{relationship}]--> {to_id}",
        }
    except Exception as e:
        logger.error(f"Failed to create relationship: {e}", exc_info=True)
        return {
            "success": False,
            "error": str(e),
        }


async def handle_traverse_graph(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_traverse_graph tool call"""
    kg = await module._ensure_kg_service()

    start_id = arguments["start_id"]
    relationship = arguments["relationship"]
    max_depth = arguments.get("max_depth", 2)

    try:
        results = await kg.traverse_graph(
            start_id=start_id,
            relationship=relationship,
            max_depth=min(max_depth, 5),
        )
        return {
            "success": True,
            "results": results,
            "count": len(results),
        }
    except Exception as e:
        logger.error(f"Failed to traverse graph: {e}", exc_info=True)
        return {
            "success": False,
            "error": str(e),
        }


async def handle_list_schemas(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_list_schemas tool call"""
    kg = await module._ensure_kg_service()

    try:
        schemas = await kg.list_schemas()
        return {
            "success": True,
            "schemas": schemas,
            "count": len(schemas),
        }
    except Exception as e:
        logger.error(f"Failed to list schemas: {e}", exc_info=True)
        return {
            "success": False,
            "error": str(e),
        }


# Handler registry
TOOL_HANDLERS = {
    "brain_create_entity": handle_create_entity,
    "brain_query_entities": handle_query_entities,
    "brain_get_entity": handle_get_entity,
    "brain_update_entity": handle_update_entity,
    "brain_delete_entity": handle_delete_entity,
    "brain_create_relationship": handle_create_relationship,
    "brain_traverse_graph": handle_traverse_graph,
    "brain_list_schemas": handle_list_schemas,
}
