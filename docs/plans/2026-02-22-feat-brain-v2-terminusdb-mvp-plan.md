---
title: Brain v2: TerminusDB Knowledge Graph MVP
type: feat
date: 2026-02-22
issue: 94
---

# Brain v2: TerminusDB Knowledge Graph MVP

## Overview

Implement Phase 1 MVP of Parachute Brain v2 as a strongly-typed, version-controlled knowledge graph powered by TerminusDB. This prototype validates core integration mechanics, tests agent-native interaction patterns, and establishes the foundation for a production extended mind system.

**Scope:** Minimal viable implementation to prove TerminusDB integration, MCP tool exposure, schema validation, and data persistence. UI and advanced query features deferred to Phase 2.

## Problem Statement

Current Brain module (`computer/modules/brain/`) is a minimal file-based entity store with:
- Simple substring search (no graph traversal)
- No relationships between entities
- No schema enforcement or type safety
- No version control for data
- Limited agent integration

This limits Parachute's ability to serve as a true extended mind system where agents build and query structured knowledge over time.

## Proposed Solution

Build Brain v2 as a separate module (`computer/modules/brain_v2/`) that:
1. Runs TerminusDB in Docker for graph storage
2. Defines entity schemas in YAML files (`vault/.brain/schemas/*.yaml`)
3. Exposes MCP tools for agent interaction
4. Provides FastAPI routes for UI testing
5. Persists data across server restarts
6. Supports schema evolution without breaking existing data

**Tech stack:**
- TerminusDB v12.0.0 (Docker container)
- `terminusdb-client` Python library (v10.2.6)
- Pydantic models for validation
- Async wrappers via `asyncio.to_thread()`
- MCP tools in existing `parachute/mcp_server.py`

## Technical Approach

### Architecture

```
Agent/User Request
    ↓
MCP Tool Call / FastAPI Route
    ↓
BrainV2Module
    ↓
KnowledgeGraphService (async wrapper)
    ↓
terminusdb-client (sync library, wrapped with asyncio.to_thread)
    ↓
TerminusDB Docker Container
    ↓
Binary Storage (vault/.brain/data/)
    ↕
Periodic RDF Export (vault/.brain/exports/)
```

### File Structure

```
computer/modules/brain_v2/
├── manifest.yaml              # Module metadata, provides: BrainV2Interface
├── module.py                  # BrainV2Module class (router, interface methods)
├── knowledge_graph.py         # KnowledgeGraphService (async wrapper)
├── schema_compiler.py         # YAML → TerminusDB JSON schema compiler
└── models.py                  # Pydantic models (Entity, Schema, QueryRequest)

computer/parachute/
├── mcp_server.py              # Extended with Brain v2 tools
└── docker/
    └── docker-compose.brain.yml   # TerminusDB service definition

vault/.brain/
├── schemas/
│   ├── person.yaml            # Person entity schema
│   ├── project.yaml           # Project entity schema
│   └── note.yaml              # Note entity schema
├── data/                      # TerminusDB storage (Docker volume)
└── exports/                   # Periodic RDF/JSON snapshots
```

### Implementation Phases

#### Phase 1.1: TerminusDB Docker Setup

**Tasks:**
- [ ] Create `computer/parachute/docker/docker-compose.brain.yml` with TerminusDB v12.0.0 service
- [ ] Configure volume mount to `vault/.brain/data/`
- [ ] Add health check endpoint (`http://localhost:6363/api/info`)
- [ ] Integrate into server startup lifespan manager (`parachute/server.py`)
- [ ] Test container starts/stops with server lifecycle

**Files to create:**
- `docker-compose.brain.yml`

**Files to modify:**
- `parachute/server.py:44-192` (lifespan manager)

**Success criteria:**
- TerminusDB container starts with Parachute server
- Data persists across container restarts
- Health check passes before server accepts requests

**Docker Compose Definition:**

```yaml
# computer/parachute/docker/docker-compose.brain.yml
version: '3.8'

services:
  terminusdb:
    image: terminusdb/terminusdb-server:v12.0.0
    container_name: parachute-brain-terminusdb
    hostname: terminusdb-server
    ports:
      - "6363:6363"
    volumes:
      - ${VAULT_PATH}/.brain/data:/app/terminusdb/storage
    environment:
      - TERMINUSDB_SERVER_NAME=localhost
      - TERMINUSDB_ADMIN_PASS=${TERMINUSDB_ADMIN_PASS:-root}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:6363/api/info"]
      interval: 10s
      timeout: 5s
      retries: 5
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
```

**Security Hardening Applied:**
- `--security-opt=no-new-privileges` prevents privilege escalation
- `--cap-drop=ALL` removes all Linux capabilities
- `--cap-add` restores only essential capabilities for TerminusDB
- Non-root user by default in TerminusDB image

**Lifespan Integration Pattern:**

```python
# parachute/server.py
from pathlib import Path
import asyncio
import subprocess

async def start_terminusdb(vault_path: Path):
    """Start TerminusDB container if not running"""
    compose_file = Path(__file__).parent / "docker" / "docker-compose.brain.yml"

    # Use asyncio.create_subprocess_exec (NOT subprocess.run - blocks event loop!)
    proc = await asyncio.create_subprocess_exec(
        "docker-compose",
        "-f", str(compose_file),
        "--project-directory", str(vault_path),
        "up", "-d",
        env={"VAULT_PATH": str(vault_path)},
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()

    if proc.returncode != 0:
        raise RuntimeError(f"Failed to start TerminusDB: {stderr.decode()}")

    # Wait for health check
    for i in range(30):  # 30 * 2s = 60s timeout
        try:
            async with httpx.AsyncClient() as client:
                resp = await client.get("http://localhost:6363/api/info", timeout=2.0)
                if resp.status_code == 200:
                    logger.info("TerminusDB ready")
                    return
        except Exception:
            await asyncio.sleep(2)

    raise RuntimeError("TerminusDB health check timed out")

@asynccontextmanager
async def lifespan(app: FastAPI):
    # ... existing startup ...

    # Start TerminusDB
    await start_terminusdb(vault_path)

    yield

    # Cleanup (existing pattern)
```

