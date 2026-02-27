"""
Brain MCP Tools — LadybugDB v3

Agent-native access to the LadybugDB knowledge graph.
Agents write structured knowledge directly — no LLM extraction pipeline.
"""

import asyncio
import json
import logging
import uuid
from typing import Any

logger = logging.getLogger(__name__)


# ── Tool Definitions ──────────────────────────────────────────────────────────

BRAIN_TOOLS = [
    # ── Primary agent-write tools ─────────────────────────────────────────────
    {
        "name": "brain_upsert_entity",
        "description": (
            "Create or update an entity in the knowledge graph. "
            "Use any entity_type string that fits — 'person', 'project', 'event', 'book', 'idea', etc. "
            "No predefined types required. The ontology grows from what you actually write. "
            "Always include 'description' in attributes for a plain-text summary. "
            "Structured fields are available once a type is defined with brain_create_type. "
            "Merges by name — safe to call repeatedly. "
            "Example: brain_upsert_entity(entity_type='person', name='Kevin', "
            "attributes={'description': 'Co-founder at Regen Hub, co-running LVB cohort'})"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_type": {
                    "type": "string",
                    "description": "Any string label for the entity type (e.g. 'person', 'project', 'event', 'idea')",
                },
                "name": {
                    "type": "string",
                    "description": "Unique entity name (primary key)",
                },
                "attributes": {
                    "type": "object",
                    "description": (
                        "Field values as key-value pairs. 'description' is always available for unstructured notes. "
                        "Type-specific fields are available after brain_create_type. "
                        "Unknown fields are silently ignored."
                    ),
                },
            },
            "required": ["entity_type", "name"],
        },
    },
    {
        "name": "brain_search",
        "description": (
            "Text search across entity names and field values. "
            "Returns matching entities ordered by recency. "
            "Optionally filter by entity_type."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search text (case-insensitive substring match)",
                },
                "entity_type": {
                    "type": "string",
                    "description": "Optional: filter to a specific entity type",
                },
                "num_results": {
                    "type": "integer",
                    "description": "Maximum results to return (default 20, max 50)",
                    "minimum": 1,
                    "maximum": 50,
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "brain_cypher_query",
        "description": (
            "Execute a raw Cypher query against the LadybugDB graph database. "
            "For power users and debugging. Use brain_search for simple queries."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Cypher query string",
                },
                "params": {
                    "type": "object",
                    "description": "Optional query parameters",
                },
            },
            "required": ["query"],
        },
    },
    # ── Schema management ─────────────────────────────────────────────────────
    {
        "name": "brain_list_types",
        "description": "List Brain entity types with field definitions and entity counts.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "brain_create_type",
        "description": (
            "Create a new entity type in entity_types.yaml. "
            "Adds columns to the database automatically (no restart needed). "
            "Example: brain_create_type(name='Resource', fields={'url': {type: 'text'}})"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "PascalCase type name (e.g. 'Resource', 'Event')",
                },
                "fields": {
                    "type": "object",
                    "description": "Field definitions. Each field: {type: 'text', description: '...'}",
                },
                "description": {
                    "type": "string",
                    "description": "Optional description of the type",
                },
            },
            "required": ["name", "fields"],
        },
    },
    {
        "name": "brain_update_type",
        "description": (
            "Add or update fields on an existing entity type. "
            "New fields are added as columns to the database (no restart needed). "
            "Existing entity data is preserved."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Entity type to update"},
                "fields": {
                    "type": "object",
                    "description": "Fields to add or update. Each field: {type: 'text', description: '...'}",
                },
            },
            "required": ["name", "fields"],
        },
    },
    {
        "name": "brain_delete_type",
        "description": (
            "Remove an entity type from entity_types.yaml. "
            "Existing entities and database columns are preserved (data not lost). "
            "The type will no longer appear in the sidebar."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string", "description": "Entity type to remove"}},
            "required": ["name"],
        },
    },
    # ── Entity CRUD ───────────────────────────────────────────────────────────
    {
        "name": "brain_create_entity",
        "description": (
            "Create an entity directly in the graph. Prefer brain_upsert_entity "
            "which handles deduplication automatically."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_type": {
                    "type": "string",
                    "description": "Any string label for the entity type",
                },
                "data": {
                    "type": "object",
                    "description": "Entity fields. Must include 'name'.",
                },
            },
            "required": ["entity_type", "data"],
        },
    },
    {
        "name": "brain_query_entities",
        "description": "List entities by type. Use brain_search for text search.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_type": {
                    "type": "string",
                    "description": "Entity type to query",
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum results (default 100)",
                    "minimum": 1,
                    "maximum": 1000,
                },
                "offset": {
                    "type": "integer",
                    "description": "Pagination offset",
                    "minimum": 0,
                },
            },
            "required": ["entity_type"],
        },
    },
    {
        "name": "brain_get_entity",
        "description": "Retrieve an entity by name. Returns all field values.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_id": {
                    "type": "string",
                    "description": "Entity name (e.g. 'Parachute', 'Kevin')",
                },
            },
            "required": ["entity_id"],
        },
    },
    {
        "name": "brain_update_entity",
        "description": "Update entity field values directly.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_id": {"type": "string", "description": "Entity name to update"},
                "data": {"type": "object", "description": "Updated field values"},
            },
            "required": ["entity_id", "data"],
        },
    },
    {
        "name": "brain_delete_entity",
        "description": "Delete an entity and all its relationships from the graph.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_id": {"type": "string", "description": "Entity name to delete"},
            },
            "required": ["entity_id"],
        },
    },
    {
        "name": "brain_create_relationship",
        "description": (
            "Create a typed relationship between two entities. "
            "Example: brain_create_relationship(from_id='Kevin', relationship='co-owns', to_id='LVB')"
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "from_id": {"type": "string", "description": "Source entity name"},
                "relationship": {
                    "type": "string",
                    "description": "Relationship label (e.g. 'co-owns', 'works-at', 'collaborates-with')",
                },
                "to_id": {"type": "string", "description": "Target entity name"},
                "description": {
                    "type": "string",
                    "description": "Optional description of the relationship",
                },
            },
            "required": ["from_id", "relationship", "to_id"],
        },
    },
    {
        "name": "brain_traverse_graph",
        "description": "Traverse the knowledge graph from a starting entity. Returns connected entities.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "start_id": {
                    "type": "string",
                    "description": "Starting entity name",
                },
                "relationship": {
                    "type": "string",
                    "description": "Relationship filter (currently unused — traverses all relationships)",
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
    # ── Episode (compat) ──────────────────────────────────────────────────────
    {
        "name": "brain_add_episode",
        "description": (
            "Legacy compatibility tool. "
            "Prefer brain_upsert_entity for structured knowledge. "
            "Maps to upsert_entity using the name field."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Short title for this episode",
                },
                "episode_body": {
                    "type": "string",
                    "description": "Text content",
                },
                "source_description": {
                    "type": "string",
                    "description": "Where this text comes from",
                },
                "reference_time": {
                    "type": "string",
                    "description": "ISO 8601 timestamp (unused, kept for compat)",
                },
            },
            "required": ["name", "episode_body", "source_description"],
        },
    },
    # ── Saved queries ─────────────────────────────────────────────────────────
    {
        "name": "brain_list_saved_queries",
        "description": "List all saved Cypher queries.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "brain_save_query",
        "description": "Save a named filter query for later reuse.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Human-readable name"},
                "entity_type": {"type": "string", "description": "Entity type this query targets"},
                "filters": {
                    "type": "array",
                    "description": "Filter conditions",
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
                "query_id": {"type": "string", "description": "UUID of the saved query"},
            },
            "required": ["query_id"],
        },
    },
]


