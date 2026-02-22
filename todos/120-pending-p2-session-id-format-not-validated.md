---
status: pending
priority: p2
issue_id: 35
tags: [code-review, security, validation]
dependencies: []
---

# Session ID Format Not Validated Against Expected Pattern

## Problem Statement

Session IDs from environment variables are not validated against the expected format (`sess_{hex16}`). Malformed session IDs could cause unexpected behavior, path traversal attempts, or information leakage through error messages.

**Why it matters:** Input validation at trust boundaries prevents injection attacks and unexpected behavior.

## Findings

**Source:** security-sentinel agent (confidence: 82%)

**Location:** `computer/parachute/mcp_server.py:70`

```python
@classmethod
def from_env(cls) -> Self:
    return cls(
        session_id=os.getenv("PARACHUTE_SESSION_ID"),  # No format validation
        workspace_id=os.getenv("PARACHUTE_WORKSPACE_ID"),
        trust_level=normalize_trust_level(raw_trust) if raw_trust else None,
    )
```

**Current behavior:** Session IDs generated as `sess_{uuid.uuid4().hex[:16]}` (line 572), but incoming IDs not validated.

**Impact:**
- Malformed IDs cause database query failures
- Path traversal attempts (e.g., `../../etc/passwd`)
- Information leakage through error messages when invalid IDs queried

## Proposed Solutions

### Option 1: Regex Validation (Recommended)
**Effort:** Small (15 minutes)
**Risk:** Low

```python
import re

SESSION_ID_PATTERN = re.compile(r'^sess_[a-f0-9]{16}$|^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')

def validate_session_id(session_id: str) -> None:
    """Validate session ID format. Raises ValueError on invalid input."""
    if not session_id or not SESSION_ID_PATTERN.match(session_id):
        raise ValueError(f"Invalid session ID format: {session_id!r}")

@classmethod
def from_env(cls) -> Self:
    session_id = os.getenv("PARACHUTE_SESSION_ID")
    if session_id:
        try:
            validate_session_id(session_id)
        except ValueError as e:
            logger.warning(f"Invalid session_id from env: {e}")
            session_id = None

    # ... rest of implementation
```

**Pros:**
- Rejects malformed IDs early
- Prevents database query errors
- Logs suspicious activity

**Cons:**
- Must support both formats (new: `sess_hex16`, legacy: full UUID)

### Option 2: Prefix Check Only
**Effort:** Small (5 minutes)
**Risk:** Low (minimal validation)

```python
if session_id and not session_id.startswith("sess_"):
    logger.warning(f"Invalid session_id prefix: {session_id!r}")
    session_id = None
```

**Pros:**
- Simple
- Catches obvious path traversal

**Cons:**
- Doesn't validate hex format

## Recommended Action

**Use regex validation** (Option 1) to enforce both format variants.

## Technical Details

**Affected files:**
- `computer/parachute/mcp_server.py` — SessionContext.from_env()

**Session ID formats:**
- **New:** `sess_{hex16}` (e.g., `sess_a1b2c3d4e5f6g7h8`)
- **Legacy:** Full UUID (e.g., `550e8400-e29b-41d4-a716-446655440000`)

**Validation pattern:**
```python
r'^sess_[a-f0-9]{16}$|^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
```

## Acceptance Criteria

- [ ] Session ID format validated before use
- [ ] Malformed session IDs rejected (logged + set to None)
- [ ] Both new and legacy formats accepted
- [ ] Tests verify path traversal attempts blocked
- [ ] Error messages don't leak internal details

## Work Log

- 2026-02-22: Identified during code review by security-sentinel agent

## Resources

- **Related finding:** Workspace ID validation (#119)
- **Source PR:** feat/multi-agent-workspace-teams branch
- **Issue:** #35 (Multi-Agent Workspace Teams)
