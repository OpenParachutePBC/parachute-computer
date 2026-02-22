---
status: pending
priority: p3
issue_id: 62
tags: [code-review, python, quality, error-handling]
created: 2026-02-21
---

# Silent Validator Failure in Workspace Trust Level Normalization

## Problem Statement

The `normalize_trust` field validators in `WorkspaceConfig`, `WorkspaceCreate`, and `WorkspaceUpdate` catch `ValueError` from `normalize_trust_level()` and silently return the invalid value instead of propagating the error. This defeats the purpose of the explicit error message in `normalize_trust_level()` and results in opaque Pydantic validation errors.

**Impact:** Low-medium - Users get unhelpful error messages when providing invalid trust levels, losing the detailed guidance from `normalize_trust_level()`.

**Introduced in:** Commit 8f93d13 (trust level normalization)

## Findings

**Source:** Python Reviewer (Confidence: 88)

**Current code pattern (appears 3 times):**
```python
@field_validator("default_trust_level", mode="before")
@classmethod
def normalize_trust(cls, v: Any) -> Any:
    if isinstance(v, str):
        from parachute.core.trust import normalize_trust_level
        try:
            return normalize_trust_level(v)
        except ValueError:
            return v  # BUG: Returns invalid value unchanged
    return v
```

**Why this is wrong:**

**User sends:**
```json
{"default_trust_level": "invalid_value"}
```

**What happens:**
1. Validator catches `ValueError`, returns `"invalid_value"` unchanged
2. Pydantic's `TrustLevelStr = Literal["direct", "sandboxed"]` constraint fails
3. User sees: `Input should be 'direct' or 'sandboxed'`

**What should happen:**
1. Validator lets `ValueError` propagate
2. Pydantic converts to validation error preserving message
3. User sees: `Unknown trust level: 'invalid_value'. Valid values: direct, sandboxed, trusted, untrusted, full, vault`

**Locations:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/models/workspace.py:109-118` (WorkspaceConfig)
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/models/workspace.py:142-151` (WorkspaceCreate)
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/models/workspace.py:165-174` (WorkspaceUpdate)

## Proposed Solutions

### Solution 1: Remove Silent Catch (Recommended)

**Approach:** Let `ValueError` propagate to Pydantic's error handling.

**Implementation:**
```python
@field_validator("default_trust_level", mode="before")
@classmethod
def normalize_trust(cls, v: Any) -> Any:
    if isinstance(v, str):
        from parachute.core.trust import normalize_trust_level
        return normalize_trust_level(v)  # Let ValueError propagate
    return v
```

Pydantic v2 automatically converts `ValueError` to a validation error with the message preserved.

**Pros:**
- Helpful error messages for users
- Simpler code (removes try/except)
- Leverages Pydantic's error handling

**Cons:**
- None

**Effort:** Minimal (5 minutes - remove 6 lines)
**Risk:** Very low

### Solution 2: Explicit Re-raise with Context

**Approach:** Catch and re-raise with additional context.

**Implementation:**
```python
@field_validator("default_trust_level", mode="before")
@classmethod
def normalize_trust(cls, v: Any) -> Any:
    if isinstance(v, str):
        from parachute.core.trust import normalize_trust_level
        try:
            return normalize_trust_level(v)
        except ValueError as e:
            raise ValueError(f"Invalid default_trust_level: {e}") from e
    return v
```

**Pros:**
- Adds field name context
- Still preserves original error message

**Cons:**
- More verbose than Solution 1
- Pydantic already adds field context

**Effort:** Small (10 minutes)
**Risk:** Very low

## Recommended Action

Implement **Solution 1** - remove the `except ValueError: return v` pattern entirely. Pydantic v2's error handling will provide clear, helpful error messages automatically.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/models/workspace.py:109-118, 142-151, 165-174`

**Components:**
- Workspace model validation
- Trust level normalization

**Database changes:** None

**API impact:**
- Improved error messages in API responses
- No breaking changes (invalid input still fails validation)

## Acceptance Criteria

- [ ] Remove `try/except ValueError` from all three `normalize_trust` validators
- [ ] Verify error message includes helpful guidance from `normalize_trust_level()`
- [ ] Test with invalid trust level value (e.g., `"invalid"`)
- [ ] Confirm error message includes: "Valid values: direct, sandboxed, trusted, untrusted, full, vault"
- [ ] All existing tests pass

## Work Log

- **2026-02-21**: Issue identified during Python code review of commit 8f93d13

## Resources

**Related commits:**
- 8f93d13 - feat(sandbox): trust level rename + default container

**Pydantic docs:**
- https://docs.pydantic.dev/latest/concepts/validators/#field-validators
- https://docs.pydantic.dev/latest/errors/errors/
