"""
Brain MCP Tools

Agent-native access to the Graphiti knowledge graph.
14 legacy tools preserved by name + 3 new tools (add_episode, search, cypher_query).
"""

import asyncio
import json
import logging
import uuid
from typing import Any

logger = logging.getLogger(__name__)


# ── Tool Definitions ──────────────────────────────────────────────────────────

BRAIN_TOOLS = [
    # ── New primary tools ────────────────────────────────────────────────────
    {
        "name": "brain_add_episode",
        "description": (
            "Ingest text as an episode into the knowledge graph. "
            "Graphiti's LLM extracts Person, Project, Area, and Topic entities "
            "automatically. Use this as the primary way to contribute knowledge. "
            "Examples: journal entries, meeting notes, project updates, conversations."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Short title for this episode (e.g. 'Journal 2026-02-25 morning')",
                },
                "episode_body": {
                    "type": "string",
                    "description": "Text content to extract entities from",
                },
                "source_description": {
                    "type": "string",
                    "description": "Where this text comes from (e.g. 'Daily journal', 'Chat session')",
                },
                "reference_time": {
                    "type": "string",
                    "description": "ISO 8601 timestamp for temporal anchoring (e.g. '2026-02-25T09:00:00Z'). Defaults to now.",
                },
            },
            "required": ["name", "episode_body", "source_description"],
        },
    },
    {
        "name": "brain_search",
        "description": (
            "Hybrid search (semantic + BM25) over the knowledge graph. "
            "Returns matching facts and relationships between entities. "
            "Preferred over brain_query_entities for natural language queries."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Natural language search query",
                },
                "num_results": {
                    "type": "integer",
                    "description": "Maximum results to return (default 10)",
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
            "Execute a Cypher query directly against the Kuzu graph database. "
            "For power users and debugging. Use named saved queries when possible."
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
    # ── Legacy tools (kept by name, Graphiti backends) ───────────────────────
    {
        "name": "brain_list_types",
        "description": "List Brain entity types (Person, Project, Area, Topic) with field descriptions.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "brain_create_type",
        "description": (
            "Not supported with Graphiti backend. "
            "Entity types are defined in code (Person, Project, Area, Topic). "
            "Use brain_add_episode to contribute knowledge."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "fields": {"type": "object"},
            },
            "required": ["name", "fields"],
        },
    },
    {
        "name": "brain_update_type",
        "description": "Not supported with Graphiti backend. Schema is defined in code.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "fields": {"type": "object"},
            },
            "required": ["name", "fields"],
        },
    },
    {
        "name": "brain_delete_type",
        "description": "Not supported with Graphiti backend. Schema is defined in code.",
        "inputSchema": {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "required": ["name"],
        },
    },
    {
        "name": "brain_create_entity",
        "description": (
            "Create an entity by adding a synthetic episode. "
            "Graphiti extracts it as a structured entity. "
            "Prefer brain_add_episode with natural text for better extraction."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_type": {
                    "type": "string",
                    "description": "Entity type: Person, Project, Area, or Topic",
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
        "description": "Query entities by type with pagination. Returns entities from the graph.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_type": {
                    "type": "string",
                    "description": "Entity type to query (Person, Project, Area, Topic)",
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
        "description": "Retrieve an entity by name. Returns entity summary and labels.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_id": {
                    "type": "string",
                    "description": "Entity name (e.g. 'Parachute', 'Aaron')",
                },
            },
            "required": ["entity_id"],
        },
    },
    {
        "name": "brain_update_entity",
        "description": (
            "Update an entity by adding a new episode with corrected information. "
            "Graphiti tracks temporal changes automatically — previous facts are preserved."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "entity_id": {"type": "string", "description": "Entity name to update"},
                "data": {"type": "object", "description": "Updated fields"},
            },
            "required": ["entity_id", "data"],
        },
    },
    {
        "name": "brain_delete_entity",
        "description": (
            "Logically delete an entity by recording its removal as an episode. "
            "Graphiti creates a temporal invalidation — historical facts are preserved."
        ),
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
        "description": "Create a relationship between two entities via an episode.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "from_id": {"type": "string", "description": "Source entity name"},
                "relationship": {
                    "type": "string",
                    "description": "Relationship description (e.g. 'works on', 'collaborates with')",
                },
                "to_id": {"type": "string", "description": "Target entity name"},
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
                    "description": "Relationship filter (currently ignored — traverses all edges)",
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
        "name": "brain_list_saved_queries",
        "description": "List all saved Cypher queries.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "brain_save_query",
        "description": "Save a named Cypher query for later reuse.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Human-readable name"},
                "entity_type": {"type": "string", "description": "Entity type this query targets"},
                "filters": {
                    "type": "array",
                    "description": "Filter conditions (legacy format, for UI compatibility)",
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
                "cypher": {
                    "type": "string",
                    "description": "Optional raw Cypher query string",
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

async def handle_add_episode(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    from datetime import datetime, timezone

    ref_time = None
    if "reference_time" in arguments:
        try:
            ref_time = datetime.fromisoformat(arguments["reference_time"])
        except ValueError:
            pass
    if ref_time is None:
        ref_time = datetime.now(timezone.utc)

    try:
        result = await svc.add_episode(
            name=arguments["name"],
            episode_body=arguments["episode_body"],
            source_description=arguments["source_description"],
            reference_time=ref_time,
        )
        return result
    except Exception as e:
        logger.error(f"brain_add_episode failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_search(module, arguments: dict[str, Any]) -> dict[str, Any]:
    svc = await module._ensure_service()
    try:
        results = await svc.search(
            query=arguments["query"],
            num_results=min(arguments.get("num_results", 10), 50),
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
    await module._ensure_service()
    try:
        from .graphiti_service import GraphitiService
        svc = module._service
        types = svc.list_types()
        return {"success": True, "types": types, "count": len(types)}
    except Exception as e:
        logger.error(f"brain_list_types failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


def _schema_not_supported(tool_name: str) -> dict[str, Any]:
    return {
        "success": False,
        "error": (
            f"{tool_name} is not supported with the Graphiti backend. "
            "Entity types (Person, Project, Area, Topic) are defined in code. "
            "Use brain_add_episode to contribute knowledge to the graph."
        ),
    }


async def handle_create_type(module, arguments: dict[str, Any]) -> dict[str, Any]:
    return _schema_not_supported("brain_create_type")


async def handle_update_type(module, arguments: dict[str, Any]) -> dict[str, Any]:
    return _schema_not_supported("brain_update_type")


async def handle_delete_type(module, arguments: dict[str, Any]) -> dict[str, Any]:
    return _schema_not_supported("brain_delete_type")


async def handle_create_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Create entity via synthetic episode text."""
    svc = await module._ensure_service()
    entity_type = arguments["entity_type"]
    data = arguments["data"]
    name = data.get("name", "Unknown")

    # Build natural-language episode from the structured data
    fields_text = ". ".join(f"{k}: {v}" for k, v in data.items() if k != "name" and v)
    episode_body = f"New {entity_type}: {name}."
    if fields_text:
        episode_body += f" {fields_text}."

    try:
        result = await svc.add_episode(
            name=f"Create {entity_type}: {name}",
            episode_body=episode_body,
            source_description=f"Manual entity creation via brain_create_entity",
        )
        return {
            "success": True,
            "entity_id": name,
            "message": f"Created {entity_type} entity '{name}' via episode ingestion",
            **result,
        }
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
    entity_name = arguments["entity_id"]  # entity_id is the entity name
    try:
        entity = await svc.get_entity(entity_name)
        if entity is None:
            return {"success": False, "error": f"Entity not found: {entity_name}"}
        return {"success": True, "entity": entity}
    except Exception as e:
        logger.error(f"brain_get_entity failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_update_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Update entity via episode (Graphiti tracks temporal changes)."""
    svc = await module._ensure_service()
    entity_name = arguments["entity_id"]
    data = arguments["data"]

    fields_text = ". ".join(f"{k} is now {v}" for k, v in data.items() if v)
    episode_body = f"Update for {entity_name}: {fields_text}." if fields_text else f"{entity_name} has been updated."

    try:
        result = await svc.add_episode(
            name=f"Update: {entity_name}",
            episode_body=episode_body,
            source_description="Manual entity update via brain_update_entity",
        )
        return {
            "success": True,
            "entity_id": entity_name,
            "message": (
                "Updated via episode ingestion. "
                "Graphiti tracks temporal changes automatically — previous facts are preserved."
            ),
            **result,
        }
    except Exception as e:
        logger.error(f"brain_update_entity failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_delete_entity(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Logically delete entity via episode (temporal invalidation)."""
    svc = await module._ensure_service()
    entity_name = arguments["entity_id"]

    try:
        result = await svc.add_episode(
            name=f"Delete: {entity_name}",
            episode_body=f"Aaron no longer tracks entity: {entity_name}.",
            source_description="Logical entity deletion via brain_delete_entity",
        )
        return {
            "success": True,
            "entity_id": entity_name,
            "message": (
                "Entity logically deleted via temporal invalidation episode. "
                "Historical facts are preserved."
            ),
            **result,
        }
    except Exception as e:
        logger.error(f"brain_delete_entity failed: {e}", exc_info=True)
        return {"success": False, "error": str(e)}


async def handle_create_relationship(module, arguments: dict[str, Any]) -> dict[str, Any]:
    """Create relationship via episode text."""
    svc = await module._ensure_service()
    from_id = arguments["from_id"]
    relationship = arguments["relationship"]
    to_id = arguments["to_id"]

    episode_body = f"{from_id} {relationship} {to_id}."
    try:
        result = await svc.add_episode(
            name=f"Relationship: {from_id} → {to_id}",
            episode_body=episode_body,
            source_description="Manual relationship creation via brain_create_relationship",
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
        results = await svc.traverse_graph(
            start_name=start_id,
            max_depth=max_depth,
        )
        return {"success": True, "results": results, "count": len(results)}
    except Exception as e:
        logger.error(f"brain_traverse_graph failed: {e}", exc_info=True)
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
            if "cypher" in arguments:
                entry["cypher"] = arguments["cypher"]
            data["queries"].append(entry)
            await asyncio.to_thread(queries_path.write_text, json.dumps(data, indent=2))
        return {"success": True, "id": query_id, "message": f"Saved query '{arguments['name']}'"}
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
