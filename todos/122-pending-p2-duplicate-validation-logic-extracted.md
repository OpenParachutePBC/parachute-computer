---
status: pending
priority: p2
issue_id: 35
tags: [code-review, code-quality, refactoring]
dependencies: []
---

# Duplicate Content Validation Logic Should Be Extracted

## Problem Statement

Identical validation logic for message content (max 50k chars, control character filtering) appears in both `create_session()` and `send_message()` functions. This violates DRY (Don't Repeat Yourself) and creates maintenance burden.

**Why it matters:** Bugs or changes to validation logic must be applied in two places. Duplication increases the risk of inconsistency.

## Findings

**Source:** code-simplicity-reviewer agent (confidence: 92%)

**Locations:**
- `computer/parachute/mcp_server.py:536-543` — create_session validation
- `computer/parachute/mcp_server.py:644-651` — send_message validation (identical)

```python
# Lines 536-543 (create_session)
if len(initial_message) > 50_000:
    return {"error": "Initial message too long (max 50,000 characters)"}

control_chars = [c for c in initial_message if ord(c) < 32 and c not in '\n\r\t']
if control_chars:
    return {"error": "Initial message contains invalid control characters"}

# Lines 644-651 (send_message) — IDENTICAL except field name
if len(message) > 50_000:
    return {"error": "Message too long (max 50,000 characters)"}

control_chars = [c for c in message if ord(c) < 32 and c not in '\n\r\t']
if control_chars:
    return {"error": "Message contains invalid control characters"}
```

**Total duplication:** 8 lines repeated

## Proposed Solutions

### Option 1: Extract Helper Function (Recommended)
**Effort:** Small (15 minutes)
**Risk:** None

```python
def _validate_message_content(
    content: str,
    field_name: str = "message",
    max_length: int = 50_000
) -> Optional[str]:
    """Validate message content.

    Returns:
        Error message if invalid, None if valid.
    """
    if len(content) > max_length:
        return f"{field_name.capitalize()} too long (max {max_length:,} characters)"

    control_chars = [c for c in content if ord(c) < 32 and c not in '\n\r\t']
    if control_chars:
        return f"{field_name.capitalize()} contains invalid control characters"

    return None

# Usage in create_session:
if error := _validate_message_content(initial_message, "initial message"):
    return {"error": error}

# Usage in send_message:
if error := _validate_message_content(message):
    return {"error": error}
```

**Pros:**
- Single source of truth
- Easy to test in isolation
- Consistent error messages
- Walrus operator (`:=`) for clean usage

**Cons:**
- None

### Option 2: Pydantic Validator
**Effort:** Medium (30 minutes)
**Risk:** Low

```python
from pydantic import BaseModel, validator

class MessageContent(BaseModel):
    content: str

    @validator("content")
    def validate_content(cls, v):
        if len(v) > 50_000:
            raise ValueError("Content too long (max 50,000 characters)")
        control_chars = [c for c in v if ord(c) < 32 and c not in '\n\r\t']
        if control_chars:
            raise ValueError("Content contains invalid control characters")
        return v
```

**Pros:**
- Type-safe
- Integrates with FastAPI

**Cons:**
- Heavier weight for simple validation

## Recommended Action

**Extract helper function** (Option 1) — simple, testable, removes duplication.

## Technical Details

**Affected files:**
- `computer/parachute/mcp_server.py`

**Changes:**
1. Add `_validate_message_content()` helper function (after imports)
2. Replace lines 536-543 with single call
3. Replace lines 644-651 with single call
4. Add unit tests for `_validate_message_content()`

**LOC reduction:** ~6 lines (8 duplicated → 2 call sites + 1 helper definition)

## Acceptance Criteria

- [ ] Helper function `_validate_message_content()` created
- [ ] Used in both `create_session()` and `send_message()`
- [ ] Unit tests verify validation logic
- [ ] Error messages remain consistent
- [ ] No duplicate validation code

## Work Log

- 2026-02-22: Identified during code review by code-simplicity-reviewer agent

## Resources

- **Python Walrus operator:** https://peps.python.org/pep-0572/
- **Source PR:** feat/multi-agent-workspace-teams branch
- **Issue:** #35 (Multi-Agent Workspace Teams)