---

#### Phase 1.2: Schema System

**Tasks:**
- [ ] Design YAML schema format for entity types (Person, Project, Note)
- [ ] Implement `SchemaCompiler` class to parse YAML → TerminusDB JSON schema
- [ ] Create initial schemas: `person.yaml`, `project.yaml`, `note.yaml`
- [ ] Add schema validation on module startup
- [ ] Test schema compilation and loading into TerminusDB

**Files to create:**
- `modules/brain_v2/schema_compiler.py`
- `vault/.brain/schemas/person.yaml`
- `vault/.brain/schemas/project.yaml`
- `vault/.brain/schemas/note.yaml`

**Success criteria:**
- YAML schemas parse without errors
- Compiled schemas load into TerminusDB successfully
- Invalid schemas raise clear errors on startup
- Schema changes (weakening only) don't break existing entities

**YAML Schema Format (Tana-inspired):**

```yaml
# vault/.brain/schemas/person.yaml
name: Person
description: A person entity in the knowledge graph
key_strategy: Lexical  # URI from name field
key_fields:
  - name

fields:
  name:
    type: string
    required: true
    description: Full name of the person

  email:
    type: string
    required: false
    description: Email address

  company:
    type: string
    required: false
    description: Company affiliation

  role:
    type: string
    required: false
    description: Role or title

  tags:
    type: array
    items: string
    required: false
    description: Tags for categorization

  notes:
    type: string
    required: false
    description: Free-form notes

  related_projects:
    type: array
    items: Project
    required: false
    description: Projects this person is involved with
```

```yaml
# vault/.brain/schemas/project.yaml
name: Project
description: A project or initiative
key_strategy: Lexical
key_fields:
  - name

fields:
  name:
    type: string
    required: true

  description:
    type: string
    required: false

  status:
    type: enum
    values: [active, paused, completed, archived]
    required: false
    default: active

  tags:
    type: array
    items: string
    required: false

  team_members:
    type: array
    items: Person
    required: false
```

```yaml
# vault/.brain/schemas/note.yaml
name: Note
description: A standalone note or thought
key_strategy: Random  # UUID, not name-based

fields:
  title:
    type: string
    required: true

  content:
    type: string
    required: true

  tags:
    type: array
    items: string
    required: false

  linked_entities:
    type: array
    items: [Person, Project]  # Union type
    required: false

  created_at:
    type: datetime
    required: true
```

**Schema Compiler Implementation:**

```python
# modules/brain_v2/schema_compiler.py
from pathlib import Path
import yaml
from typing import Any

class SchemaCompiler:
    """Compile YAML schemas to TerminusDB JSON schema format"""

    TYPE_MAP = {
        "string": "xsd:string",
        "integer": "xsd:integer",
        "boolean": "xsd:boolean",
        "datetime": "xsd:dateTime",
        "enum": "Enum",  # Handled specially
        "array": "List",  # Handled specially
    }

    def compile_schema(self, yaml_path: Path) -> dict:
        """Parse YAML and generate TerminusDB JSON schema"""
        with open(yaml_path) as f:
            schema_def = yaml.safe_load(f)

        # Build TerminusDB DocumentTemplate equivalent
        json_schema = {
            "@type": "Class",
            "@id": schema_def["name"],
            "@documentation": schema_def.get("description", ""),
            "@key": self._build_key_strategy(schema_def),
        }

        # Compile fields
        for field_name, field_spec in schema_def.get("fields", {}).items():
            json_schema[field_name] = self._compile_field(field_spec)

        return json_schema

    def _build_key_strategy(self, schema_def: dict) -> dict:
        """Generate @key based on key_strategy"""
        strategy = schema_def.get("key_strategy", "Random")

        if strategy == "Lexical":
            return {
                "@type": "Lexical",
                "@fields": schema_def.get("key_fields", ["name"]),
            }
        elif strategy == "Random":
            return {"@type": "Random"}
        elif strategy == "Hash":
            return {
                "@type": "Hash",
                "@fields": schema_def.get("key_fields", []),
            }
        else:
            raise ValueError(f"Unknown key strategy: {strategy}")

    def _compile_field(self, field_spec: dict) -> Any:
        """Compile single field to TerminusDB type"""
        field_type = field_spec["type"]
        required = field_spec.get("required", False)

        # Handle primitive types
        if field_type in self.TYPE_MAP:
            terminus_type = self.TYPE_MAP[field_type]

        # Handle enums
        elif field_type == "enum":
            # Create inline enum (alternative: separate EnumTemplate)
            enum_name = f"{field_spec.get('name', 'Enum')}"
            return {
                "@type": "Enum",
                "@id": enum_name,
                "@values": field_spec["values"],
            }

        # Handle arrays
        elif field_type == "array":
            item_type = field_spec["items"]
            if isinstance(item_type, str):
                # Single type array
                if item_type in self.TYPE_MAP:
                    terminus_type = {"@type": "List", "@class": self.TYPE_MAP[item_type]}
                else:
                    # Reference to another entity
                    terminus_type = {"@type": "List", "@class": item_type}
            elif isinstance(item_type, list):
                # Union type array (e.g., [Person, Project])
                terminus_type = {
                    "@type": "List",
                    "@class": {"@type": "TaggedUnion", "@classes": item_type},
                }

        # Handle entity references
        else:
            # Assume it's a reference to another entity type
            terminus_type = field_type

        # Wrap in Optional if not required
        if not required:
            return {"@type": "Optional", "@class": terminus_type}

        return terminus_type

    def compile_all_schemas(self, schemas_dir: Path) -> list[dict]:
        """Compile all YAML schemas in directory"""
        schemas = []
        for yaml_file in schemas_dir.glob("*.yaml"):
            schemas.append(self.compile_schema(yaml_file))
        return schemas
```

