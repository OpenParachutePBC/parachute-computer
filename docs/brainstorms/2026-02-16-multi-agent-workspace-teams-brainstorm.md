# Multi-Agent Workspace Teams (Revised)

**Status**: Brainstorm complete, ready for planning
**Builds on**: Issue #35 (original brainstorm)
**Updated**: 2026-02-16 — incorporates PRs #38, #39, #42 (persistent containers, SDK session persistence, bot management)
**Priority**: P2

---

## What We're Building

Enable agents within a Parachute workspace to coordinate by messaging each other, creating sub-sessions, and working as collaborative teams. Transforms Parachute from single-agent sessions into a multi-agent orchestration platform.

**Vision**: An agent working on a complex task can spawn specialist agents, delegate sub-problems, and synthesize results — all within secure workspace boundaries.

---

## What Changed Since the Original Brainstorm

Today's PRs fundamentally change the infrastructure available for multi-agent teams:

| PR | What it adds | Impact on teams |
|----|-------------|-----------------|
| #38 Persistent Docker containers | One persistent container per workspace | All untrusted team agents share the same container — no per-agent container overhead |
| #39 SDK session persistence | `.claude/` directory mounted per workspace | Team agents share SDK session directory; transcripts persist across resume |
| #42 Bot management UX | Inline approve/deny, pending sort, polling badge | Bot sessions can participate in teams; approval UX pattern is reusable |

---

## Key Decisions

### 1. Workspace = Team Boundary (unchanged from original)

Agents can only coordinate within the same workspace. Prevents information leakage across projects.

### 2. Shared Container Model (new)

All untrusted team sessions in a workspace share the same persistent Docker container.

- Agents run as separate `docker exec` processes in the shared container
- Shared filesystem — agents can see each other's file changes
- Efficient: no container overhead per agent
- Security boundary is the workspace, not the agent

### 3. Shared SDK Session Directory (new)

All agents in a workspace share `vault/.parachute/sandbox/{workspace-slug}/.claude/`.

- All transcripts in one place
- Potential file conflicts with simultaneous writes — acceptable risk for now, can add session-id subdirectories later if needed
- Simple: no additional mount configuration

### 4. Session Creation via Chat MCP Tools (new)

Spawned agent sessions must appear as first-class sessions in the SQLite database and the Flutter UI.

**Approach**: Extend existing `parachute.mcp.chat_tools` with a `create_session` tool.

- Creates SQLite record (title, workspace, trust level, parent session)
- Initializes SDK session
- Sessions appear in the app's session list automatically
- Same infrastructure the app uses via REST API

**Why not a separate "team" MCP namespace**: Session creation is a chat concern. Keeping it in chat_tools means one source of truth for session lifecycle.

### 5. Context-Aware MCP Tool Security (new — critical)

**Problem**: MCP tools currently have **no session context**. The built-in parachute MCP runs as a standalone stdio process with only `PARACHUTE_VAULT_PATH`. Tools don't know which session, workspace, or trust level is calling them.

**Decision**: Inject session context via environment variables when spawning the MCP server process.

```
PARACHUTE_SESSION_ID=sess_abc123
PARACHUTE_WORKSPACE_ID=my-project
PARACHUTE_TRUST_LEVEL=untrusted
```

**Why this approach**:
- Env vars are set by the orchestrator, not the agent — can't be manipulated
- Fits existing stdio MCP model (process spawned per session by SDK)
- Tool implementation reads env vars to enforce constraints
- Invisible to the agent (clean API, security is non-negotiable)

