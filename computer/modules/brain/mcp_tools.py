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
        "description": "List all available entity schemas. Returns normalized schema definitions with field types and descriptions.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "brain_list_types",
        "description": "List all schema types with field definitions and entity counts. Preferred over brain_list_schemas for newer workflows.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "brain_create_type",
        "description": "Create a new schema type (TerminusDB Class) with field definitions. Returns success status.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "PascalCase type name (e.g. 'Project', 'Person'). Must not be a reserved TerminusDB name.",
                },
                "fields": {
                    "type": "object",
                    "description": "Field definitions keyed by snake_case field name",
                    "additionalProperties": {
                        "type": "object",
                        "properties": {
                            "type": {
                                "type": "string",
                                "enum": ["string", "integer", "boolean", "datetime", "enum", "link"],
                            },
                            "required": {"type": "boolean"},
                            "values": {
                                "type": "array",
                                "items": {"type": "string"},
                                "description": "Allowed values for enum fields",
                            },
                            "link_type": {
                                "type": "string",
                                "description": "Target type name for link fields (e.g. 'Person')",
                            },
                            "description": {"type": "string"},
                        },
                        "required": ["type"],
                    },
                },
                "key_strategy": {
                    "type": "string",
                    "enum": ["Random", "Lexical", "Hash", "ValueHash"],
                    "description": "Key generation strategy (default: Random)",
                },
                "description": {
                    "type": "string",
                    "description": "Optional description for this type",
                },
            },
            "required": ["name", "fields"],
        },
    },
    {
        "name": "brain_update_type",
        "description": "Update an existing schema type's fields (full field replacement). Additive changes (new fields) are safe. Making a field required when data exists may fail.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Type name to update",
                },
                "fields": {
                    "type": "object",
                    "description": "New field definitions (replaces all existing fields)",
                    "additionalProperties": {
                        "type": "object",
                        "properties": {
                            "type": {
                                "type": "string",
                                "enum": ["string", "integer", "boolean", "datetime", "enum", "link"],
                            },
                            "required": {"type": "boolean"},
                            "values": {"type": "array", "items": {"type": "string"}},
                            "link_type": {"type": "string"},
                        },
                        "required": ["type"],
                    },
                },
            },
            "required": ["name", "fields"],
        },
    },
    {
        "name": "brain_delete_type",
        "description": "Delete a schema type. Blocked with an error if entities of this type exist — delete all entities first.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Type name to delete",
                },
            },
            "required": ["name"],
        },
    },
    {
        "name": "brain_list_saved_queries",
        "description": "List all saved filter queries for the Brain module.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "brain_save_query",
        "description": "Save a named filter query for later reuse.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Human-readable name for this saved query",
                },
                "entity_type": {
                    "type": "string",
                    "description": "The entity type this query applies to",
                },
                "filters": {
                    "type": "array",
                    "description": "List of filter conditions",
                    "items": {
                        "type": "object",
                        "properties": {
                            "field_name": {"type": "string"},
                            "operator": {"type": "string", "enum": ["eq", "neq", "contains"]},
                            "value": {},
                        },
                        "required": ["field_name", "operator", "value"],
                    },
                },
            },
            "required": ["name", "entity_type", "filters"],
        },
    },
    {
        "name": "brain_delete_saved_query",
        "description": "Delete a saved query by its ID.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query_id": {
                    "type": "string",
                    "description": "UUID of the saved query to delete",
                },
            },
            "required": ["query_id"],
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
    """Handle brain_list_schemas tool call — returns normalized schema format."""
    await module._ensure_kg_service()

    try:
        schemas = module._format_schemas_for_api()
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


async def handle_list_types(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_list_types tool call."""
    kg = await module._ensure_kg_service()

    try:
        types = await kg.list_schema_types_with_counts()
        return {
            "success": True,
            "types": types,
            "count": len(types),
        }
    except Exception as e:
        logger.error(f"Failed to list types: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_create_type(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_create_type tool call."""
    kg = await module._ensure_kg_service()

    name = arguments["name"]
    fields = arguments["fields"]
    key_strategy = arguments.get("key_strategy", "Random")
    description = arguments.get("description")

    try:
        await kg.create_schema_type(
            name=name,
            fields=fields,
            key_strategy=key_strategy,
            description=description,
        )
        await module._reload_schemas()
        return {"success": True, "name": name, "message": f"Created type '{name}'"}
    except ValueError as e:
        return {"success": False, "error": str(e)}
    except Exception as e:
        logger.error(f"Failed to create type: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_update_type(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_update_type tool call."""
    kg = await module._ensure_kg_service()

    name = arguments["name"]
    fields = arguments["fields"]

    try:
        await kg.update_schema_type(name=name, fields=fields)
        await module._reload_schemas()
        return {"success": True, "name": name, "message": f"Updated type '{name}'"}
    except ValueError as e:
        return {"success": False, "error": str(e)}
    except Exception as e:
        logger.error(f"Failed to update type: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_delete_type(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_delete_type tool call."""
    import json
    kg = await module._ensure_kg_service()

    name = arguments["name"]

    try:
        count = await kg.count_entities(name)
        if count > 0:
            return {
                "success": False,
                "error": f"Type '{name}' has {count} entities. Delete all entities first.",
            }
        await kg.delete_schema_type(name)
        await module._reload_schemas()
        return {"success": True, "message": f"Deleted type '{name}'"}
    except Exception as e:
        logger.error(f"Failed to delete type: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_list_saved_queries(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_list_saved_queries tool call."""
    import json
    queries_path = module.vault_path / ".brain" / "queries.json"

    try:
        if queries_path.exists():
            data = json.loads(queries_path.read_text())
            queries = data.get("queries", [])
        else:
            queries = []
        return {"success": True, "queries": queries, "count": len(queries)}
    except Exception as e:
        logger.error(f"Failed to list saved queries: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_save_query(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_save_query tool call."""
    import json, uuid as uuid_mod
    queries_path = module.vault_path / ".brain" / "queries.json"
    queries_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        data = json.loads(queries_path.read_text()) if queries_path.exists() else {"queries": []}
        query_id = str(uuid_mod.uuid4())
        data["queries"].append({
            "id": query_id,
            "name": arguments["name"],
            "entity_type": arguments["entity_type"],
            "filters": arguments["filters"],
        })
        queries_path.write_text(json.dumps(data, indent=2))
        return {"success": True, "id": query_id, "message": f"Saved query '{arguments['name']}'"}
    except Exception as e:
        logger.error(f"Failed to save query: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_delete_saved_query(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Handle brain_delete_saved_query tool call."""
    import json
    query_id = arguments["query_id"]
    queries_path = module.vault_path / ".brain" / "queries.json"

    try:
        if not queries_path.exists():
            return {"success": False, "error": "No saved queries found"}
        data = json.loads(queries_path.read_text())
        original_count = len(data.get("queries", []))
        data["queries"] = [q for q in data.get("queries", []) if q.get("id") != query_id]
        if len(data["queries"]) == original_count:
            return {"success": False, "error": f"Query '{query_id}' not found"}
        queries_path.write_text(json.dumps(data, indent=2))
        return {"success": True, "message": f"Deleted query '{query_id}'"}
    except Exception as e:
        logger.error(f"Failed to delete saved query: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


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
    "brain_list_types": handle_list_types,
    "brain_create_type": handle_create_type,
    "brain_update_type": handle_update_type,
    "brain_delete_type": handle_delete_type,
    "brain_list_saved_queries": handle_list_saved_queries,
    "brain_save_query": handle_save_query,
    "brain_delete_saved_query": handle_delete_saved_query,
}