**Usage in Module Startup:**

```python
# modules/brain_v2/module.py
from pathlib import Path
from .schema_compiler import SchemaCompiler

class BrainV2Module:
    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path
        self.schemas_dir = vault_path / ".brain" / "schemas"

        # Ensure directories exist
        self.schemas_dir.mkdir(parents=True, exist_ok=True)
        (vault_path / ".brain" / "data").mkdir(parents=True, exist_ok=True)
        (vault_path / ".brain" / "exports").mkdir(parents=True, exist_ok=True)

        # Compile and load schemas
        compiler = SchemaCompiler()
        self.schemas = compiler.compile_all_schemas(self.schemas_dir)

        # Initialize KnowledgeGraphService (Phase 1.3)
        # self.kg_service = KnowledgeGraphService(...)
```

---

#### Phase 1.3: Knowledge Graph Service

**Tasks:**
- [ ] Install `terminusdb-client` Python library
- [ ] Create `KnowledgeGraphService` class with async wrappers
- [ ] Implement core operations: connect, create_entity, query_entities, create_relationship
- [ ] Test basic CRUD operations
- [ ] Validate schema enforcement on writes

**Files to create:**
- `modules/brain_v2/knowledge_graph.py`
- `modules/brain_v2/models.py` (Pydantic request/response models)

**Files to modify:**
- `computer/requirements.txt` (add `terminusdb-client>=10.2.6`)

**Success criteria:**
- Service connects to TerminusDB successfully
- Entities created with schema validation
- Queries return correct results
- Invalid entities rejected with clear errors
- Data persists across Python process restarts

**KnowledgeGraphService Implementation:**

```python
# modules/brain_v2/knowledge_graph.py
from pathlib import Path
from typing import Optional, Any
import asyncio
import os
from terminusdb_client import WOQLClient
from terminusdb_client.errors import DatabaseError

class KnowledgeGraphService:
    """Async wrapper around TerminusDB client"""

    def __init__(
        self,
        vault_path: Path,
        server_url: str = "http://localhost:6363",
        db_name: str = "parachute_brain",
    ):
        self.vault_path = vault_path
        self.server_url = server_url
        self.db_name = db_name
        self.client: Optional[WOQLClient] = None
        self._connected = False

    async def connect(self, schemas: list[dict]) -> None:
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

            # Load schemas (replace existing)
            # TerminusDB allows schema evolution via weakening changes
            for schema in schemas:
                client.insert_document(
                    schema,
                    graph_type="schema",
                    commit_msg="Update schema from YAML definitions",
                )

            return client

        # CRITICAL PATTERN: Use asyncio.to_thread() for blocking client calls
        # Never use subprocess.run() in async context (freezes event loop)
        self.client = await asyncio.to_thread(_connect_sync)
        self._connected = True

    async def create_entity(
        self,
        entity_type: str,
        data: dict[str, Any],
        commit_msg: Optional[str] = None,
    ) -> str:
        """Create entity, returns IRI"""
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        def _create_sync():
            doc = {"@type": entity_type, **data}
            result = self.client.insert_document(
                doc,
                commit_msg=commit_msg or f"Create {entity_type}",
            )
            # TerminusDB returns IRI of created document
            return result

        return await asyncio.to_thread(_create_sync)

    async def query_entities(
        self,
        entity_type: str,
        filters: Optional[dict[str, Any]] = None,
    ) -> list[dict]:
        """Query entities by type and optional filters"""
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        def _query_sync():
            template = {"@type": entity_type}
            if filters:
                template.update(filters)

            results = self.client.query_document(template)
            return results

        return await asyncio.to_thread(_query_sync)

    async def get_entity(self, entity_id: str) -> Optional[dict]:
        """Retrieve single entity by IRI"""
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        def _get_sync():
            try:
                return self.client.get_document(entity_id)
            except Exception:
                return None

        return await asyncio.to_thread(_get_sync)

    async def update_entity(
        self,
        entity_id: str,
        updates: dict[str, Any],
        commit_msg: Optional[str] = None,
    ) -> None:
        """Update entity fields"""
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        def _update_sync():
            # Get current document
            doc = self.client.get_document(entity_id)

            # Apply updates
            doc.update(updates)

            # Save
            self.client.update_document(
                doc,
                commit_msg=commit_msg or f"Update {entity_id}",
            )

        await asyncio.to_thread(_update_sync)

    async def create_relationship(
        self,
        from_id: str,
        relationship: str,
        to_id: str,
        commit_msg: Optional[str] = None,
    ) -> None:
        """
        Create relationship between entities.

        Adds to_id to from_entity's relationship field (array).
        Creates bidirectional link if schema defines inverse.
        """
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

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

        await asyncio.to_thread(_create_rel_sync)

    async def traverse_graph(
        self,
        start_id: str,
        relationship: str,
        max_depth: int = 2,
    ) -> list[dict]:
        """
        Traverse graph from starting entity following relationship.

        Returns list of connected entities up to max_depth hops.
        """
        if not self._connected:
            raise RuntimeError("Not connected to TerminusDB")

        def _traverse_sync():
            visited = set()
            results = []
            queue = [(start_id, 0)]

            while queue:
                entity_id, depth = queue.pop(0)

                if entity_id in visited or depth > max_depth:
                    continue

                visited.add(entity_id)

                # Get entity
                entity = self.client.get_document(entity_id)
                if not entity:
                    continue

                results.append(entity)

                # Follow relationships
                if relationship in entity:
                    related_ids = entity[relationship]
                    if not isinstance(related_ids, list):
                        related_ids = [related_ids]

                    for related_id in related_ids:
                        if related_id not in visited:
                            queue.append((related_id, depth + 1))

            return results

        return await asyncio.to_thread(_traverse_sync)

    async def export_to_rdf(self, output_path: Path) -> None:
        """Export current graph state to RDF/Turtle format"""
        # TODO: Phase 2 - implement RDF export
        pass
```

