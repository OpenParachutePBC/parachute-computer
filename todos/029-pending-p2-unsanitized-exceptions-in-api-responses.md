---
status: pending
priority: p2
issue_id: 55
tags: [code-review, security, python, bot-connector]
dependencies: []
---

# Unsanitized Exception Messages Exposed in API Responses

## Problem Statement

Three API endpoints in `bots.py` pass raw `str(e)` into HTTP responses. Exception messages may contain sensitive information like file paths, connection strings, or internal state that should not be exposed to API consumers.

## Findings

- **Source**: security-sentinel (F1, confidence 92)
- **Location**: `computer/parachute/api/bots.py` lines 286, 303, 347
- **Evidence**:
  - Line 286: `raise HTTPException(status_code=500, detail=str(e))` in start endpoint
  - Line 303: `return {"success": False, "error": str(e)}` in stop endpoint
  - Line 347: `return {"success": False, "error": str(e)}` in test endpoint

## Proposed Solutions

### Solution A: Use generic error messages (Recommended)
Replace `str(e)` with generic messages, log the actual exception:
```python
except Exception as e:
    logger.error(f"Failed to start {platform} connector: {e}", exc_info=True)
    raise HTTPException(status_code=500, detail=f"Failed to start {platform} connector")
```
- **Pros**: No information leakage, simple
- **Cons**: Less helpful for debugging via API
- **Effort**: Small
- **Risk**: Low

### Solution B: Use `_sanitize_error` from base connector
Apply the same `_sanitize_error()` pattern that already exists in the connector base class.
- **Pros**: Consistent sanitization, reuses existing logic
- **Cons**: `_sanitize_error` is an instance method, would need to be made a module-level function
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/api/bots.py`
- **Database changes**: None

## Acceptance Criteria

- [ ] No raw exception messages in HTTP responses
- [ ] Actual exceptions still logged server-side
- [ ] API consumers get helpful but safe error messages

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from /para-review | Standard OWASP guidance — don't expose internals |

## Resources

- PR branch: `feat/bot-connector-resilience`
- Issue: #55
