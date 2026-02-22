---
status: pending
priority: p3
issue_id: 94
tags: [code-review, agent-native, brain-v2, enhancement]
dependencies: []
---

# Brain v2: MCP Tools for Agent-Native Access (Phase 2)

## Problem Statement

Brain v2 is currently UI-only (FastAPI routes). None of the 7 CRUD operations are accessible to agents via MCP tools, scoring 0/7 on agent-native capabilities.

**Why it matters:** Parachute's core principle is "agent-native architecture" - anything a user can do, an agent should be able to do. Chat and Daily modules provide MCP tools for their functionality; Brain v2 should follow this pattern.

## Findings

**Source:** agent-native-reviewer agent (confidence: 100/100)

**Capabilities requiring MCP tools:**
1. ❌ Create entity (POST /entities)
2. ❌ Query entities (GET /entities/{type})
3. ❌ Get specific entity (GET /entities/{id})
4. ❌ Update entity (PUT /entities/{id})
5. ❌ Delete entity (DELETE /entities/{id})
6. ❌ Create relationship (POST /relationships)
7. ❌ Traverse graph (POST /traverse)

**Score:** 0/7 (0%) agent-accessible

**Context:**
- README.md line 217 acknowledges: "MCP Tools: Full agent-native CRUD tools" as Phase 2 work
- Plan explicitly deferred this to Phase 1.4 (skipped in favor of 1.5 routes)
- Current implementation is intentionally HTTP-only for MVP

## Proposed Solutions

### Option A: Implement MCP Tools in Phase 2 (Recommended)
**Approach:** Add tools/ directory with 7 MCP tool definitions

**Implementation sketch:**
```python
# computer/modules/brain_v2/tools/create_entity.py
{
    "name": "brain_v2_create_entity",
    "description": "Create a new entity in the knowledge graph",
    "inputSchema": {
        "type": "object",
        "properties": {
            "entity_type": {"type": "string"},
            "data": {"type": "object"},
            "commit_msg": {"type": "string"}
        },
        "required": ["entity_type", "data"]
    }
}

async def execute(params: dict) -> dict:
    # Call KnowledgeGraphService directly
    kg = get_kg_service()
    entity_id = await kg.create_entity(...)
    return {"entity_id": entity_id}
```

**Pros:**
- Achieves 100% agent parity
- Aligns with Parachute architecture principles
- Enables agent-driven knowledge graph workflows
- Reuses existing KnowledgeGraphService logic

**Cons:**
- Requires MCP tool definitions (~350 lines total)
- Testing overhead (7 tools)
- Out of scope for Phase 1 MVP

**Effort:** Large (6-8 hours for all 7 tools + tests)
**Risk:** Low (well-defined pattern)

### Option B: Hybrid Approach (HTTP + MCP Tool Registration)
**Approach:** Register existing HTTP routes as MCP tools via tool descriptor

**Pros:**
- Reuses HTTP implementation
- Faster than full MCP implementation
- Agents can use via HTTP calls

**Cons:**
- Less idiomatic for MCP
- Requires HTTP → MCP adapter
- Still substantial work

**Effort:** Medium (3-4 hours)
**Risk:** Medium

### Option C: Document as Known Limitation
**Approach:** Keep in README.md Phase 2 backlog, defer indefinitely

**Pros:**
- Zero implementation cost
- Matches current MVP scope

**Cons:**
- Brain v2 remains UI-only
- Violates agent-native principle
- Limits agent workflows

**Effort:** None
**Risk:** Low (but architectural debt)

## Recommended Action

(To be filled during triage)

**Suggestion:** Option A for Phase 2 (aligns with roadmap and principles)

## Technical Details

**MCP tool registration pattern** (from chat/daily modules):
```python
# In module.py
def get_mcp_tools(self) -> list[dict]:
    return [
        {
            "name": "brain_v2_create_entity",
            "description": "...",
            "inputSchema": {...},
            "handler": self._handle_create_entity
        },
        # ... 6 more tools
    ]
```

**Affected components:**
- New: `computer/modules/brain_v2/tools/` directory
- Modified: `module.py` to register tools
- Integration: MCP tool registry in orchestrator

**Similar implementations:**
- `computer/modules/chat/tools/` (3 tools)
- `computer/modules/daily/tools/` (5 tools)

## Acceptance Criteria

**For Phase 2 implementation:**
- [ ] 7 MCP tools defined (create, query, get, update, delete, relationship, traverse)
- [ ] Each tool has JSON schema for inputs
- [ ] Tools call KnowledgeGraphService methods (no duplication)
- [ ] Error handling aligns with MCP error format
- [ ] Tools registered in module.get_mcp_tools()
- [ ] Agent can create entity via MCP tool
- [ ] Agent can query entities via MCP tool
- [ ] Agent can traverse graph via MCP tool
- [ ] Documentation updated with MCP tool examples

## Work Log

### 2026-02-22
- **Created:** agent-native-reviewer flagged during /para-review of PR #97
- **Note:** This is expected for Phase 1 MVP; roadmap already includes Phase 2 MCP work

## Resources

- **PR:** #97 (Brain v2 TerminusDB MVP)
- **Review agent:** agent-native-reviewer
- **Roadmap:** README.md:217 (Phase 2: MCP Tools)
- **Plan:** Phase 1.4 deferred in favor of 1.5 routes
- **Pattern:** chat/daily modules for MCP tool examples
- **Architecture:** `.claude/skills/agent-native-architecture/` for principles