**Pydantic Models:**

```python
# modules/brain_v2/models.py
from pydantic import BaseModel, Field
from typing import Optional, Any

class CreateEntityRequest(BaseModel):
    """Request to create entity via MCP tool or API"""
    entity_type: str = Field(description="Type of entity (Person, Project, Note)")
    data: dict[str, Any] = Field(description="Entity field values")
    commit_msg: Optional[str] = Field(default=None, description="Commit message")

class QueryEntitiesRequest(BaseModel):
    """Request to query entities"""
    entity_type: str = Field(description="Type to query")
    filters: Optional[dict[str, Any]] = Field(default=None, description="Filter conditions")

class CreateRelationshipRequest(BaseModel):
    """Request to create relationship"""
    from_id: str = Field(description="Source entity IRI")
    relationship: str = Field(description="Relationship field name")
    to_id: str = Field(description="Target entity IRI")

class TraverseGraphRequest(BaseModel):
    """Request to traverse graph"""
    start_id: str = Field(description="Starting entity IRI")
    relationship: str = Field(description="Relationship to follow")
    max_depth: int = Field(default=2, description="Maximum traversal depth")

class Entity(BaseModel):
    """Generic entity response"""
    id: str = Field(alias="@id", description="Entity IRI")
    type: str = Field(alias="@type", description="Entity type")
    data: dict[str, Any] = Field(description="Entity fields")

    model_config = {"populate_by_name": True}
```

---

#### Phase 1.4: MCP Tools

**Tasks:**
- [ ] Add Brain v2 tools to `parachute/mcp_server.py` TOOLS list
- [ ] Implement tool handlers using `KnowledgeGraphService`
- [ ] Add session context injection for trust level enforcement
- [ ] Test tools via MCP inspector or agent interaction
- [ ] Validate schema-aware suggestions work

**Files to modify:**
- `parachute/mcp_server.py` (add 4 new tools + handlers)

**Success criteria:**
- Agents can create entities with correct schema validation
- Agents can query graph and get results
- Agents can create relationships between entities
- Agents can traverse graph with max depth limits
- Trust levels restrict operations correctly (sandboxed = read-only exports)

**MCP Tool Definitions:**

```python
# parachute/mcp_server.py (additions)

# Import at top
from modules.brain_v2.knowledge_graph import KnowledgeGraphService
from modules.brain_v2.models import (
    CreateEntityRequest,
    QueryEntitiesRequest,
    CreateRelationshipRequest,
    TraverseGraphRequest,
)

# Add to TOOLS list
BRAIN_V2_TOOLS = [
    Tool(
        name="brain_create_entity",
        description="""Create a new entity in the knowledge graph.

        Entities must conform to defined schemas (Person, Project, Note).
        Required fields are enforced based on schema definitions.
        Returns the entity IRI on success.

        Examples:
        - Create Person: {"entity_type": "Person", "data": {"name": "John Doe", "email": "john@example.com"}}
        - Create Project: {"entity_type": "Project", "data": {"name": "AI Research", "status": "active"}}
        """,
        inputSchema={
            "type": "object",
            "properties": {
                "entity_type": {
                    "type": "string",
                    "enum": ["Person", "Project", "Note"],
                    "description": "Type of entity to create",
                },
                "data": {
                    "type": "object",
                    "description": "Entity field values (must match schema)",
                },
                "commit_msg": {
                    "type": "string",
                    "description": "Optional commit message",
                },
            },
            "required": ["entity_type", "data"],
        },
    ),
    Tool(
        name="brain_query_entities",
        description="""Query entities by type and optional filters.

        Returns list of entities matching the query.
        Use filters to narrow results (e.g., {"status": "active"}).

        Examples:
        - All people: {"entity_type": "Person"}
        - Active projects: {"entity_type": "Project", "filters": {"status": "active"}}
        - Person by name: {"entity_type": "Person", "filters": {"name": "John Doe"}}
        """,
        inputSchema={
            "type": "object",
            "properties": {
                "entity_type": {
                    "type": "string",
                    "enum": ["Person", "Project", "Note"],
                    "description": "Type of entity to query",
                },
                "filters": {
                    "type": "object",
                    "description": "Optional filter conditions",
                },
            },
            "required": ["entity_type"],
        },
    ),
    Tool(
        name="brain_create_relationship",
        description="""Create a relationship between two entities.

        Links source entity to target entity via named relationship field.
        Relationship field must exist in source entity's schema.
        Creates bidirectional link if schema defines inverse relationship.

        Examples:
        - Link person to project: {"from_id": "Person/john_doe", "relationship": "related_projects", "to_id": "Project/ai_research"}
        - Link project to person: {"from_id": "Project/ai_research", "relationship": "team_members", "to_id": "Person/john_doe"}
        """,
        inputSchema={
            "type": "object",
            "properties": {
                "from_id": {
                    "type": "string",
                    "description": "Source entity IRI (e.g., Person/john_doe)",
                },
                "relationship": {
                    "type": "string",
                    "description": "Relationship field name from schema",
                },
                "to_id": {
                    "type": "string",
                    "description": "Target entity IRI",
                },
            },
            "required": ["from_id", "relationship", "to_id"],
        },
    ),
    Tool(
        name="brain_traverse_graph",
        description="""Traverse the knowledge graph following relationships.

        Starts from a given entity and follows relationship links up to max_depth hops.
        Returns all connected entities discovered during traversal.

        Examples:
        - Find all projects connected to person: {"start_id": "Person/john_doe", "relationship": "related_projects", "max_depth": 1}
        - Find extended network: {"start_id": "Person/john_doe", "relationship": "related_projects", "max_depth": 2}
        """,
        inputSchema={
            "type": "object",
            "properties": {
                "start_id": {
                    "type": "string",
                    "description": "Starting entity IRI",
                },
                "relationship": {
                    "type": "string",
                    "description": "Relationship field to follow",
                },
                "max_depth": {
                    "type": "number",
                    "default": 2,
                    "minimum": 1,
                    "maximum": 5,
                    "description": "Maximum traversal depth (1-5 hops)",
                },
            },
            "required": ["start_id", "relationship"],
        },
    ),
]

TOOLS.extend(BRAIN_V2_TOOLS)
```

