---
status: pending
priority: p2
issue_id: 100
tags: [code-review, agent-native, mcp, architecture]
dependencies: [002]
---

# Missing MCP Tools: Agent-Native Accessibility Gap

## Problem Statement

The Brain v2 UI has no corresponding MCP tools, meaning agents cannot perform any Brain v2 operations programmatically. This violates the agent-native architecture principle that "anything a user can do, an agent can do."

**Impact**: Agents cannot create, read, update, or delete Brain v2 entities. Workflows requiring Brain v2 operations must involve manual user intervention. Parachute's "agent-first" vision is compromised for the knowledge graph module.

## Findings

**Source**: agent-native-reviewer agent
**Confidence**: 98
**Locations**:
- Missing: `computer/modules/brain_v2/tools/` directory
- Reference: `computer/modules/brain/tools/` (Brain v1 has MCP tools)
- Reference: `computer/modules/chat/tools/` (Chat has MCP tools)

**Evidence**:
Brain v2 module structure:
```
computer/modules/brain_v2/
├── module.py           # HTTP endpoints only
├── models.py
└── terminusdb_client.py
# NO tools/ directory
```

Compare to Brain v1 (has MCP tools):
```
computer/modules/brain/
├── module.py
├── models.py
└── tools/
    ├── create_memory_tool.py
    ├── search_memories_tool.py
    └── ...
```

**User Capabilities vs Agent Capabilities**:
| Action | User (UI) | Agent (MCP) |
|--------|-----------|-------------|
| List entities | ✅ | ❌ |
| View entity | ✅ | ❌ |
| Create entity | ✅ | ❌ |
| Update entity | ✅ | ❌ |
| Delete entity | ✅ | ❌ |
| Search entities | ✅ | ❌ |

## Proposed Solutions

### Option 1: Create MCP tools for all CRUD operations (Recommended)
**Implementation**:

```python
# computer/modules/brain_v2/tools/list_entities_tool.py
from mcp.types import Tool, TextContent

async def list_entities(entity_type: str = None) -> list[TextContent]:
    """List entities from Brain v2 knowledge graph.

    Args:
        entity_type: Optional filter by entity type/schema

    Returns:
        List of entities with IDs and display names
    """
    client = get_db_client()
    query = build_list_query(entity_type)
    results = await client.query(query)
    return format_entity_list(results)

TOOL = Tool(
    name="brain_v2_list_entities",
    description="List entities from Brain v2 knowledge graph",
    inputSchema={
        "type": "object",
        "properties": {
            "entity_type": {"type": "string", "description": "Filter by entity type"},
        },
    },
)
```

Additional tools needed:
- `brain_v2_get_entity` - View entity details
- `brain_v2_create_entity` - Create new entity
- `brain_v2_update_entity` - Update existing entity
- `brain_v2_delete_entity` - Delete entity
- `brain_v2_search_entities` - Full-text search
- `brain_v2_list_schemas` - List available entity types

**Pros**:
- Full agent-native parity with UI
- Enables autonomous Brain v2 workflows
- Standard MCP integration pattern
- Agents can manage knowledge graph

**Cons**:
- Requires ~6-8 hours to implement all tools
- Depends on backend endpoints existing (see #002)

**Effort**: Large (6-8 hours for all tools)
**Risk**: Low

**Dependencies**: Requires #002 (missing backend endpoint) to be fixed first

### Option 2: Single unified brain_v2 tool with action parameter
**Implementation**:
```python
async def brain_v2(
    action: Literal["list", "get", "create", "update", "delete", "search"],
    entity_type: str = None,
    entity_id: str = None,
    data: dict = None,
    query: str = None,
) -> list[TextContent]:
    """Unified Brain v2 tool for all operations."""
    if action == "list":
        return await _list_entities(entity_type)
    elif action == "get":
        return await _get_entity(entity_id)
    # ... etc
```

**Pros**:
- Single tool to implement
- Simpler MCP registration
- Faster to build

**Cons**:
- Less discoverable for agents
- Complex parameter validation
- Harder to document
- Non-standard pattern (other modules use separate tools)

**Effort**: Medium (3-4 hours)
**Risk**: Low

### Option 3: Expose HTTP API via generic http_request tool
**Implementation**: Agents use generic HTTP tool to call Brain v2 endpoints

**Pros**:
- No new tools needed
- Flexibility

**Cons**:
- Not agent-friendly (agents must know endpoints)
- No type safety
- Violates abstraction principle
- Poor discoverability

**Effort**: Small (0 hours - already possible)
**Risk**: High (bad UX for agents)

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- Create: `computer/modules/brain_v2/tools/` directory
- Create: 6-8 tool files for CRUD operations
- Modify: `computer/modules/brain_v2/module.py` to register MCP tools

**Affected Components**:
- Brain v2 module (add MCP tool layer)
- Agent workflows using Brain v2
- MCP server registration

**Tool Architecture**:
```
Agent Request → MCP Server → Brain v2 Tools → TerminusDB Client → Database
                                ↓
                     HTTP Endpoints (for UI) can share same service layer
```

**Database Changes**: None (tools call existing backend)

**API Changes**: None for HTTP API, new MCP tools added

## Acceptance Criteria

- [ ] All CRUD operations have corresponding MCP tools
- [ ] Tools follow MCP specification with proper schemas
- [ ] Agents can list, view, create, update, delete entities via tools
- [ ] Tool responses include proper error handling
- [ ] Documentation added for each tool
- [ ] Integration test: Agent creates entity → reads it back → updates → deletes
- [ ] Parity check: Any UI action has equivalent MCP tool path

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: No MCP tools for Brain v2, violates agent-native architecture
- **Source**: agent-native-reviewer agent (confidence: 98)
- **Dependency**: Blocked by #002 (missing backend endpoint)
- **Pattern**: Brain v1 has MCP tools, Brain v2 should too

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Related Issue**: #98 - Implement Brain v2 Flutter UI
- **Dependency**: #002 - Missing backend API endpoint
- **MCP Specification**: https://spec.modelcontextprotocol.io/
- **Reference Implementation**: `computer/modules/brain/tools/` (Brain v1)
- **Agent-Native Principle**: See `.claude/skills/agent-native-architecture/SKILL.md`