**Enforcement rules** (in tool implementation):
- `create_session` inherits workspace from `PARACHUTE_WORKSPACE_ID` (can't create in other workspaces)
- `create_session` inherits trust level <= `PARACHUTE_TRUST_LEVEL` (can't escalate)
- `send_message` can only target sessions in same workspace
- Untrusted sessions can only message other untrusted sessions

### 6. Trust Level Enforcement (refined from original)

| From Session | Can Create | Can Message |
|--------------|-----------|-------------|
| Trusted | Trusted or Untrusted | Any in workspace |
| Untrusted | Untrusted only | Untrusted only |

This is now enforced via env-var context (Decision 5), not just tool-level parameter validation.

---

## Open Questions (for planning phase)

### Bookmarked: MCP Module Security Model

The env-var context injection (Decision 5) is a foundational change that affects all MCP tools, not just team-related ones. This needs careful design:

- How does the orchestrator pass context when spawning stdio MCP processes?
- Does the SDK support per-session env vars for MCP servers, or do we need a wrapper?
- Should all built-in MCP tools become context-aware, or just new team tools?
- How do we test that context enforcement actually prevents escalation?

### Session UI for Teams

- How do spawned sessions appear in the session list? Nested under parent? Separate with a "spawned by" indicator?
- Do spawned sessions get a special visual treatment (like bot sessions)?
- Can users interact with spawned sessions directly, or only through the coordinator?

### Lifecycle Management

- When a parent session ends, what happens to spawned children?
- Should there be a spawn limit per workspace? (Original brainstorm suggested max 10)
- How do we prevent runaway agent spawning?

### Message Delivery

- Direct injection into recipient's context vs. message queue?
- Original brainstorm recommended direct for MVP, queue if latency issues arise
- With shared container, could agents also coordinate via shared filesystem? (Should we discourage this?)

---

## Architecture Sketch

### New/Modified Files

```
computer/parachute/
├── mcp_server.py              # Add create_session, send_message, list_workspace_sessions tools
├── lib/mcp_loader.py          # Inject session context env vars when spawning MCP
├── core/orchestrator.py       # Pass session context to MCP loader
├── core/capability_filter.py  # (existing) Trust level filtering still applies
└── models/session.py          # Add parent_session_id, created_by fields
```

### Database Schema Additions

```python
class Session(SQLModel, table=True):
    # ... existing fields ...
    parent_session_id: Optional[str] = None  # Session that spawned this one
    created_by: Optional[str] = None         # 'user' or 'agent:{session_id}'
```

### MCP Tool Additions

```python
# create_session — creates child session in caller's workspace
create_session(title: str, agent_name: str, initial_message: str) -> SessionInfo
# workspace + trust_level inherited from env vars

# send_message — inter-session messaging
send_message(session_id: str, message: str) -> DeliveryStatus
# validates recipient is in same workspace, respects trust rules

# list_workspace_sessions — discover team members
list_workspace_sessions() -> list[SessionInfo]
# workspace scoped via env var, only shows sessions caller can see
```

---

## Phased Rollout (revised)

### Phase 1: MCP Context Foundation
- Inject session context env vars into MCP server spawning
- Context-aware enforcement in tool implementations
- No new tools yet — just the security plumbing

### Phase 2: Session Spawning & Messaging
- `create_session` MCP tool (creates DB record + SDK session)
- `send_message` MCP tool (inter-session messaging)
- `list_workspace_sessions` MCP tool
- Parent-child relationship in SQLite

### Phase 3: App UI
- Spawned sessions visible in session list
- Parent-child visual relationship
- Team activity indicators

### Phase 4: Advanced Coordination
- Broadcast messaging
- Rate limiting and spawn limits
- Session lifecycle management (parent ends → children cleanup)

---

## Related Issues

- #23: Bot Management (completed — PR #42, approval UX pattern reusable for team sessions)
- #26: Sandbox Session Persistence (completed — PR #39, shared `.claude/` directory)
- #33: Persistent Docker Containers (completed — PR #38, shared container model)
- #34: Intelligent Cost Optimization (model routing could apply to spawned agents)

## Next Steps

1. Run `/para-plan` to create detailed implementation plan starting from Phase 1
2. Phase 1 (MCP context) is the foundational prerequisite — plan that first