**Tool Handlers:**

```python
# parachute/mcp_server.py (in handle_tool_call function)

# Add at module level (after SessionContext)
_kg_service: Optional[KnowledgeGraphService] = None

async def _ensure_kg_service() -> KnowledgeGraphService:
    """Lazy-load KnowledgeGraphService singleton"""
    global _kg_service
    if _kg_service is None:
        from modules.brain_v2.knowledge_graph import KnowledgeGraphService
        from modules.brain_v2.schema_compiler import SchemaCompiler

        # Load schemas
        schemas_dir = _vault_path / ".brain" / "schemas"
        compiler = SchemaCompiler()
        schemas = await asyncio.to_thread(compiler.compile_all_schemas, schemas_dir)

        # Connect
        _kg_service = KnowledgeGraphService(_vault_path)
        await _kg_service.connect(schemas)

    return _kg_service

# Add to handle_tool_call() function
async def handle_tool_call(name: str, arguments: dict) -> str:
    """Handle MCP tool calls"""

    # ... existing tool handlers ...

    # Brain v2 tools
    elif name == "brain_create_entity":
        # Trust level enforcement
        if _session_context.trust_level == "sandboxed":
            return json.dumps({
                "error": "Permission denied: sandboxed sessions have read-only access to Brain"
            })

        kg = await _ensure_kg_service()
        req = CreateEntityRequest(**arguments)

        try:
            entity_id = await kg.create_entity(
                entity_type=req.entity_type,
                data=req.data,
                commit_msg=req.commit_msg,
            )
            return json.dumps({
                "success": True,
                "entity_id": entity_id,
                "message": f"Created {req.entity_type} entity",
            })
        except Exception as e:
            return json.dumps({
                "error": f"Failed to create entity: {str(e)}",
            })

    elif name == "brain_query_entities":
        kg = await _ensure_kg_service()
        req = QueryEntitiesRequest(**arguments)

        try:
            results = await kg.query_entities(
                entity_type=req.entity_type,
                filters=req.filters,
            )
            return json.dumps({
                "success": True,
                "results": results,
                "count": len(results),
            })
        except Exception as e:
            return json.dumps({
                "error": f"Query failed: {str(e)}",
            })

    elif name == "brain_create_relationship":
        # Trust level enforcement
        if _session_context.trust_level == "sandboxed":
            return json.dumps({
                "error": "Permission denied: sandboxed sessions have read-only access to Brain"
            })

        kg = await _ensure_kg_service()
        req = CreateRelationshipRequest(**arguments)

        try:
            await kg.create_relationship(
                from_id=req.from_id,
                relationship=req.relationship,
                to_id=req.to_id,
            )
            return json.dumps({
                "success": True,
                "message": f"Created relationship: {req.from_id} -> {req.to_id}",
            })
        except Exception as e:
            return json.dumps({
                "error": f"Failed to create relationship: {str(e)}",
            })

    elif name == "brain_traverse_graph":
        kg = await _ensure_kg_service()
        req = TraverseGraphRequest(**arguments)

        try:
            results = await kg.traverse_graph(
                start_id=req.start_id,
                relationship=req.relationship,
                max_depth=req.max_depth,
            )
            return json.dumps({
                "success": True,
                "results": results,
                "count": len(results),
            })
        except Exception as e:
            return json.dumps({
                "error": f"Traversal failed: {str(e)}",
            })

    else:
        return json.dumps({"error": f"Unknown tool: {name}"})
```

**Trust Level Enforcement Pattern:**

Following institutional learnings:
- **CRITICAL**: Use direct assignment for trust context, NOT `setdefault()`
- Session context injected via env vars (`PARACHUTE_TRUST_LEVEL`)
- Sandboxed sessions get read-only access (query only, no creates/updates)
- Vault/Full sessions can create/update entities and relationships

---

#### Phase 1.5: FastAPI Routes

**Tasks:**
- [ ] Create `BrainV2Module` class with router
- [ ] Implement basic CRUD routes for entity management
- [ ] Add routes for relationship creation and graph traversal
- [ ] Register module in server startup
- [ ] Test routes with curl/HTTP client

**Files to create:**
- `modules/brain_v2/module.py`
- `modules/brain_v2/manifest.yaml`

**Files to modify:**
- `parachute/server.py` (module registration)

**Success criteria:**
- Routes registered at `/api/brain_v2/*`
- CRUD operations work via HTTP
- Pydantic validation catches invalid requests
- Responses match expected formats
- Module integrates with existing module loader pattern

**Module Implementation:**

