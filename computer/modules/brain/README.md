# Brain - TerminusDB Knowledge Graph

Strongly-typed, version-controlled knowledge graph for Parachute using TerminusDB.

## Overview

Brain provides:
- **Declarative schemas** - YAML schema definitions compiled to TerminusDB
- **Full CRUD operations** - Create, read, update, delete entities with validation
- **Graph relationships** - Link entities and traverse connections
- **Version control** - Git-like versioning via TerminusDB
- **Agent-native** - FastAPI routes for UI and MCP tools for agents
- **Performance** - WOQL-based traversal, pagination, async I/O

## Architecture

```
User/Agent Request
    ↓
FastAPI Route (HTTP) or MCP Tool
    ↓
BrainModule
    ↓
KnowledgeGraphService (async wrapper)
    ↓
terminusdb-client (sync library, wrapped with asyncio.to_thread)
    ↓
TerminusDB Docker Container
    ↓
Binary Storage (vault/.brain/data/)
```

## Quick Start

### 1. Set Admin Password

```bash
# Generate secure password
python -c 'import secrets; print(secrets.token_urlsafe(32))'

# Export for server
export TERMINUSDB_ADMIN_PASS="your-secure-password"
```

### 2. Create Schemas

Create YAML schemas in `~/Parachute/.brain/schemas/`:

```yaml
# person.yaml
name: Person
description: A person entity
key_strategy: Lexical
key_fields:
  - name

fields:
  name:
    type: string
    required: true
  email:
    type: string
    required: false
  company:
    type: string
    required: false
  tags:
    type: array
    items: string
    required: false
```

### 3. Start Server

```bash
cd computer
parachute server -f
```

TerminusDB container starts automatically. Check logs for "TerminusDB ready after Ns".

### 4. Use the API

```bash
# Create entity
curl -X POST http://localhost:3333/api/brain/entities \
  -H "Content-Type: application/json" \
  -d '{
    "entity_type": "Person",
    "data": {
      "name": "Alice",
      "email": "alice@example.com",
      "company": "Acme Corp"
    }
  }'

# Query entities
curl http://localhost:3333/api/brain/entities/Person?limit=10

# Create relationship
curl -X POST http://localhost:3333/api/brain/relationships \
  -H "Content-Type: application/json" \
  -d '{
    "from_id": "Person/Alice",
    "relationship": "related_projects",
    "to_id": "Project/parachute"
  }'

# Traverse graph
curl -X POST http://localhost:3333/api/brain/traverse \
  -H "Content-Type: application/json" \
  -d '{
    "start_id": "Person/Alice",
    "relationship": "related_projects",
    "max_depth": 2
  }'
```

## Schema Format

### Key Strategies

- **Lexical** - Generate IRI from field values (e.g., `Person/Alice`)
- **Random** - Generate UUID-based IRI
- **Hash** - Hash-based IRI from fields
- **ValueHash** - Content-addressed IRI

### Field Types

- `string` - Text field
- `integer` - Whole number
- `boolean` - True/false
- `datetime` - Timestamp (ISO 8601)
- `enum` - Enumerated values (e.g., `status: [active, paused, completed]`)
- `array` - List of items (e.g., `tags: array of string`)
- Entity reference - Link to another entity (e.g., `Person`, `Project`)

### Example Schemas

See `~/Parachute/.brain/schemas/`:
- `person.yaml` - Person entities with email, company, role
- `project.yaml` - Projects with status enum and team members
- `note.yaml` - Notes with linked entities (union types)

## API Routes

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/brain/entities` | Create entity |
| GET | `/api/brain/entities/{type}` | Query entities by type |
| PUT | `/api/brain/entities/{id}` | Update entity |
| DELETE | `/api/brain/entities/{id}` | Delete entity |
| POST | `/api/brain/relationships` | Create relationship |
| POST | `/api/brain/traverse` | Traverse graph |
| GET | `/api/brain/schemas` | List schemas |

All routes support pagination (`limit`, `offset` query parameters).

## Performance Considerations

- **Pagination**: All queries capped at 1000 results maximum
- **Traversal depth**: Graph traversal limited to 5 hops maximum
- **WOQL queries**: Server-side traversal (not N+1 fetches)
- **Async I/O**: Schema compilation uses aiofiles
- **Lazy loading**: Schemas compiled on first request

## Security

- **Docker hardening**: Read-only filesystem, localhost binding, resource limits
- **Schema validation**: Name format, field type validation
- **Input sanitization**: Pydantic strict mode on all requests
- **Trust levels**: (Future) Sandboxed sessions get read-only access
- **No default passwords**: TERMINUSDB_ADMIN_PASS must be set explicitly

## Troubleshooting

### TerminusDB fails to start

```bash
# Check Docker is running
docker info

# Check port 6363 is free
lsof -i :6363

# View TerminusDB logs
docker logs parachute-brain-terminusdb

# Manually start container
cd ~/Parachute
export VAULT_PATH=~/Parachute
docker-compose -f computer/parachute/docker/docker-compose.brain.yml up
```

### Schema compilation errors

```bash
# Check YAML syntax
python -c "import yaml; print(yaml.safe_load(open('~/Parachute/.brain/schemas/person.yaml')))"

# Validate schema name format (alphanumeric + underscore only)
# Invalid: "person-entity", Valid: "Person", "person_entity"
```

### Connection errors

```bash
# Test TerminusDB health
curl http://localhost:6363/api/info

# Check password is set
echo $TERMINUSDB_ADMIN_PASS
```

## Future Enhancements (Phase 2)

- **MCP Tools**: Full agent-native CRUD tools
- **Flutter UI**: Entity list, create, edit screens
- **Full-text search**: Search across entity content
- **Natural language queries**: English → WOQL translation
- **RDF export**: Periodic snapshots for git archival
- **Migration tool**: Import from old Brain markdown entities
- **Temporal queries**: Access historical versions
- **Tana-style features**: Supertags, field inheritance, live queries

## References

- [TerminusDB Documentation](https://terminusdb.com/docs)
- [Python Client](https://github.com/terminusdb/terminusdb-client-python)
- [WOQL Guide](https://terminusdb.com/docs/guides/woql)
- [FastAPI Async](https://fastapi.tiangolo.com/async/)
- [Pydantic v2](https://docs.pydantic.dev/latest/)

---

**Status**: Phase 1 MVP Complete (Backend)
**Issue**: #94
**Plan**: `docs/plans/2026-02-22-feat-brain-v2-terminusdb-mvp-plan-deepened.md`
