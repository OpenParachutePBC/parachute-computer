---
title: feat: MCP session context injection for tool-level security
type: feat
date: 2026-02-22
issue: 47
priority: P2
prerequisite_for: 35
---

# MCP Session Context Injection for Tool-Level Security

**Prerequisite for**: #35 (Multi-Agent Workspace Teams)
**Priority**: P2

---

## Overview

Enable MCP tools to enforce per-session security constraints by injecting session context (session_id, workspace_id, trust_level) as environment variables when the orchestrator spawns MCP server processes. This provides tools with the information needed to scope their behavior appropriately without relying on agent-provided data.

**Core principle**: Security boundaries are set by the orchestrator, not the agent. MCP tools must receive authenticated context from a trusted source.

---

## Problem Statement

MCP tools currently have **no session context**. The built-in parachute MCP server (`mcp_server.py`) runs as a standalone stdio process with only `PARACHUTE_VAULT_PATH`. Tools don't know:

- Which session is calling them
- What workspace (if any) is active
- What trust level applies
- Who the user is (for future multi-user support)

**Impact:**

This blocks any MCP tool that needs per-session constraints:
- **Immediate blocker**: `create_session` and `send_message` tools for multi-agent teams (#35)
- **Future use cases**: Workspace-scoped queries, per-user data access, session-aware logging

**Current workaround**: Trust-level filtering (`capability_filter.py`) controls which MCPs are *available* to a session, but once available, the tool has no idea who's calling it.

**Example vulnerability**: A sandboxed session and a direct session both see the same MCP tool. The tool can't differentiate behavior based on caller trust level.

---

## Proposed Solution

Inject session context via environment variables when the orchestrator spawns MCP server processes:

```python
# Added to each MCP server's env dict before passing to SDK
{
    "PARACHUTE_SESSION_ID": "sess_abc123",
    "PARACHUTE_WORKSPACE_ID": "my-project",  # Empty string if no workspace
    "PARACHUTE_TRUST_LEVEL": "sandboxed",    # normalized: direct | sandboxed
}
```

### Why Environment Variables?

1. **Set by orchestrator** - Cannot be manipulated by the agent
2. **Fits MCP stdio model** - SDK spawns processes with custom env per session
3. **Invisible to agent** - Clean API, security is non-negotiable
4. **Proven pattern** - Sandbox already uses this for per-session config (`sandbox.py:225-246`)

### Architecture Flow

```
┌─────────────┐
│ Orchestrator│
│ Session:    │
│  id: abc123 │
│  workspace: │
│   my-proj   │
│  trust:     │
│   sandboxed │
└──────┬──────┘
       │
       │ 1. Load MCPs from vault/.mcp.json
       │ 2. Filter by trust level
       │ 3. Filter by workspace capabilities
       │ 4. Inject session context into env
       │
       v
┌──────────────────────────────────┐
│ MCP Server Config (to SDK)       │
│ {                                │
│   "parachute": {                 │
│     "command": "python",         │
│     "args": ["-m", ...],         │
│     "env": {                     │
│       "PARACHUTE_VAULT_PATH": "",│
│       "PARACHUTE_SESSION_ID": "",│  ← Injected
│       "PARACHUTE_WORKSPACE_ID":"",│  ← Injected
│       "PARACHUTE_TRUST_LEVEL": "",│  ← Injected
│     }                            │
│   }                              │
│ }                                │
└──────────────────────────────────┘
       │
       │ 5. SDK spawns subprocess with env
       │
       v
┌──────────────────────────────────┐
│ MCP Server Process               │
│ (parachute.mcp_server)           │
│                                  │
│ session_id = os.getenv(          │
│   "PARACHUTE_SESSION_ID"         │
│ )                                │
│ workspace_id = os.getenv(        │
│   "PARACHUTE_WORKSPACE_ID"       │
│ )                                │
│ trust_level = os.getenv(         │
│   "PARACHUTE_TRUST_LEVEL"        │
│ )                                │
│                                  │
│ # Use context for scoping        │
│ # - Filter results by workspace  │
│ # - Enforce trust boundaries     │
│ # - Log with session context     │
└──────────────────────────────────┘
```

---

## Technical Approach

### Phase 1: Orchestrator Context Injection

**File**: `computer/parachute/core/orchestrator.py`

**Injection point**: After MCP filtering, before passing to SDK (around line 635)

**Current code**:
```python
# Load MCP servers with OAuth tokens attached for HTTP servers
resolved_mcps = None
mcp_warnings: list[str] = []
try:
    global_mcps = await load_mcp_servers(self.vault_path)
    resolved_mcps = resolve_mcp_servers(agent.mcp_servers, global_mcps)

    # Validate and filter
    if resolved_mcps:
        resolved_mcps, mcp_warnings = validate_and_filter_servers(resolved_mcps)
except Exception as e:
    logger.error(f"Failed to load MCP servers: {e}")
    resolved_mcps = None

# Trust-level filtering
if resolved_mcps:
    pre_count = len(resolved_mcps)
    resolved_mcps = filter_by_trust_level(resolved_mcps, effective_trust)

# Workspace filtering
if workspace_config and workspace_config.capabilities:
    filtered = filter_capabilities(
        capabilities=workspace_config.capabilities,
        all_mcps=resolved_mcps,
        # ...
    )
    resolved_mcps = filtered.mcp_servers or None
```

**New code** (add after filtering, before SDK call):
```python
# Inject session context into MCP env vars
if resolved_mcps:
    from parachute.core.mcp_context import inject_session_context

    resolved_mcps = inject_session_context(
        mcp_servers=resolved_mcps,
        session_id=session.id,
        workspace_id=workspace_id or "",
        trust_level=effective_trust,
    )
```

**Create new file**: `computer/parachute/core/mcp_context.py`

```python
"""MCP session context injection.

Injects session metadata into MCP server environment variables so tools
can enforce per-session constraints without trusting agent-provided data.
"""

import logging
from typing import Any

logger = logging.getLogger(__name__)


def inject_session_context(
    mcp_servers: dict[str, Any],
    session_id: str,
    workspace_id: str,
    trust_level: str,
) -> dict[str, Any]:
    """Inject session context into MCP server env vars.

    Adds environment variables that MCP tools can read to scope behavior:
    - PARACHUTE_SESSION_ID: Unique session identifier
    - PARACHUTE_WORKSPACE_ID: Workspace slug (empty string if none)
    - PARACHUTE_TRUST_LEVEL: Normalized trust level (direct | sandboxed)

    Args:
        mcp_servers: MCP server configs (will be modified in-place)
        session_id: Unique session identifier (UUID)
        workspace_id: Workspace slug or empty string
        trust_level: Normalized trust level (direct | sandboxed)

    Returns:
        The modified mcp_servers dict (same reference)

    Example:
        >>> mcps = {"parachute": {"command": "python", "args": ["-m", "..."]}}
        >>> inject_session_context(mcps, "sess_123", "my-workspace", "sandboxed")
        >>> print(mcps["parachute"]["env"]["PARACHUTE_SESSION_ID"])
        'sess_123'
    """
    for mcp_name, mcp_config in mcp_servers.items():
        # Ensure env dict exists
        if "env" not in mcp_config:
            mcp_config["env"] = {}

        # Inject context (don't overwrite existing values if set)
        env = mcp_config["env"]
        if "PARACHUTE_SESSION_ID" not in env:
            env["PARACHUTE_SESSION_ID"] = session_id
        if "PARACHUTE_WORKSPACE_ID" not in env:
            env["PARACHUTE_WORKSPACE_ID"] = workspace_id
        if "PARACHUTE_TRUST_LEVEL" not in env:
            env["PARACHUTE_TRUST_LEVEL"] = trust_level

        logger.debug(
            f"Injected session context into MCP '{mcp_name}': "
            f"session={session_id[:8]}, workspace={workspace_id or '(none)'}, "
            f"trust={trust_level}"
        )

    return mcp_servers
```

**Testing approach**:
- Unit test `inject_session_context()` with various MCP configs
- Integration test: Verify env vars reach MCP subprocess (add debug logging to `mcp_server.py`)
- Test that existing `env` entries are preserved (don't overwrite `PARACHUTE_VAULT_PATH`)

---

### Phase 2: Update Parachute MCP Server

**File**: `computer/parachute/mcp_server.py`

**Current initialization** (lines 668-690):
```python
if __name__ == "__main__":
    vault_path = sys.argv[1] if len(sys.argv) > 1 else os.getenv("PARACHUTE_VAULT_PATH")
    if not vault_path:
        print("Error: vault path required", file=sys.stderr)
        sys.exit(1)

    # Initialize global state
    _vault_path = Path(vault_path)
    _db = Database(_vault_path / "Chat" / "sessions.db")

    # Run MCP server
    mcp.run()
```

**New initialization** (read session context):
```python
if __name__ == "__main__":
    vault_path = sys.argv[1] if len(sys.argv) > 1 else os.getenv("PARACHUTE_VAULT_PATH")
    if not vault_path:
        print("Error: vault path required", file=sys.stderr)
        sys.exit(1)

    # Read session context from environment
    session_id = os.getenv("PARACHUTE_SESSION_ID")
    workspace_id = os.getenv("PARACHUTE_WORKSPACE_ID")
    trust_level = os.getenv("PARACHUTE_TRUST_LEVEL")

    # Log context for debugging
    if session_id:
        logger.info(
            f"MCP server started with session context: "
            f"session={session_id[:8]}, workspace={workspace_id or '(none)'}, "
            f"trust={trust_level}"
        )
    else:
        logger.warning("MCP server started without session context (legacy mode)")

    # Store in module globals for tool access
    _vault_path = Path(vault_path)
    _session_id = session_id
    _workspace_id = workspace_id
    _trust_level = trust_level
    _db = Database(_vault_path / "Chat" / "sessions.db")

    # Run MCP server
    mcp.run()
```

**Add module-level globals** (after line 59):
```python
# Session context (injected via env vars by orchestrator)
_session_id: str | None = None
_workspace_id: str | None = None
_trust_level: str | None = None
```

**Future use in tools** (example for workspace-scoped queries):
```python
@mcp.tool()
async def search_sessions(
    query: str,
    limit: int = 10,
    source: str | None = None,
    tags: list[str] | None = None,
) -> list[dict]:
    """Search chat sessions by keyword."""
    # If workspace is active, only search sessions in that workspace
    workspace_filter = _workspace_id if _workspace_id else None

    results = await _db.search_sessions(
        query=query,
        limit=limit,
        source=source,
        tags=tags,
        workspace_id=workspace_filter,  # ← New scoping
    )
    return [_session_to_dict(s) for s in results]
```

**Phase 2 scope**: Just read and log the context. Don't change tool behavior yet - that's for #35.

---

### Phase 3: Sandbox Container Context

**File**: `computer/parachute/core/sandbox.py`

**Current MCP passing to container** (lines 244-246):
```python
if config.mcp_servers is not None:
    mcp_names = ",".join(config.mcp_servers.keys())
    env_lines.append(f"PARACHUTE_MCP_SERVERS={mcp_names}")
```

**Enhancement**: The orchestrator already filters MCPs before passing `config.mcp_servers` to sandbox. The filtered config includes env vars with session context (from Phase 1). No additional work needed - the context flows through naturally.

**Verification**:
- Add debug logging to `docker/entrypoint.py` to confirm env vars reach container
- Test both ephemeral (`run_agent`) and persistent (`run_persistent`, `run_default`) modes

**File**: `computer/parachute/docker/entrypoint.py`

**Current MCP loading** (lines 175-189):
```python
# MCP servers
if capabilities.get("mcp_servers"):
    options_kwargs["mcp_servers"] = capabilities["mcp_servers"]
```

**Add logging**:
```python
# MCP servers (with session context injected by orchestrator)
if capabilities.get("mcp_servers"):
    options_kwargs["mcp_servers"] = capabilities["mcp_servers"]

    # Log that session context is present (for debugging)
    for mcp_name, mcp_config in capabilities["mcp_servers"].items():
        env = mcp_config.get("env", {})
        if "PARACHUTE_SESSION_ID" in env:
            session_id = env["PARACHUTE_SESSION_ID"]
            emit({
                "type": "log",
                "message": f"MCP '{mcp_name}' has session context: {session_id[:8]}...",
                "level": "debug",
            })
```

---

## Security Considerations

### 1. Prevent Agent Manipulation

**Threat**: Agent tries to pass fake session context to MCP tools

**Mitigation**:
- Context comes from orchestrator env vars, not agent messages
- MCP subprocess inherits env from parent (SDK), agent has no control
- Even if agent sends fake context in message, MCP reads env vars (trusted source)

**Verification**: Unit test that env vars can't be overridden by agent-provided data

### 2. Session Isolation

**Threat**: One session's MCP subprocess leaks data to another session

**Current isolation**:
- SDK spawns separate MCP processes per session (stdio model)
- Each process gets its own env vars
- Processes don't share memory or file descriptors

**Additional safeguards**:
- Log session_id in MCP server startup (audit trail)
- Future: Add process ID to logs for correlation
- Future: Use session_id in temp file names (if MCP writes temp data)

### 3. Trust Level Enforcement

**Threat**: MCP tool allows escalation from sandboxed to direct

**Current protection**:
- Trust-level filtering happens BEFORE context injection
- Sandboxed sessions never see direct-only MCPs
- Context injection is informational, not authorization

**Best practice for tool authors**:
```python
# In MCP tool implementation
if _trust_level == "sandboxed":
    # Extra validation for sandboxed callers
    if not is_safe_for_sandboxed(operation):
        raise PermissionError("Operation not allowed in sandboxed session")
```

**Documentation**: Add `docs/mcp-tool-security.md` with trust level guidelines

### 4. Input Validation

**Threat**: Malicious workspace_id or session_id causes injection attacks

**Protection**:
- `session_id` is UUID from database (validated on creation)
- `workspace_id` is slug validated by `validate_workspace_slug()` (lines 28-34 in `validation.py`)
- `trust_level` is normalized by `normalize_trust_level()` (from `core/trust.py`)

**No additional validation needed** - orchestrator inputs are already sanitized.

### 5. Institutional Learnings Applied

Based on security patterns found in learnings-researcher:

✅ **Validate at API boundary** - Session/workspace IDs validated before reaching orchestrator
✅ **Don't trust external configs** - Context injection doesn't merge user-provided MCP configs
✅ **Path confinement** - Not applicable (env vars, not filesystem)
✅ **Reject symlinks** - Not applicable
✅ **No string interpolation for structured data** - Using dict assignment, not f-strings
✅ **Trust level hard-fail** - Filtering removes unavailable MCPs; no fallback escalation

**Specific application**: Todo #073 warns against merging external MCP configs without validation. Our implementation doesn't merge - it injects env vars into already-loaded configs.

---

## Acceptance Criteria

### Functional Requirements

- [ ] `inject_session_context()` adds env vars to all MCP server configs
- [ ] Orchestrator calls injection after filtering, before SDK
- [ ] `mcp_server.py` reads and logs session context on startup
- [ ] Session context flows through sandbox boundary (ephemeral and persistent)
- [ ] Existing MCP configs preserve their original env vars
- [ ] Empty workspace_id represented as empty string (not null)

### Non-Functional Requirements

- [ ] No performance degradation (context injection is O(n) where n = # of MCPs)
- [ ] Backward compatible (MCPs without context continue working)
- [ ] Debug logging aids troubleshooting (context visible in logs)
- [ ] Security: Agent cannot override orchestrator-provided context

### Quality Gates

- [ ] Unit tests for `inject_session_context()` (various input scenarios)
- [ ] Integration test: Verify env vars reach MCP subprocess
- [ ] Integration test: Verify context flows through sandbox
- [ ] Code review confirms no security gaps
- [ ] Documentation explains when/how to use context in tools

---

## Testing Strategy

### Unit Tests

**File**: `computer/tests/core/test_mcp_context.py` (new)

```python
import pytest
from parachute.core.mcp_context import inject_session_context


def test_inject_creates_env_dict():
    """Env dict is created if missing."""
    mcps = {"test": {"command": "python"}}
    result = inject_session_context(mcps, "sess_123", "ws", "direct")
    assert "env" in result["test"]
    assert result["test"]["env"]["PARACHUTE_SESSION_ID"] == "sess_123"


def test_inject_preserves_existing_env():
    """Existing env vars are not overwritten."""
    mcps = {
        "test": {
            "command": "python",
            "env": {"CUSTOM_VAR": "keep_me"},
        }
    }
    result = inject_session_context(mcps, "sess_123", "", "sandboxed")
    assert result["test"]["env"]["CUSTOM_VAR"] == "keep_me"
    assert result["test"]["env"]["PARACHUTE_SESSION_ID"] == "sess_123"


def test_inject_empty_workspace():
    """Empty workspace_id represented as empty string."""
    mcps = {"test": {"command": "python"}}
    result = inject_session_context(mcps, "sess_123", "", "direct")
    assert result["test"]["env"]["PARACHUTE_WORKSPACE_ID"] == ""


def test_inject_all_context_fields():
    """All three context fields are injected."""
    mcps = {"test": {"command": "python"}}
    result = inject_session_context(mcps, "sess_abc", "my-ws", "sandboxed")
    env = result["test"]["env"]
    assert env["PARACHUTE_SESSION_ID"] == "sess_abc"
    assert env["PARACHUTE_WORKSPACE_ID"] == "my-ws"
    assert env["PARACHUTE_TRUST_LEVEL"] == "sandboxed"


def test_inject_multiple_servers():
    """Context injected into all MCP servers."""
    mcps = {
        "mcp1": {"command": "python"},
        "mcp2": {"command": "node"},
    }
    result = inject_session_context(mcps, "sess_123", "ws", "direct")
    assert result["mcp1"]["env"]["PARACHUTE_SESSION_ID"] == "sess_123"
    assert result["mcp2"]["env"]["PARACHUTE_SESSION_ID"] == "sess_123"


def test_inject_doesnt_override_existing_context():
    """Pre-set context vars are not overwritten."""
    mcps = {
        "test": {
            "command": "python",
            "env": {"PARACHUTE_SESSION_ID": "custom_session"},
        }
    }
    result = inject_session_context(mcps, "sess_123", "", "direct")
    assert result["test"]["env"]["PARACHUTE_SESSION_ID"] == "custom_session"
```

### Integration Tests

**File**: `computer/tests/integration/test_mcp_session_context.py` (new)

```python
import asyncio
import os
import pytest
from pathlib import Path
from parachute.core.orchestrator import Orchestrator
from parachute.models.session import SessionCreate


@pytest.mark.asyncio
async def test_session_context_reaches_mcp_server(tmp_vault):
    """Session context env vars reach MCP server subprocess."""
    # Create orchestrator with test vault
    orchestrator = Orchestrator(vault_path=tmp_vault, settings=test_settings)

    # Create session with workspace
    session = await orchestrator.database.create_session(
        SessionCreate(
            id="test_session_123",
            workspace_id="test-workspace",
            trust_level="sandboxed",
            module="chat",
        )
    )

    # Start session (triggers MCP loading)
    # Use a message that triggers MCP tool call
    async for event in orchestrator.run_streaming(
        session_id=session.id,
        message="List recent sessions",  # Triggers search_sessions tool
    ):
        if event.get("type") == "log" and "MCP" in event.get("message", ""):
            # Check that debug log shows session context
            assert "test_session_123" in event["message"]
            break


@pytest.mark.asyncio
async def test_sandbox_receives_mcp_context(tmp_vault):
    """MCP context flows through sandbox boundary."""
    orchestrator = Orchestrator(vault_path=tmp_vault, settings=test_settings)

    session = await orchestrator.database.create_session(
        SessionCreate(
            id="sandbox_session",
            workspace_id="ws",
            trust_level="sandboxed",
            module="chat",
        )
    )

    # Sandboxed session triggers container spawn
    async for event in orchestrator.run_streaming(
        session_id=session.id,
        message="Test MCP in sandbox",
    ):
        if event.get("type") == "log" and "session context" in event.get("message", ""):
            # Entrypoint logged context
            assert "sandbox_session" in event["message"]
            break
```

### Manual Testing

1. **Direct mode session**:
   ```bash
   # Start server
   parachute server -f

   # Create chat session (via app or API)
   # Send message that triggers MCP tool
   # Check logs for: "MCP server started with session context: session=..."
   ```

2. **Sandboxed mode session**:
   ```bash
   # Create sandboxed session
   # Verify Docker container logs show session context
   docker logs parachute-sandbox-<session-id>
   ```

3. **Workspace session**:
   ```bash
   # Create session with workspace_id
   # Verify MCP logs show workspace: workspace=my-project
   ```

---

## Success Metrics

### Immediate Success

- [ ] Session context reaches MCP server process (verified via logs)
- [ ] Context flows through both direct and sandboxed modes
- [ ] No regressions in existing MCP functionality
- [ ] Zero security vulnerabilities introduced

### Future Enablement

- [ ] Issue #35 can implement `create_session` and `send_message` tools using session context
- [ ] MCP tools can scope queries by workspace (e.g., workspace-only session search)
- [ ] Audit logging can correlate MCP tool calls with sessions
- [ ] Multi-user support can distinguish users via context (future)

---

## Dependencies & Prerequisites

### Hard Dependencies

- ✅ Trust level normalization (`core/trust.py`) - already exists (from commit 8f93d13)
- ✅ Workspace validation (`core/validation.py`) - already exists
- ✅ MCP loading architecture (`lib/mcp_loader.py`) - already exists

### Soft Dependencies

- Issue #35 (Multi-Agent Workspace Teams) will consume this feature
- Future workspace-scoped queries depend on `PARACHUTE_WORKSPACE_ID`
- Future multi-user support depends on extensibility (add `PARACHUTE_USER_ID` later)

### No Breaking Changes

- Existing MCPs continue working (context is additive)
- Backward compatible with MCPs that don't read context
- No changes to MCP tool definitions or SDK integration

---

## Risks & Mitigation

### Risk 1: SDK Modifies Env Dict

**Risk**: Claude SDK might shallow-copy `mcp_servers` dict, breaking our env injection

**Likelihood**: Low (orchestrator controls dict before SDK)

**Impact**: High (context doesn't reach subprocess)

**Mitigation**:
- Integration test verifies env vars reach subprocess
- If SDK copies, inject at different layer (e.g., wrap command with env prefix)

**Fallback**: Pass context via temp file mounted in container (like `capabilities.json`)

### Risk 2: Subprocess Isolation Breaks

**Risk**: Two sessions' MCP subprocesses somehow share env

**Likelihood**: Very low (SDK spawns per-session)

**Impact**: Critical (session data leaks)

**Mitigation**:
- Review SDK subprocess spawning code
- Add process ID to logs for correlation
- Integration test with parallel sessions

**Monitoring**: Log session_id in MCP server startup for audit trail

### Risk 3: Performance Degradation

**Risk**: Context injection adds latency to session startup

**Likelihood**: Low (simple dict mutation)

**Impact**: Low (< 1ms per MCP server)

**Mitigation**:
- Measure session startup time before/after
- Benchmark with 10+ MCPs to verify O(n) performance

**Acceptable threshold**: < 10ms added latency for 10 MCPs

---

## Implementation Phases

### Phase 1: Core Injection (2-3 hours)

**Goal**: Context injection works end-to-end

**Tasks**:
- [ ] Create `core/mcp_context.py` with `inject_session_context()`
- [ ] Add injection call to `orchestrator.py` after filtering
- [ ] Write unit tests for injection function
- [ ] Test that existing env vars are preserved

**Deliverable**: Orchestrator injects context into MCP configs

### Phase 2: MCP Server Update (1-2 hours)

**Goal**: Parachute MCP reads and logs context

**Tasks**:
- [ ] Update `mcp_server.py` to read env vars
- [ ] Add module-level globals for context
- [ ] Add startup logging
- [ ] Test that context is visible in logs

**Deliverable**: MCP server logs session context on startup

### Phase 3: Sandbox Verification (1 hour)

**Goal**: Context flows through sandbox boundary

**Tasks**:
- [ ] Add debug logging to `docker/entrypoint.py`
- [ ] Test ephemeral container mode (`run_agent`)
- [ ] Test persistent container mode (`run_persistent`, `run_default`)
- [ ] Verify logs show session context

**Deliverable**: Both direct and sandboxed modes have context

### Phase 4: Testing & Documentation (2 hours)

**Goal**: Comprehensive testing and docs

**Tasks**:
- [ ] Write integration tests (session context reaches MCP)
- [ ] Write integration test (sandbox receives context)
- [ ] Document `PARACHUTE_*` env vars in MCP server comments
- [ ] Update CLAUDE.md with context injection notes
- [ ] Create `docs/mcp-tool-security.md` with guidelines

**Deliverable**: Tested, documented, ready for #35

**Total estimated effort**: 6-8 hours

---

## Future Considerations

### Multi-User Support

When multi-user becomes a priority:

```python
# Add to inject_session_context()
if user_id:
    env["PARACHUTE_USER_ID"] = user_id
```

MCP tools can then scope data by user:
```python
# In mcp_server.py tool
results = await _db.search_sessions(
    query=query,
    workspace_id=_workspace_id,
    user_id=_user_id,  # New filter
)
```

### Workspace-Specific MCP Configuration

Extend `WorkspaceCapabilities` to override MCP env vars:

```yaml
# vault/.parachute/workspaces/my-project/config.yaml
capabilities:
  mcps: all
  mcp_env_overrides:
    parachute:
      CUSTOM_VAR: "workspace-specific-value"
```

Apply overrides after context injection in orchestrator.

### Per-Session MCP Instances

For advanced isolation, spawn separate MCP server instances per session:

```python
# In mcp_loader.py
def get_session_mcp_name(mcp_name: str, session_id: str) -> str:
    return f"{mcp_name}_{session_id[:8]}"
```

Each session gets its own parachute MCP server process. More resource-intensive but stronger isolation.

### Audit Logging

Add structured logging for MCP tool calls:

```python
# In mcp_server.py tool handler
logger.info(
    "MCP tool call",
    extra={
        "tool_name": "search_sessions",
        "session_id": _session_id,
        "workspace_id": _workspace_id,
        "trust_level": _trust_level,
        "args": {"query": query},
    }
)
```

Enables security auditing and usage analytics.

---

## References & Research

### Internal References

**Architecture**:
- `computer/parachute/core/orchestrator.py:512-543` - MCP loading and filtering
- `computer/parachute/lib/mcp_loader.py:33-64` - Built-in MCP env var pattern
- `computer/parachute/core/capability_filter.py:45-85` - Trust-level filtering
- `computer/parachute/core/sandbox.py:225-246` - Per-session env var injection pattern
- `computer/parachute/docker/entrypoint.py:175-189` - Container MCP loading

**Models**:
- `computer/parachute/models/session.py:125-220` - Session metadata available
- `computer/parachute/models/workspace.py:79-129` - Workspace configuration

**Security Patterns**:
- `computer/parachute/core/trust.py` - Trust level normalization
- `computer/parachute/core/validation.py:28-34` - Workspace slug validation
- `todos/073-pending-p1-plugin-mcp-merge-no-validation.md` - MCP config security
- `todos/114-pending-p2-bot-connector-trust-level-implications.md` - Trust level threat model

### Related Issues

- #35 - Multi-Agent Workspace Teams (depends on this)
- #47 - This issue (MCP session context injection)

### Institutional Learnings Applied

From `learnings-researcher` findings:

1. **Input validation at API boundary** - Session/workspace IDs already validated before reaching orchestrator
2. **MCP config safety** - Not merging external configs; injecting into loaded configs
3. **Trust level enforcement** - Using normalized trust levels from `core/trust.py`
4. **Environment variables for subprocess context** - Following sandbox.py pattern
5. **Path confinement** - Not applicable (env vars, not filesystem)
6. **No string interpolation** - Using dict assignment for structured data

### External References

**Claude SDK**:
- MCP stdio protocol: Subprocesses spawned with custom env per session
- SDK handles subprocess lifecycle; orchestrator provides config

**MCP Protocol**:
- Model Context Protocol specification (stdio transport)
- Environment variables are standard subprocess configuration

---

## Pseudo-Code Examples

### mcp_context.py

```python
"""MCP session context injection."""

import logging
from typing import Any

logger = logging.getLogger(__name__)


def inject_session_context(
    mcp_servers: dict[str, Any],
    session_id: str,
    workspace_id: str,
    trust_level: str,
) -> dict[str, Any]:
    """Inject session context into MCP env vars."""
    for mcp_name, mcp_config in mcp_servers.items():
        if "env" not in mcp_config:
            mcp_config["env"] = {}

        env = mcp_config["env"]
        env.setdefault("PARACHUTE_SESSION_ID", session_id)
        env.setdefault("PARACHUTE_WORKSPACE_ID", workspace_id)
        env.setdefault("PARACHUTE_TRUST_LEVEL", trust_level)

        logger.debug(f"Context injected: {mcp_name} -> {session_id[:8]}")

    return mcp_servers
```

### orchestrator.py (updated)

```python
# After MCP filtering (around line 657)
if resolved_mcps:
    from parachute.core.mcp_context import inject_session_context

    resolved_mcps = inject_session_context(
        mcp_servers=resolved_mcps,
        session_id=session.id,
        workspace_id=workspace_id or "",
        trust_level=effective_trust,
    )
```

### mcp_server.py (updated)

```python
# Module globals (after line 59)
_session_id: str | None = None
_workspace_id: str | None = None
_trust_level: str | None = None

# Main block (lines 668-690)
if __name__ == "__main__":
    vault_path = sys.argv[1] if len(sys.argv) > 1 else os.getenv("PARACHUTE_VAULT_PATH")

    # Read session context
    _session_id = os.getenv("PARACHUTE_SESSION_ID")
    _workspace_id = os.getenv("PARACHUTE_WORKSPACE_ID")
    _trust_level = os.getenv("PARACHUTE_TRUST_LEVEL")

    if _session_id:
        logger.info(f"Session context: {_session_id[:8]}, ws={_workspace_id}, trust={_trust_level}")

    _vault_path = Path(vault_path)
    _db = Database(_vault_path / "Chat" / "sessions.db")
    mcp.run()
```

### test_mcp_context.py

```python
import pytest
from parachute.core.mcp_context import inject_session_context


def test_inject_all_fields():
    mcps = {"test": {"command": "python"}}
    result = inject_session_context(mcps, "sess_123", "ws", "direct")

    env = result["test"]["env"]
    assert env["PARACHUTE_SESSION_ID"] == "sess_123"
    assert env["PARACHUTE_WORKSPACE_ID"] == "ws"
    assert env["PARACHUTE_TRUST_LEVEL"] == "direct"
```

---

## Documentation Plan

### New Documentation

1. **`docs/mcp-tool-security.md`** - Guidelines for MCP tool authors
   - How to read session context env vars
   - Best practices for trust level enforcement
   - Examples of workspace-scoped queries
   - Security considerations

2. **`computer/parachute/core/mcp_context.py`** - Inline docstrings
   - Function-level docs with examples
   - Args/returns documentation
   - Usage examples in module docstring

3. **`computer/parachute/mcp_server.py`** - Update comments
   - Document new module globals
   - Explain session context lifecycle
   - Note backward compatibility (context optional)

### Updated Documentation

1. **`computer/CLAUDE.md`** - Add section on MCP context injection
   - Explain when/how context is injected
   - Document env var naming convention
   - Link to tool security guide

2. **`README.md`** - Update MCP documentation
   - Mention session-aware MCP tools
   - Link to security guide

3. **`computer/parachute/mcp_server.py`** - Tool docstrings
   - Note which tools use session context
   - Document workspace filtering behavior (when implemented)

### API Documentation

No user-facing API changes. Context injection is transparent to users.

---

## Rollout Plan

### Development

1. Create feature branch: `feat/mcp-session-context`
2. Implement phases 1-4 sequentially
3. Run full test suite after each phase
4. Create PR with comprehensive description

### Testing

1. Unit tests pass (pytest)
2. Integration tests pass (session context reaches MCP)
3. Manual testing in dev environment (direct and sandboxed modes)
4. Security review (verify no agent manipulation possible)

### Deployment

1. Merge to main after review
2. No database migrations needed
3. No configuration changes needed (backward compatible)
4. Monitor logs for "MCP server started with session context" messages
5. Verify no performance regression

### Monitoring

**Key metrics**:
- Session startup latency (should not increase)
- MCP server startup success rate (should remain 100%)
- Log volume (expect slightly more debug logs)

**Alerts**:
- MCP server failures
- Sessions without context (indicates regression)

### Rollback Plan

If critical issues discovered:
1. Revert orchestrator injection call (single line)
2. MCP server continues working (context is optional)
3. No data corruption possible (env vars only)

---

## Conclusion

This feature provides the foundation for session-aware MCP tools by injecting authenticated context from the orchestrator. It's a prerequisite for multi-agent workspace teams (#35) and enables future features like workspace-scoped queries, per-user data access, and audit logging.

**Key benefits**:
- **Security**: Context comes from trusted source (orchestrator), not agent
- **Simplicity**: Single injection point, minimal code changes
- **Extensibility**: Easy to add new context fields (user_id, etc.)
- **Backward compatible**: Existing MCPs continue working

**Estimated effort**: 6-8 hours total

**Next steps**: Implement phases 1-4, then unblock #35 for multi-agent teams.