```python
# modules/brain_v2/module.py
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, HTTPException, Depends
from .knowledge_graph import KnowledgeGraphService
from .schema_compiler import SchemaCompiler
from .models import (
    CreateEntityRequest,
    QueryEntitiesRequest,
    CreateRelationshipRequest,
    TraverseGraphRequest,
    Entity,
)

class BrainV2Module:
    """Brain v2 module with TerminusDB knowledge graph"""

    name = "brain_v2"
    provides = ["BrainV2Interface"]

    def __init__(self, vault_path: Path, **kwargs):
        self.vault_path = vault_path
        self.schemas_dir = vault_path / ".brain" / "schemas"

        # Ensure directories exist
        self.schemas_dir.mkdir(parents=True, exist_ok=True)
        (vault_path / ".brain" / "data").mkdir(parents=True, exist_ok=True)
        (vault_path / ".brain" / "exports").mkdir(parents=True, exist_ok=True)

        # Initialize service (lazy-loaded on first request)
        self.kg_service: Optional[KnowledgeGraphService] = None
        self.schemas: list[dict] = []

    async def _ensure_kg_service(self) -> KnowledgeGraphService:
        """Lazy-load KnowledgeGraphService"""
        if self.kg_service is None:
            # Compile schemas
            compiler = SchemaCompiler()
            self.schemas = compiler.compile_all_schemas(self.schemas_dir)

            # Connect to TerminusDB
            self.kg_service = KnowledgeGraphService(self.vault_path)
            await self.kg_service.connect(self.schemas)

        return self.kg_service

    def get_router(self) -> APIRouter:
        """Return FastAPI router for Brain v2 routes"""
        router = APIRouter(prefix="/api/brain_v2", tags=["brain_v2"])

        @router.post("/entities")
        async def create_entity(request: CreateEntityRequest):
            """Create new entity"""
            kg = await self._ensure_kg_service()

            try:
                entity_id = await kg.create_entity(
                    entity_type=request.entity_type,
                    data=request.data,
                    commit_msg=request.commit_msg,
                )
                return {
                    "success": True,
                    "entity_id": entity_id,
                }
            except Exception as e:
                raise HTTPException(status_code=400, detail=str(e))

        @router.get("/entities/{entity_type}")
        async def query_entities(entity_type: str):
            """Query entities by type"""
            kg = await self._ensure_kg_service()

            try:
                results = await kg.query_entities(entity_type)
                return {
                    "success": True,
                    "results": results,
                    "count": len(results),
                }
            except Exception as e:
                raise HTTPException(status_code=400, detail=str(e))

        @router.get("/entities/{entity_type}/{entity_id}")
        async def get_entity(entity_type: str, entity_id: str):
            """Get single entity by ID"""
            kg = await self._ensure_kg_service()

            # Construct IRI
            iri = f"{entity_type}/{entity_id}"
            entity = await kg.get_entity(iri)

            if not entity:
                raise HTTPException(status_code=404, detail="Entity not found")

            return entity

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
                return {
                    "success": True,
                    "message": f"Created relationship: {request.from_id} -> {request.to_id}",
                }
            except Exception as e:
                raise HTTPException(status_code=400, detail=str(e))

        @router.post("/traverse")
        async def traverse_graph(request: TraverseGraphRequest):
            """Traverse graph from starting entity"""
            kg = await self._ensure_kg_service()

            try:
                results = await kg.traverse_graph(
                    start_id=request.start_id,
                    relationship=request.relationship,
                    max_depth=request.max_depth,
                )
                return {
                    "success": True,
                    "results": results,
                    "count": len(results),
                }
            except Exception as e:
                raise HTTPException(status_code=400, detail=str(e))

        return router

    # Interface methods for cross-module access
    async def search_entities(self, query: str) -> list[dict]:
        """Search entities (for InterfaceRegistry)"""
        kg = await self._ensure_kg_service()
        # TODO: Implement full-text search (Phase 2)
        return []
```

**Manifest:**

```yaml
# modules/brain_v2/manifest.yaml
name: brain_v2
version: "0.1.0"
description: "Brain v2: TerminusDB knowledge graph with agent-native interaction"
trust_level: trusted

provides:
  - BrainV2Interface

requires: []

dependencies:
  - terminusdb-client>=10.2.6
  - pyyaml>=6.0
```

---

#### Phase 1.6: Flutter UI (Minimal)

**Tasks:**
- [ ] Create basic entity list screen
- [ ] Create entity creation form
- [ ] Add BrainV2Service for API calls
- [ ] Test round-trip: create entity in UI → query in agent
- [ ] Validate schema validation errors display correctly

**Files to create:**
- `app/lib/features/brain_v2/services/brain_v2_service.dart`
- `app/lib/features/brain_v2/models/entity.dart`
- `app/lib/features/brain_v2/screens/entity_list_screen.dart`
- `app/lib/features/brain_v2/screens/create_entity_screen.dart`

**Success criteria:**
- Can create Person/Project/Note entities via UI
- Can view list of entities by type
- Schema validation errors show in UI
- Changes made in UI visible to agents via MCP tools

**Dart Service:**

```dart
// app/lib/features/brain_v2/services/brain_v2_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/entity.dart';

class BrainV2Service {
  final String baseUrl;

  BrainV2Service({required this.baseUrl});

  Future<String> createEntity({
    required String entityType,
    required Map<String, dynamic> data,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/brain_v2/entities'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'entity_type': entityType,
        'data': data,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to create entity: ${response.body}');
    }

    final result = jsonDecode(response.body);
    return result['entity_id'] as String;
  }

  Future<List<Entity>> queryEntities(String entityType) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/brain_v2/entities/$entityType'),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to query entities: ${response.body}');
    }

    final result = jsonDecode(response.body);
    final List<dynamic> results = result['results'];
    return results.map((json) => Entity.fromJson(json)).toList();
  }

  Future<void> createRelationship({
    required String fromId,
    required String relationship,
    required String toId,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/brain_v2/relationships'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'from_id': fromId,
        'relationship': relationship,
        'to_id': toId,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to create relationship: ${response.body}');
    }
  }
}
```

**Note:** Full Flutter implementation deferred to Phase 2. This is minimal proof-of-concept only.

---

## Acceptance Criteria

### Functional Requirements

