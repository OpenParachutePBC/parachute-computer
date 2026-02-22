---
title: feat: Multi-Agent Workspace Teams - MCP Tools for Session Spawning & Messaging
type: feat
date: 2026-02-22
issue: 35
priority: P2
prerequisite: 47
---

# Multi-Agent Workspace Teams - MCP Tools for Session Spawning & Messaging

**Priority**: P2
**Builds on**: #47 (MCP session context injection - merged)
**Status**: Ready for implementation

---

## Overview

Enable agents within a Parachute workspace to coordinate by creating child sessions and sending inter-session messages. This transforms Parachute from single-agent sessions into a multi-agent orchestration platform where a coordinating agent can spawn specialists, delegate sub-problems, and synthesize results.

**Core capability**: MCP tools (`create_session`, `send_message`, `list_workspace_sessions`) that enforce workspace boundaries and trust level constraints using the session context injected by #47.

---

## Problem Statement

Agents currently operate in isolation with no ability to:
- Spawn child agents for parallel work
- Delegate specialized tasks to domain-specific agents
- Coordinate results from multiple sub-tasks
- Message other active sessions in the workspace

**Example blocked use case**: A coordinator agent working on "build a REST API" cannot spawn separate agents for:
- Backend implementation (Python specialist)
- OpenAPI spec generation (documentation specialist)
- Integration tests (testing specialist)

Each would need to be a manual user-initiated session, defeating the purpose of autonomous coordination.

---

## Proposed Solution

Implement three MCP tools in the built-in `parachute` MCP server that enable workspace-scoped multi-agent coordination:

### 1. `create_session` Tool

Creates a child session within the caller's workspace:

```python
create_session(
    title: str,           # Session title (e.g., "Backend API Implementation")
    agent_name: str,      # Agent to run (e.g., "python-specialist")
    initial_message: str  # First message to the spawned agent
) -> SessionInfo
```

**Behavior**:
- Creates SQLite session record with `parent_session_id` set to caller
- Inherits workspace from `PARACHUTE_WORKSPACE_ID` env var
- Inherits trust level from `PARACHUTE_TRUST_LEVEL` (cannot escalate)
- Initializes SDK session in shared `.claude/` directory
- Returns session ID for messaging

### 2. `send_message` Tool

Injects a message into a running session's event stream:

```python
send_message(
    session_id: str,  # Target session (must be in same workspace)
    message: str      # Message content
) -> DeliveryStatus
```

**Behavior**:
- Validates recipient is in same workspace (via `PARACHUTE_WORKSPACE_ID`)
- Enforces trust rules (untrusted cannot message trusted)
- Injects message via orchestrator's `inject_message` mechanism
- Returns delivery confirmation

### 3. `list_workspace_sessions` Tool

Discovers active sessions in the workspace:

```python
list_workspace_sessions() -> list[SessionInfo]
```

**Behavior**:
- Scoped to `PARACHUTE_WORKSPACE_ID` from env var
- Filters by trust level (untrusted cannot see trusted sessions)
- Returns session ID, title, agent name, created time, parent ID

---

## Architecture

### Session Context Flow (Built on #47)

```
┌──────────────────────────────────────────────────────────────┐
│ Orchestrator (run_streaming)                                 │
│                                                               │
│ 1. After trust filtering (line 659):                         │
│    Inject session context into resolved_mcps env:            │
│    - PARACHUTE_SESSION_ID=sess_abc123                        │
│    - PARACHUTE_WORKSPACE_ID=my-project                       │
│    - PARACHUTE_TRUST_LEVEL=sandboxed                         │
│                                                               │
│ 2. Pass resolved_mcps to SDK                                 │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ Claude SDK (spawns MCP server process)                       │
│                                                               │
│ Subprocess environment includes:                             │
│ - PARACHUTE_SESSION_ID                                       │
│ - PARACHUTE_WORKSPACE_ID                                     │
│ - PARACHUTE_TRUST_LEVEL                                      │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ mcp_server.py (this PR's changes)                            │
│                                                               │
│ 1. Read context from env vars at startup (main):             │
│    _session_context = SessionContext.from_env()              │
│                                                               │
│ 2. Tools use context for enforcement:                        │
│    - create_session: inherit workspace + trust               │
│    - send_message: validate same workspace                   │
│    - list_workspace_sessions: filter by workspace            │
└──────────────────────────────────────────────────────────────┘
```