# ── Tool Handlers ─────────────────────────────────────────────────────────────

async def handle_upsert_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    try:
        entity = await svc.upsert_entity(
            entity_type=arguments["entity_type"],
            name=arguments["name"],
            attributes=arguments.get("attributes", {}),
        )
        return {"success": True, "entity": entity}
    except Exception as e:
        logger.error(f"brain_upsert_entity failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_search(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    try:
        results = await svc.search(
            query=arguments["query"],
            entity_type=arguments.get("entity_type", ""),
            num_results=min(arguments.get("num_results", 20), 50),
        )
        return {"success": True, "results": results, "count": len(results)}
    except Exception as e:
        logger.error(f"brain_search failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_cypher_query(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    try:
        results = await svc.execute_cypher(
            query=arguments["query"],
            params=arguments.get("params"),
        )
        return {"success": True, "results": results, "count": len(results)}
    except Exception as e:
        logger.error(f"brain_cypher_query failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_list_types(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    try:
        types = await svc.list_types_with_counts()
        return {"success": True, "types": types, "count": len(types)}
    except Exception as e:
        logger.error(f"brain_list_types failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_create_type(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    type_name = arguments.get("name", "")
    fields = arguments.get("fields", {})
    if not type_name:
        return {"success": False, "error": "name is required"}
    from .schema import load_entity_types, save_entity_types
    entity_types = load_entity_types(module.vault_path)
    if type_name in entity_types:
        return {"success": False, "error": f"Type '{type_name}' already exists. Use brain_update_type to add fields."}
    normalized: dict[str, Any] = {}
    for fname, fdef in fields.items():
        if isinstance(fdef, dict):
            normalized[fname] = {"type": fdef.get("type", "text"), "description": fdef.get("description", "")}
        else:
            normalized[fname] = {"type": "text", "description": str(fdef)}
    entity_types[type_name] = normalized
    save_entity_types(module.vault_path, entity_types)
    try:
        added = await svc.sync_schema()
    except Exception as e:
        logger.warning(f"sync_schema failed: {e}")
        added = {"added": []}
    return {
        "success": True,
        "name": type_name,
        "fields_count": len(normalized),
        "columns_added": added.get("added", []),
    }


async def handle_update_type(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    type_name = arguments.get("name", "")
    fields = arguments.get("fields", {})
    from .schema import load_entity_types, save_entity_types
    entity_types = load_entity_types(module.vault_path)
    if type_name not in entity_types:
        return {"success": False, "error": f"Type '{type_name}' not found. Use brain_create_type first."}
    existing = entity_types[type_name]
    for fname, fdef in fields.items():
        if isinstance(fdef, dict):
            existing[fname] = {"type": fdef.get("type", "text"), "description": fdef.get("description", "")}
        else:
            existing[fname] = {"type": "text", "description": str(fdef)}
    entity_types[type_name] = existing
    save_entity_types(module.vault_path, entity_types)
    try:
        added = await svc.sync_schema()
    except Exception as e:
        logger.warning(f"sync_schema failed: {e}")
        added = {"added": []}
    return {
        "success": True,
        "name": type_name,
        "fields_count": len(existing),
        "columns_added": added.get("added", []),
    }


async def handle_delete_type(module, arguments: dict[str, Any]) -> dict[str, Any]:
    type_name = arguments.get("name", "")
    from .schema import load_entity_types, save_entity_types
    entity_types = load_entity_types(module.vault_path)
    if type_name not in entity_types:
        return {"success": False, "error": f"Type '{type_name}' not found."}
    del entity_types[type_name]
    save_entity_types(module.vault_path, entity_types)
    return {
        "success": True,
        "name": type_name,
        "note": "Type removed from schema. Existing entities and columns are preserved.",
    }


async def handle_create_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    entity_type = arguments["entity_type"]
    data = arguments["data"]
    name = data.get("name", "")
    if not name:
        return {"success": False, "error": "data.name is required"}
    attributes = {k: v for k, v in data.items() if k != "name"}
    try:
        entity = await svc.upsert_entity(entity_type=entity_type, name=name, attributes=attributes)
        return {"success": True, "entity_id": name, "entity": entity}
    except Exception as e:
        logger.error(f"brain_create_entity failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_query_entities(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    try:
        result = await svc.query_entities(
            entity_type=arguments["entity_type"],
            limit=min(arguments.get("limit", 100), 1000),
            offset=arguments.get("offset", 0),
        )
        return {"success": True, **result}
    except Exception as e:
        logger.error(f"brain_query_entities failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_get_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    entity_name = arguments["entity_id"]
    try:
        entity = await svc.get_entity(entity_name)
        if entity is None:
            return {"success": False, "error": f"Entity not found: {entity_name}"}
        return {"success": True, "entity": entity}
    except Exception as e:
        logger.error(f"brain_get_entity failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_update_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    entity_name = arguments["entity_id"]
    data = arguments["data"]
    existing = await svc.get_entity(entity_name)
    if existing is None:
        return {"success": False, "error": f"Entity not found: {entity_name}"}
    entity_type = existing.get("entity_type", "Unknown")
    try:
        entity = await svc.upsert_entity(entity_type=entity_type, name=entity_name, attributes=data)
        return {"success": True, "entity_id": entity_name, "entity": entity}
    except Exception as e:
        logger.error(f"brain_update_entity failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_delete_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    entity_name = arguments["entity_id"]
    try:
        deleted = await svc.delete_entity(entity_name)
        if not deleted:
            return {"success": False, "error": f"Entity not found: {entity_name}"}
        return {"success": True, "entity_id": entity_name, "message": f"Deleted '{entity_name}'"}
    except Exception as e:
        logger.error(f"brain_delete_entity failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_create_relationship(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    from_id = arguments["from_id"]
    relationship = arguments["relationship"]
    to_id = arguments["to_id"]
    description = arguments.get("description", "")
    try:
        result = await svc.upsert_relationship(
            from_name=from_id,
            label=relationship,
            to_name=to_id,
            description=description,
        )
        return {
            "success": True,
            "message": f"Created relationship: {from_id} --[{relationship}]--> {to_id}",
            **result,
        }
    except Exception as e:
        logger.error(f"brain_create_relationship failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_traverse_graph(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    start_id = arguments["start_id"]
    max_depth = min(arguments.get("max_depth", 2), 5)
    try:
        results = await svc.traverse(start_name=start_id, max_depth=max_depth)
        return {"success": True, "results": results, "count": len(results)}
    except Exception as e:
        logger.error(f"brain_traverse_graph failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_add_episode(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Legacy compat — maps to upsert_entity."""
    svc = await module._ensure_service()
    from .schema import load_entity_types
    name = arguments["name"]
    episode_body = arguments["episode_body"]
    entity_type = "Note"
    entity_name = name
    if ": " in name:
        parts = name.split(": ", 1)
        entity_types_known = load_entity_types(module.vault_path)
        if parts[0] in entity_types_known:
            entity_type = parts[0]
            entity_name = parts[1]
    try:
        entity = await svc.upsert_entity(
            entity_type=entity_type,
            name=entity_name,
            attributes={"description": episode_body},
        )
        return {"success": True, "episode_uuid": None, "nodes_created": 1, "edges_created": 0, "entity": entity}
    except Exception as e:
        logger.error(f"brain_add_episode failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_list_saved_queries(module, arguments: dict[str, Any]) -> dict[str, Any]:
    queries_path = module.vault_path / ".brain" / "queries.json"
    try:
        async with module._queries_lock:
            if queries_path.exists():
                text = await asyncio.to_thread(queries_path.read_text)
                data = json.loads(text)
                queries = data.get("queries", [])
            else:
                queries = []
        return {"success": True, "queries": queries, "count": len(queries)}
    except Exception as e:
        logger.error(f"brain_list_saved_queries failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_save_query(module, arguments: dict[str, Any]) -> dict[str, Any]:
    queries_path = module.vault_path / ".brain" / "queries.json"
    queries_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        async with module._queries_lock:
            if queries_path.exists():
                text = await asyncio.to_thread(queries_path.read_text)
                data = json.loads(text)
            else:
                data = {"queries": []}
            query_id = str(uuid.uuid4())
            entry = {
                "id": query_id,
                "name": arguments["name"],
                "entity_type": arguments["entity_type"],
                "filters": arguments["filters"],
            }
            data["queries"].append(entry)
            await asyncio.to_thread(queries_path.write_text, json.dumps(data, indent=2))
        return {"success": True, "id": query_id}
    except Exception as e:
        logger.error(f"brain_save_query failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_delete_saved_query(module, arguments: dict[str, Any]) -> dict[str, Any]:
    query_id = arguments["query_id"]
    queries_path = module.vault_path / ".brain" / "queries.json"
    try:
        async with module._queries_lock:
            if not queries_path.exists():
                return {"success": False, "error": "No saved queries found"}
            text = await asyncio.to_thread(queries_path.read_text)
            data = json.loads(text)
            original_count = len(data.get("queries", []))
            data["queries"] = [q for q in data.get("queries", []) if q.get("id") != query_id]
            if len(data["queries"]) == original_count:
                return {"success": False, "error": f"Query '{query_id}' not found"}
            await asyncio.to_thread(queries_path.write_text, json.dumps(data, indent=2))
        return {"success": True, "message": f"Deleted query '{query_id}'"}
    except Exception as e:
        logger.error(f"brain_delete_saved_query failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


# ── Handler Registry ──────────────────────────────────────────────────────────

TOOL_HANDLERS = {
    "brain_upsert_entity": handle_upsert_entity,
    "brain_add_episode": handle_add_episode,
    "brain_search": handle_search,
    "brain_cypher_query": handle_cypher_query,
    "brain_list_types": handle_list_types,
    "brain_create_type": handle_create_type,
    "brain_update_type": handle_update_type,
    "brain_delete_type": handle_delete_type,
    "brain_create_entity": handle_create_entity,
    "brain_query_entities": handle_query_entities,
    "brain_get_entity": handle_get_entity,
    "brain_update_entity": handle_update_entity,
    "brain_delete_entity": handle_delete_entity,
    "brain_create_relationship": handle_create_relationship,
    "brain_traverse_graph": handle_traverse_graph,
    "brain_list_saved_queries": handle_list_saved_queries,
    "brain_save_query": handle_save_query,
    "brain_delete_saved_query": handle_delete_saved_query,
}
