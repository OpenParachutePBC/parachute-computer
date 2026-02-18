---
status: pending
priority: p3
issue_id: 55
tags: [code-review, security, python, bot-connector]
dependencies: []
---

# Auth Error Detection Via Exception Class Name is Fragile

## Problem Statement

Fatal auth error fast-fail in `_run_with_reconnect()` matches on `type(e).__name__` against a string set `("InvalidToken", "LoginFailure", "Unauthorized", "Forbidden")`. This is fragile because:
1. Library updates could rename exception classes
2. Subclasses won't match if they have different names
3. String matching bypasses Python's type system

## Findings

- **Source**: security-sentinel (F3, confidence 80)
- **Location**: `computer/parachute/connectors/base.py` — `_run_with_reconnect()` auth check
- **Evidence**: Uses `type(e).__name__ in (...)` instead of `isinstance()` checks

## Proposed Solutions

### Solution A: Keep string matching with test coverage (Recommended)
The string matching is intentional — `base.py` cannot import platform-specific exceptions without coupling to optional dependencies. Add a test that verifies the exception names still exist in current library versions.
- **Pros**: No coupling to optional deps, current approach is pragmatic
- **Cons**: Still fragile to renames
- **Effort**: Small (just add validation test)
- **Risk**: Low

### Solution B: Platform-specific _is_fatal_error method
Let each connector override a method:
```python
def _is_fatal_auth_error(self, exc: Exception) -> bool:
    return isinstance(exc, (discord.LoginFailure,))
```
- **Pros**: Type-safe, extensible
- **Cons**: More code, each platform must override
- **Effort**: Medium
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/base.py`, optionally platform connectors
- **Database changes**: None

## Acceptance Criteria

- [ ] Fatal auth errors are reliably detected
- [ ] Test coverage validates exception class names exist

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from /para-review | Pragmatic trade-off — string matching avoids optional dep coupling |

## Resources

- PR branch: `feat/bot-connector-resilience`
- Issue: #55