### Database Schema Changes

Add parent-child session tracking:

```python
# models/session.py - Session model additions
class Session(SQLModel, table=True):
    # ... existing fields ...
    parent_session_id: Optional[str] = Field(default=None, index=True)
    created_by: str = Field(default="user")  # "user" or "agent:sess_xyz"
```

**Migration**: SQLAlchemy auto-migration via `create_all()` adds nullable columns.

### Trust Level Enforcement Matrix

| Caller Trust | Can Create | Can Message | Can See |
|--------------|-----------|-------------|---------|
| `direct` | direct or sandboxed | Any in workspace | All in workspace |
| `sandboxed` | sandboxed only | sandboxed only | sandboxed only |

**Enforcement point**: MCP tools read `PARACHUTE_TRUST_LEVEL` and reject operations that violate rules.

---

## Implementation Plan

### Phase 1: Session Context Reading in MCP Server

**File**: `computer/parachute/mcp_server.py`

**Add SessionContext dataclass** (deferred from #47):

```python
from dataclasses import dataclass
import os

@dataclass(frozen=True, slots=True)
class SessionContext:
    """Immutable session context injected by orchestrator via env vars."""
    session_id: str | None
    workspace_id: str | None
    trust_level: str | None

    @classmethod
    def from_env(cls) -> "SessionContext":
        return cls(
            session_id=os.getenv("PARACHUTE_SESSION_ID"),
            workspace_id=os.getenv("PARACHUTE_WORKSPACE_ID"),
            trust_level=os.getenv("PARACHUTE_TRUST_LEVEL"),
        )

    @property
    def is_available(self) -> bool:
        """Check if session context is fully populated."""
        return all([self.session_id, self.workspace_id, self.trust_level])

# Module-level singleton
_session_context: SessionContext | None = None
```

**Initialize in main()** (around line 668-694):

```python
def main() -> None:
    parser = argparse.ArgumentParser(description="Parachute MCP Server")
    parser.add_argument("vault_path", nargs="?", default=None)
    args = parser.parse_args()

    vault_path = args.vault_path or os.environ.get("PARACHUTE_VAULT_PATH")
    if not vault_path:
        print("Error: Vault path required", file=sys.stderr)
        sys.exit(1)
    if not Path(vault_path).exists():
        print(f"Error: Vault path does not exist: {vault_path}", file=sys.stderr)
        sys.exit(1)

    # Initialize session context from env vars
    global _session_context
    _session_context = SessionContext.from_env()

    if _session_context.is_available:
        logger.info(
            f"Session context: session={_session_context.session_id[:8]}, "
            f"workspace={_session_context.workspace_id}, "
            f"trust={_session_context.trust_level}"
        )
    else:
        logger.warning("MCP server started without session context (legacy mode)")

    asyncio.run(run_server(vault_path))
```

**Acceptance criteria**:
- [ ] SessionContext dataclass added with `from_env()` factory
- [ ] `_session_context` initialized in `main()` before server starts
- [ ] Log message confirms context availability
- [ ] No errors when context is missing (legacy mode)

---

### Phase 2: `create_session` MCP Tool

**File**: `computer/parachute/mcp_server.py`

**Add tool definition** (around line 253, after existing tools):

```python
@mcp_server.tool()
async def create_session(
    title: str,
    agent_name: str,
    initial_message: str,
) -> dict[str, Any]:
    """
    Create a child session in the current workspace.

    The new session inherits workspace and trust level from the caller.
    Cannot escalate trust level or create sessions in other workspaces.

    Args:
        title: Human-readable session title (e.g., "API Implementation")
        agent_name: Agent to run (e.g., "python-specialist", "default")
        initial_message: First message sent to the spawned agent

    Returns:
        {"session_id": str, "workspace_id": str, "trust_level": str}

    Raises:
        ValueError: If session context unavailable or agent doesn't exist
    """
    if not _session_context or not _session_context.is_available:
        raise ValueError("Session context not available - cannot create child sessions")

    # Inherit workspace and trust from caller (cannot override)
    workspace_id = _session_context.workspace_id
    trust_level = _session_context.trust_level

    # Validate agent exists
    agent_path = _vault_path / workspace_id / "Agents" / f"{agent_name}.md"
    if not agent_path.exists():
        # Try vault-level agent
        agent_path = _vault_path / "Agents" / f"{agent_name}.md"
        if not agent_path.exists():
            raise ValueError(f"Agent not found: {agent_name}")

    # Create session via database
    from parachute.models.session import SessionCreate, TrustLevel
    from parachute.db.database import Database

    db = Database(_vault_path / ".parachute" / "sessions.db")

    # Map trust level string to enum
    trust_enum = TrustLevel.DIRECT if trust_level == "direct" else TrustLevel.SANDBOXED

    session_data = SessionCreate(
        agent_path=str(agent_path),
        agent_name=agent_name,
        title=title,
        workspace_id=workspace_id,
        trust_level=trust_enum,
        source="agent",
    )

    new_session = db.create_session(session_data)

    # Set parent relationship and created_by
    db.update_session(
        new_session.id,
        parent_session_id=_session_context.session_id,
        created_by=f"agent:{_session_context.session_id}",
    )

    logger.info(
        f"Created child session {new_session.id[:8]} "
        f"(parent={_session_context.session_id[:8]}, "
        f"workspace={workspace_id}, agent={agent_name})"
    )

    # TODO: Send initial message via send_message tool
    # For now, return session info - caller can send message separately

    return {
        "session_id": new_session.id,
        "workspace_id": workspace_id,
        "trust_level": trust_level,
        "title": title,
        "agent_name": agent_name,
    }
```

**Acceptance criteria**:
- [ ] Tool creates session with correct parent relationship
- [ ] Workspace and trust level inherited from caller
- [ ] Agent validation checks workspace-scoped and vault-level agents
- [ ] Returns session ID for subsequent messaging
- [ ] Logs child session creation

---

### Phase 3: `send_message` MCP Tool

**File**: `computer/parachute/mcp_server.py`

**Add tool definition**:

```python
@mcp_server.tool()
async def send_message(
    session_id: str,
    message: str,
) -> dict[str, str]:
    """
    Send a message to another session in the same workspace.

    Enforces workspace boundaries and trust level rules:
    - Can only message sessions in the same workspace
    - Sandboxed sessions cannot message direct sessions

    Args:
        session_id: Target session ID
        message: Message content to inject

    Returns:
        {"status": "delivered", "session_id": str}

    Raises:
        ValueError: If target session invalid or access denied
    """
    if not _session_context or not _session_context.is_available:
        raise ValueError("Session context not available - cannot send messages")

    # Validate target session exists and is in same workspace
    from parachute.db.database import Database

    db = Database(_vault_path / ".parachute" / "sessions.db")
    target_session = db.get_session(session_id)

    if not target_session:
        raise ValueError(f"Target session not found: {session_id}")

    # Enforce workspace boundary
    if target_session.workspace_id != _session_context.workspace_id:
        raise ValueError(
            f"Cannot message session in different workspace "
            f"(caller={_session_context.workspace_id}, "
            f"target={target_session.workspace_id})"
        )

    # Enforce trust level rules
    caller_trust = _session_context.trust_level
    target_trust = target_session.trust_level.value

    if caller_trust == "sandboxed" and target_trust == "direct":
        raise ValueError("Sandboxed sessions cannot message direct sessions")

    # Inject message via orchestrator
    # Use the inject_message API endpoint
    import httpx
    from parachute.config import get_settings

    settings = get_settings()
    base_url = f"http://{settings.host}:{settings.port}"

    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"{base_url}/api/chat/{session_id}/inject",
            json={"content": message},
            timeout=5.0,
        )
        response.raise_for_status()

    logger.info(
        f"Message delivered: {_session_context.session_id[:8]} -> {session_id[:8]}"
    )

    return {
        "status": "delivered",
        "session_id": session_id,
    }
```

**Acceptance criteria**:
- [ ] Validates target session exists
- [ ] Enforces workspace boundary (same workspace only)
- [ ] Enforces trust rules (sandboxed cannot message direct)
- [ ] Uses existing `/api/chat/{session_id}/inject` endpoint
- [ ] Returns delivery confirmation

---

### Phase 4: `list_workspace_sessions` MCP Tool

**File**: `computer/parachute/mcp_server.py`

**Add tool definition**:

```python
@mcp_server.tool()
async def list_workspace_sessions() -> list[dict[str, Any]]:
    """
    List all active sessions in the current workspace.

    Filtered by trust level:
    - Direct sessions see all sessions in workspace
    - Sandboxed sessions only see other sandboxed sessions

    Returns:
        List of session info dicts with:
        - session_id: Session identifier
        - title: Session title
        - agent_name: Agent name
        - created_at: ISO timestamp
        - parent_session_id: Parent session (if spawned)
        - trust_level: direct or sandboxed
    """
    if not _session_context or not _session_context.is_available:
        raise ValueError("Session context not available")

    from parachute.db.database import Database

    db = Database(_vault_path / ".parachute" / "sessions.db")

    # Get all sessions in workspace
    all_sessions = db.list_sessions(
        workspace_id=_session_context.workspace_id,
        archived=False,
    )

    # Filter by trust level visibility
    caller_trust = _session_context.trust_level

    visible_sessions = []
    for session in all_sessions:
        session_trust = session.trust_level.value

        # Direct sessions see everything, sandboxed only see sandboxed
        if caller_trust == "direct" or session_trust == "sandboxed":
            visible_sessions.append({
                "session_id": session.id,
                "title": session.title,
                "agent_name": session.agent_name or "default",
                "created_at": session.created_at.isoformat(),
                "parent_session_id": session.parent_session_id,
                "trust_level": session_trust,
            })

    return visible_sessions
```

**Acceptance criteria**:
- [ ] Returns sessions filtered by workspace
- [ ] Enforces trust visibility (sandboxed cannot see direct)
- [ ] Includes parent_session_id for spawned sessions
- [ ] Returns active sessions only (not archived)

---

### Phase 5: Database Schema Migration

**File**: `computer/parachute/models/session.py`

**Add fields to Session model** (around line 125-208):

```python
class Session(SQLModel, table=True):
    """Session model."""

    __tablename__ = "sessions"
    __table_args__ = (
        Index("ix_sessions_workspace_id", "workspace_id"),
        Index("ix_sessions_parent_session_id", "parent_session_id"),  # NEW
        Index("ix_sessions_created_at", "created_at"),
        Index("ix_sessions_archived", "archived"),
    )

    # ... existing fields ...

    # Multi-agent coordination fields
    parent_session_id: Optional[str] = Field(
        default=None,
        index=True,
        description="Session that spawned this one (if agent-created)",
    )
    created_by: str = Field(
        default="user",
        description="Session creator: 'user' or 'agent:<session_id>'",
    )
```

**File**: `computer/parachute/db/database.py`

**Add update_session method** (around line 549, after get_session):

```python
def update_session(
    self,
    session_id: str,
    **updates: Any,
) -> Session | None:
    """
    Update session fields.

    Args:
        session_id: Session to update
        **updates: Field updates (parent_session_id, created_by, etc.)

    Returns:
        Updated session or None if not found
    """
    with self.get_session_local() as session:
        db_session = session.get(Session, session_id)
        if not db_session:
            return None

        for key, value in updates.items():
            if hasattr(db_session, key):
                setattr(db_session, key, value)

        session.add(db_session)
        session.commit()
        session.refresh(db_session)
        return db_session
```

**Acceptance criteria**:
- [ ] `parent_session_id` field added to Session model
- [ ] `created_by` field added with default "user"
- [ ] Index created for `parent_session_id`
- [ ] `update_session` method supports setting parent relationship
- [ ] Migration handled automatically by SQLModel

---

## Testing Strategy

### Unit Tests

**File**: `computer/tests/mcp/test_session_tools.py` (NEW)

```python
"""Unit tests for MCP session coordination tools."""
import pytest
from unittest.mock import Mock, patch, AsyncMock
from pathlib import Path


@pytest.fixture
def mock_session_context():
    """Mock session context for testing."""
    with patch("parachute.mcp_server._session_context") as ctx:
        ctx.session_id = "test_sess_parent"
        ctx.workspace_id = "test-workspace"
        ctx.trust_level = "sandboxed"
        ctx.is_available = True
        yield ctx


@pytest.fixture
def mock_vault(tmp_path: Path):
    """Create minimal vault structure."""
    vault = tmp_path / "vault"
    vault.mkdir()

    # Create workspace agents directory
    ws_agents = vault / "test-workspace" / "Agents"
    ws_agents.mkdir(parents=True)
    (ws_agents / "specialist.md").write_text("# Specialist Agent")

    # Create vault-level agents directory
    vault_agents = vault / "Agents"
    vault_agents.mkdir()
    (vault_agents / "default.md").write_text("# Default Agent")

    return vault


class TestCreateSession:
    """Tests for create_session tool."""

    def test_creates_child_session_with_parent_relationship(
        self, mock_session_context, mock_vault
    ):
        """Child session inherits workspace/trust and sets parent."""
        # Test that create_session:
        # - Creates DB record
        # - Sets parent_session_id
        # - Sets created_by = "agent:<parent_id>"
        # - Inherits workspace and trust
        pass

    def test_validates_agent_exists(self, mock_session_context, mock_vault):
        """Raises error if agent not found."""
        pass

    def test_cannot_create_without_context(self):
        """Raises error if session context unavailable."""
        pass

    def test_workspace_scoped_agent_discovery(
        self, mock_session_context, mock_vault
    ):
        """Finds agents in workspace/Agents first, then vault/Agents."""
        pass


class TestSendMessage:
    """Tests for send_message tool."""

    @pytest.mark.asyncio
    async def test_delivers_message_to_same_workspace(
        self, mock_session_context
    ):
        """Message delivered if target in same workspace."""
        pass

    @pytest.mark.asyncio
    async def test_blocks_cross_workspace_messaging(
        self, mock_session_context
    ):
        """Raises error if target in different workspace."""
        pass

    @pytest.mark.asyncio
    async def test_sandboxed_cannot_message_direct(
        self, mock_session_context
    ):
        """Sandboxed session cannot message direct session."""
        pass

    @pytest.mark.asyncio
    async def test_direct_can_message_sandboxed(
        self, mock_session_context
    ):
        """Direct session can message sandboxed session."""
        pass


class TestListWorkspaceSessions:
    """Tests for list_workspace_sessions tool."""

    @pytest.mark.asyncio
    async def test_filters_by_workspace(self, mock_session_context):
        """Only returns sessions in caller's workspace."""
        pass

    @pytest.mark.asyncio
    async def test_sandboxed_cannot_see_direct(
        self, mock_session_context
    ):
        """Sandboxed sessions filtered from sandboxed caller's view."""
        pass

    @pytest.mark.asyncio
    async def test_direct_sees_all(self, mock_session_context):
        """Direct sessions see both direct and sandboxed."""
        pass

    @pytest.mark.asyncio
    async def test_includes_parent_session_id(
        self, mock_session_context
    ):
        """Spawned sessions include parent_session_id."""
        pass
```

### Integration Tests

**File**: `computer/tests/integration/test_multi_agent_workflow.py` (NEW)

```python
"""Integration tests for multi-agent coordination."""
import pytest


@pytest.mark.asyncio
async def test_coordinator_spawns_and_messages_child():
    """
    End-to-end test of multi-agent workflow:
    1. Parent session creates child via create_session
    2. Parent sends message to child via send_message
    3. Child receives message in its event stream
    4. Parent lists sessions and sees child
    """
    pass


@pytest.mark.asyncio
async def test_child_inherits_workspace_and_trust():
    """
    Verify inheritance:
    1. Parent in workspace 'proj' with trust 'sandboxed'
    2. Creates child session
    3. Child has workspace='proj', trust='sandboxed'
    4. Child cannot create direct session (escalation blocked)
    """
    pass


@pytest.mark.asyncio
async def test_workspace_isolation():
    """
    Verify sessions in different workspaces cannot interact:
    1. Session A in workspace 'proj1'
    2. Session B in workspace 'proj2'
    3. A cannot message B (cross-workspace blocked)
    4. A's list_workspace_sessions doesn't show B
    """
    pass
```

---

## Security Analysis

### Threat Model

| Threat | Mitigation | Verification |
|--------|-----------|--------------|
| **Trust escalation** | Inherit trust from `PARACHUTE_TRUST_LEVEL`, no override | Unit test: sandboxed cannot create direct |
| **Workspace boundary violation** | All tools enforce `PARACHUTE_WORKSPACE_ID` match | Integration test: cross-workspace blocked |
| **Unauthorized messaging** | Trust rules + workspace checks in send_message | Unit test: sandboxed→direct blocked |
| **Information leakage** | list_sessions filters by trust visibility | Unit test: sandboxed cannot see direct |
| **Spawn bomb** | Not addressed in MVP (defer to Phase 4) | Future: rate limiting + max children |
| **Context spoofing** | Env vars set by orchestrator, not agent | Verified by #47 implementation |

### Trust Level Matrix (Enforcement)

```python
# In create_session tool
if _session_context.trust_level == "sandboxed":
    # Can only create sandboxed sessions (no escalation)
    trust_enum = TrustLevel.SANDBOXED
elif _session_context.trust_level == "direct":
    # Can create either (opt-in to sandboxing if desired)
    # For MVP: always inherit (no downgrade option)
    trust_enum = TrustLevel.DIRECT

# In send_message tool
caller_trust = _session_context.trust_level
target_trust = target_session.trust_level.value

if caller_trust == "sandboxed" and target_trust == "direct":
    raise ValueError("Sandboxed sessions cannot message direct sessions")
```

---

## Success Metrics

### Functional Requirements

- [ ] `create_session` creates child with correct parent relationship
- [ ] Child session inherits workspace and trust level
- [ ] `send_message` delivers messages within workspace boundaries
- [ ] `list_workspace_sessions` filters by workspace and trust
- [ ] All tools enforce security constraints

### Performance Requirements

- [ ] Session creation < 100ms (database insert + validation)
- [ ] Message delivery < 50ms (HTTP request to inject endpoint)
- [ ] List sessions < 50ms for workspaces with < 100 sessions

### Quality Gates

- [ ] 95%+ test coverage for new MCP tools
- [ ] All security unit tests pass
- [ ] Integration tests verify end-to-end workflow
- [ ] Manual testing with spawned sessions in app UI

---

## Dependencies & Prerequisites

### Completed (Merged)

- ✅ #47: MCP session context injection (orchestrator env var injection)
- ✅ #38: Persistent Docker containers (shared container model)
- ✅ #39: SDK session persistence (shared `.claude/` directory)

### Required for This PR

- Database write access from MCP server (already available via `Database` class)
- HTTP client library (`httpx`) for inject endpoint (already imported)
- Session model update support (add `update_session` method)

### Future Enhancements (Out of Scope)

- Phase 3: App UI for spawned sessions (nested view, visual indicators)
- Phase 4: Lifecycle management (parent ends → children cleanup, spawn limits)
- Phase 4: Advanced coordination (broadcast messaging, rate limiting)

---

## Risk Analysis & Mitigation

### High Risk: Spawn Bomb Attack

**Risk**: Malicious agent creates infinite child sessions

**Mitigation (MVP)**: Trust sandbox isolation - sandboxed agents have resource limits via Docker

**Future**: Rate limiting (max 10 children per session, max 1 create/second)

### Medium Risk: Message Injection Race

**Risk**: Multiple sessions messaging same target simultaneously

**Mitigation**: Orchestrator's inject endpoint is async-safe (uses queue)

**Verification**: Integration test with concurrent senders

### Low Risk: Parent Session Cleanup

**Risk**: Parent ends before children, orphaned sessions

**Mitigation (MVP)**: Accept orphans - they continue running

**Future**: Lifecycle management - cascade delete or reassign to workspace

### Low Risk: Database Contention

**Risk**: Multiple MCP servers writing to sessions.db

**Mitigation**: SQLite WAL mode already enabled, sessions.db supports concurrent writes

**Verification**: Existing integration tests pass

---

## Rollout Plan

### Phase 1: Core Tools (This PR)

- SessionContext reading in mcp_server.py
- `create_session`, `send_message`, `list_workspace_sessions` tools
- Database schema updates
- Unit + integration tests

**Estimated effort**: 2-3 days

### Phase 2: Documentation & Examples

- Update MCP tools documentation
- Add example: "Coordinator spawns Python + Markdown specialists"
- Update agent templates with team coordination patterns

**Estimated effort**: 1 day

### Phase 3: App UI Enhancement (Separate Issue)

- Spawned sessions show parent relationship in session list
- Visual indicator for agent-created sessions
- Team activity view

**Estimated effort**: 3-5 days (Flutter work)

### Phase 4: Advanced Features (Separate Issue)

- Lifecycle management (parent cleanup triggers child cleanup)
- Spawn limits and rate limiting
- Broadcast messaging
- Session groups/teams

**Estimated effort**: 5-7 days

---

## Acceptance Criteria

### Implementation Complete

- [ ] SessionContext dataclass added and initialized in mcp_server.py
- [ ] `create_session` tool creates child with parent relationship
- [ ] `send_message` tool delivers messages with workspace/trust enforcement
- [ ] `list_workspace_sessions` tool filters by workspace and trust
- [ ] Database schema includes `parent_session_id` and `created_by`
- [ ] `update_session` method added to Database class

### Testing Complete

- [ ] 15+ unit tests covering tool logic and security enforcement
- [ ] 3+ integration tests for end-to-end workflows
- [ ] Manual testing: coordinator spawns child and messages it
- [ ] Security tests verify trust escalation blocked

### Documentation Complete

- [ ] Tool docstrings explain parameters and behavior
- [ ] Security model documented (trust inheritance, workspace boundaries)
- [ ] Example workflow in plan or README

---

## References

### Internal

- **Brainstorm**: `docs/brainstorms/2026-02-16-multi-agent-workspace-teams-brainstorm.md`
- **Prerequisite PR**: #47 (MCP session context injection)
- **Session model**: `computer/parachute/models/session.py:125-208`
- **Orchestrator tools**: `computer/parachute/core/orchestrator_tools.py:216-266`
- **Database CRUD**: `computer/parachute/db/database.py:367-549`
- **MCP server tools**: `computer/parachute/mcp_server.py:63-253`
- **Inject endpoint**: `computer/parachute/api/chat.py:277-308`

### External

- **MCP Protocol**: https://modelcontextprotocol.io/
- **SQLModel Migrations**: https://sqlmodel.tiangolo.com/tutorial/create-db-and-table/
- **Claude SDK Session Persistence**: Internal SDK behavior (`.claude/` directory)

### Related Issues

- #38: Persistent Docker Containers (merged)
- #39: SDK Session Persistence (merged)
- #47: MCP Session Context Injection (merged)
- Future: App UI for team sessions
- Future: Lifecycle management and spawn limits

---

## Implementation Checklist

### Code Changes

- [ ] Add SessionContext dataclass to mcp_server.py
- [ ] Initialize `_session_context` in main()
- [ ] Implement `create_session` tool with validation
- [ ] Implement `send_message` tool with enforcement
- [ ] Implement `list_workspace_sessions` tool with filtering
- [ ] Add `parent_session_id` field to Session model
- [ ] Add `created_by` field to Session model
- [ ] Add `update_session` method to Database class
- [ ] Add index for `parent_session_id`

### Tests

- [ ] Unit tests for SessionContext.from_env()
- [ ] Unit tests for create_session (inheritance, validation)
- [ ] Unit tests for send_message (workspace, trust enforcement)
- [ ] Unit tests for list_workspace_sessions (filtering)
- [ ] Integration test: coordinator spawns and messages child
- [ ] Integration test: workspace isolation
- [ ] Integration test: trust level enforcement

### Documentation

- [ ] Tool docstrings complete
- [ ] Security model documented
- [ ] Example workflow added

---

🤖 Ready for implementation with `/para-work 35`