- [ ] TerminusDB container starts with Parachute server
- [ ] Data persists across server/container restarts
- [ ] Schemas compile from YAML to TerminusDB format
- [ ] Agent can create Person/Project/Note entities via MCP tools
- [ ] Agent can query entities by type and filters
- [ ] Agent can create relationships between entities
- [ ] Agent can traverse graph following relationships
- [ ] UI can create entities via FastAPI routes
- [ ] UI can view list of entities by type
- [ ] Schema validation rejects invalid entities
- [ ] Trust levels enforce access controls (sandboxed = read-only)

### Non-Functional Requirements

- [ ] No blocking subprocess calls in async context (asyncio.to_thread pattern)
- [ ] Session context injection uses direct assignment (not setdefault)
- [ ] MCP config caching uses shallow copy pattern
- [ ] Container hardening applied (no-new-privileges, cap-drop)
- [ ] All YAML schemas parse without errors on startup
- [ ] FastAPI routes respond within 500ms for typical queries
- [ ] TerminusDB health check passes before server accepts requests

### Quality Gates

- [ ] No P1/P2 security issues from institutional learnings
- [ ] Pydantic models validate all request/response shapes
- [ ] Error messages are clear and actionable
- [ ] Code follows existing module patterns (manifest, router, interface)
- [ ] Dependencies documented in requirements.txt and manifest.yaml

---

## Dependencies & Prerequisites

### External Dependencies

- **TerminusDB v12.0.0** - Docker image `terminusdb/terminusdb-server:v12.0.0`
- **terminusdb-client v10.2.6+** - Python library for TerminusDB interaction
- **PyYAML v6.0+** - YAML parsing for schema definitions
- **Docker Compose** - Already required for sandboxed agents

### Internal Dependencies

- **Module loader** (`parachute/core/module_loader.py`) - Must load Brain v2 module
- **MCP server** (`parachute/mcp_server.py`) - Extended with Brain v2 tools
- **Server lifespan** (`parachute/server.py`) - TerminusDB startup integrated
- **Session context** (`parachute/mcp_server.py:54-84`) - Trust level enforcement

### Prerequisites

- Docker installed and running
- Vault path configured (`VAULT_PATH` env var or `~/.parachute/config.yaml`)
- Port 6363 available for TerminusDB
- Python 3.11+ with asyncio support

---

## Risk Analysis & Mitigation

### High Risk

**Risk:** Blocking subprocess calls freeze FastAPI event loop
- **Impact:** Server hangs, SSE streams stop
- **Mitigation:** Use `asyncio.create_subprocess_exec()` everywhere, never `subprocess.run()` in async context
- **Detection:** Load testing with concurrent requests

**Risk:** Trust level enforcement bypassed via MCP config manipulation
- **Impact:** Sandboxed agents gain write access to graph
- **Mitigation:** Direct assignment of trust context (not setdefault), validate all session context inputs
- **Detection:** Security review, test sandboxed agent restrictions

**Risk:** Schema compilation errors break server startup
- **Impact:** Server won't start if schemas invalid
- **Mitigation:** Schema validation with clear error messages, fallback to empty schema set
- **Detection:** Unit tests for SchemaCompiler, integration tests with invalid schemas

### Medium Risk

**Risk:** TerminusDB container fails to start
- **Impact:** Brain v2 features unavailable
- **Mitigation:** Health check with retries, clear error message to user, graceful degradation
- **Detection:** Server startup logs, health check monitoring

**Risk:** Memory growth from in-memory schema cache
- **Impact:** Server memory usage increases over time
- **Mitigation:** Schemas reloaded on demand, not cached indefinitely
- **Detection:** Memory profiling during long-running tests

**Risk:** Relationship creation creates invalid graph state
- **Impact:** Broken references, traversal failures
- **Mitigation:** Schema validation enforces relationship field existence, bidirectional integrity checks
- **Detection:** Integration tests for relationship creation, graph traversal tests

### Low Risk

**Risk:** YAML schema syntax errors
- **Impact:** Schemas fail to compile on startup
- **Mitigation:** Schema validation, clear error messages, example schemas documented
- **Detection:** Unit tests, schema documentation

**Risk:** Performance degradation with large graphs
- **Impact:** Slow queries, high latency
- **Mitigation:** Defer to Phase 2 (indexing, caching), MVP focuses on small graphs (<1000 entities)
- **Detection:** Load testing with realistic graph sizes

---

## Success Metrics

### Technical Metrics

- **TerminusDB uptime**: >99% during development
- **Query latency**: <500ms for typical queries (MVP: <100 entities)
- **Schema compilation time**: <1s for 10 schemas
- **MCP tool response time**: <1s for create/query operations
- **Server startup time**: <15s including TerminusDB health check

### Functional Metrics

- **Agent success rate**: >90% for valid entity creation requests
- **Schema validation accuracy**: 100% (invalid entities rejected, valid accepted)
- **Graph traversal correctness**: 100% (returns all connected entities up to max_depth)
- **Data persistence**: 100% (no data loss across restarts)

### User Experience Metrics (Phase 2)

- **Entity creation clicks**: <5 clicks from "new entity" to "created"
- **Query result display**: <2s from query to results shown
- **Error message clarity**: User understands what went wrong >80% of time

---

## Future Considerations (Phase 2+)

### User Experience Enhancements

- Slash command interface for entity creation (Notion-style)
- Embedded queries in Daily journal entries
- Schema editor UI for modifying entity types
- Visual graph explorer (optional power feature)
- Live query results (auto-update on graph changes)

### Advanced Features

- Full-text search across entity content
- Natural language query translation (English → WOQL)
- Temporal queries (history/versioning via TerminusDB branches)
- Aggregations and analytics (count relationships, find hubs)
- Export scheduling (real-time vs daily RDF snapshots)
- Migration tool for old Brain markdown entities

### Performance & Scaling

- Query result caching (Redis or in-memory)
- Lazy-loading for large result sets
- Graph indexing for common query patterns
- Connection pooling for TerminusDB client
- Horizontal scaling via TerminusDB push/pull

