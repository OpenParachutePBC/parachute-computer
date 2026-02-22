---
status: pending
priority: p2
issue_id: 35
tags: [code-review, security, validation]
dependencies: []
---

# Missing Workspace ID Validation on Session Context Injection

## Problem Statement

`SessionContext.from_env()` reads `PARACHUTE_WORKSPACE_ID` from environment variables without validation. While the orchestrator sets these authoritatively, a compromised MCP server or malicious environment could inject arbitrary workspace IDs, bypassing workspace isolation.

**Why it matters:** Workspace boundaries are a security boundary. Invalid or malicious workspace IDs could allow cross-workspace access.

## Findings

**Source:** security-sentinel agent (confidence: 85%)

**Location:** `computer/parachute/mcp_server.py:61-73`

```python
@classmethod
def from_env(cls) -> Self:
    """Read session context from environment variables."""
    from parachute.core.trust import normalize_trust_level

    raw_trust = os.getenv("PARACHUTE_TRUST_LEVEL")
    return cls(
        session_id=os.getenv("PARACHUTE_SESSION_ID"),
        workspace_id=os.getenv("PARACHUTE_WORKSPACE_ID"),  # No validation
        trust_level=normalize_trust_level(raw_trust) if raw_trust else None,
    )
```

**Impact:**
- Attacker controlling env vars could access sessions in other workspaces
- Workspace boundary enforcement bypassed
- Trust level restrictions circumvented by targeting different workspace

## Proposed Solutions

### Option 1: Validate Workspace Slug Format (Recommended)
**Effort:** Small (15 minutes)
**Risk:** Low (additive validation)

```python
@classmethod
def from_env(cls) -> Self:
    from parachute.core.trust import normalize_trust_level
    from parachute.core.workspaces import validate_workspace_slug

    raw_trust = os.getenv("PARACHUTE_TRUST_LEVEL")
    workspace_id = os.getenv("PARACHUTE_WORKSPACE_ID")

    # Validate workspace_id if present
    if workspace_id:
        try:
            validate_workspace_slug(workspace_id)
        except ValueError as e:
            logger.warning(f"Invalid workspace_id from env: {e}")
            workspace_id = None  # Reject invalid input

    return cls(
        session_id=os.getenv("PARACHUTE_SESSION_ID"),
        workspace_id=workspace_id,
        trust_level=normalize_trust_level(raw_trust) if raw_trust else None,
    )
```

**Pros:**
- Defense in depth
- Rejects malformed workspace IDs
- Logs suspicious activity

**Cons:**
- Adds dependency on workspaces module

### Option 2: Regex Validation
**Effort:** Small (10 minutes)
**Risk:** Low

```python
import re

WORKSPACE_SLUG_PATTERN = re.compile(r'^[a-z0-9-]+$')

if workspace_id and not WORKSPACE_SLUG_PATTERN.match(workspace_id):
    logger.warning(f"Invalid workspace_id format: {workspace_id!r}")
    workspace_id = None
```

**Pros:**
- No external dependencies
- Simple validation

**Cons:**
- Duplicates validation logic if already in workspaces module

## Recommended Action

**Use `validate_workspace_slug()`** if it exists (Option 1), otherwise regex (Option 2).

## Technical Details

**Affected files:**
- `computer/parachute/mcp_server.py` — SessionContext.from_env() method

**Affected components:**
- All MCP tools that check `_session_context.workspace_id`
- Workspace boundary enforcement

**Validation rules:**
- Alphanumeric + hyphens only
- Lowercase (normalized)
- Non-empty

## Acceptance Criteria

- [ ] Workspace ID validated before use
- [ ] Invalid workspace IDs rejected (logged + set to None)
- [ ] Tests verify malformed workspace IDs are rejected
- [ ] Security review confirms workspace isolation intact

## Work Log

- 2026-02-22: Identified during code review by security-sentinel agent

## Resources

- **Related finding:** Session ID validation (#118)
- **Source PR:** feat/multi-agent-workspace-teams branch
- **Issue:** #35 (Multi-Agent Workspace Teams)