### Integration

- Chat module context enrichment (query Brain during conversations)
- Daily module auto-linking (suggest entities from journal entries)
- Brain → Brain sync (push/pull graphs between instances)
- Import from Obsidian/Roam (markdown → entities)
- Export to other tools (Notion, Airtable, etc.)

---

## Documentation Plan

### Code Documentation

- [ ] Docstrings for all public methods in `KnowledgeGraphService`
- [ ] Schema YAML format specification with examples
- [ ] MCP tool usage examples in docstrings
- [ ] README.md in `modules/brain_v2/` with quickstart

### User Documentation

- [ ] Brain v2 setup guide (vault structure, schema creation)
- [ ] MCP tool reference (what each tool does, parameters, examples)
- [ ] Schema definition guide (field types, key strategies, relationships)
- [ ] Troubleshooting guide (common errors, solutions)

### Developer Documentation

- [ ] Architecture decision record (why TerminusDB, alternatives considered)
- [ ] Module integration guide (how to consume BrainV2Interface)
- [ ] Testing guide (how to run integration tests)
- [ ] Performance tuning guide (caching, indexing, query optimization)

---

## References & Research

### Internal References

**Architecture Decisions:**
- Brainstorm: `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/docs/brainstorms/2026-02-22-parachute-brain-v2-knowledge-graph-brainstorm.md`
- Module pattern: `computer/modules/brain/module.py:18-162`
- MCP server pattern: `computer/parachute/mcp_server.py:1-1078`
- Sandbox integration: `computer/parachute/core/sandbox.py:464-590`

**Similar Implementations:**
- Existing Brain module: `computer/modules/brain/`
- Chat module structure: `computer/modules/chat/`
- Daily module: `computer/modules/daily/`

**Configuration:**
- Server startup: `computer/parachute/server.py:44-192`
- Module loader: `computer/parachute/core/module_loader.py:72-146`
- Settings: `computer/parachute/config.py:153-202`

**Critical Learnings:**
- Async subprocess pattern: Plan `2026-02-22-feat-rich-sandbox-image-plan-deepened.md`
- MCP session context injection: Plan `2026-02-22-feat-mcp-session-context-injection-plan-enhanced.md`
- Trust level consolidation: Plan `2026-02-21-feat-workspace-sandbox-rework-plan.md`

### External References

**TerminusDB Documentation:**
- Official docs: https://terminusdb.org/docs/
- Python client: https://terminusdb.github.io/terminusdb-client-python/
- Schema reference: https://terminusdb.org/docs/schema-reference-guide/
- WOQL guide: https://terminusdb.org/docs/woql-getting-started/

**Best Practices:**
- TerminusDB Docker install: https://terminusdb.org/docs/install-terminusdb-as-a-docker-container/
- Performance benchmark: https://terminusdb.com/blog/graph-database-performance-benchmark/
- Schema migration: https://terminusdb.org/blog/2023-04-24-schema-migration/

**Python Libraries:**
- terminusdb-client: https://pypi.org/project/terminusdb-client/
- Pydantic: https://docs.pydantic.dev/
- FastAPI: https://fastapi.tiangolo.com/

### Related Work

**GitHub Issues:**
- Issue #94: Brain v2 brainstorm (this plan implements Phase 1)

**Technology Research:**
- TerminusDB vs alternatives: Brainstorm research (Neo4j, Git + RDF, SQLite + custom)
- Async patterns in Python: FastAPI documentation, asyncio best practices
- Schema evolution strategies: TerminusDB schema migration blog post

---

## Implementation Checklist

### Phase 1.1: Docker Setup
- [ ] Create `docker-compose.brain.yml`
- [ ] Add health check logic to `parachute/server.py`
- [ ] Test container lifecycle (start/stop/restart)
- [ ] Verify data persistence across restarts

### Phase 1.2: Schema System
- [ ] Implement `SchemaCompiler` class
- [ ] Create `person.yaml`, `project.yaml`, `note.yaml`
- [ ] Test schema compilation
- [ ] Validate error handling for invalid schemas

### Phase 1.3: Knowledge Graph Service
- [ ] Install `terminusdb-client` dependency
- [ ] Implement `KnowledgeGraphService` with async wrappers
- [ ] Create Pydantic models
- [ ] Test CRUD operations manually

### Phase 1.4: MCP Tools
- [ ] Add Brain v2 tools to `mcp_server.py`
- [ ] Implement tool handlers
- [ ] Add trust level enforcement
- [ ] Test with MCP inspector or agent

### Phase 1.5: FastAPI Routes
- [ ] Create `BrainV2Module` class
- [ ] Implement router with CRUD endpoints
- [ ] Register module in server
- [ ] Test routes with curl

### Phase 1.6: Flutter UI (Minimal)
- [ ] Create `BrainV2Service` Dart client
- [ ] Create entity models
- [ ] Create basic list/create screens
- [ ] Test round-trip (UI → API → TerminusDB → Agent)

### Testing & Validation
- [ ] Integration test: Create entity via MCP tool
- [ ] Integration test: Query entities via API
- [ ] Integration test: Create relationship via MCP tool
- [ ] Integration test: Traverse graph via API
- [ ] Security test: Sandboxed session cannot write
- [ ] Performance test: Query latency <500ms
- [ ] Stability test: Server restarts preserve data

---

## Next Steps

After Phase 1 MVP is complete and validated:

1. **User testing** - Get feedback on agent interaction patterns, schema design
2. **Performance profiling** - Identify bottlenecks, optimize queries
3. **Phase 2 planning** - Prioritize UX enhancements vs advanced features
4. **Documentation** - Write user guide, schema tutorial, troubleshooting FAQ
5. **Integration** - Connect Brain v2 with Chat (context enrichment) and Daily (auto-linking)
