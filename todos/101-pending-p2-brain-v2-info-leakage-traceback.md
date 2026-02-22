---
status: completed
priority: p2
issue_id: 94
tags: [code-review, security, brain-v2, python]
dependencies: []
---

# Brain v2: Sensitive Information Leakage in HTTP Error Responses

## Problem Statement

Brain v2 exposes detailed exception tracebacks in HTTP 500 responses, potentially revealing sensitive information like file paths, environment details, and internal implementation. This affects all 7 FastAPI routes.

**Why it matters:** Security through obscurity isn't security, but unnecessary information disclosure expands the attack surface and aids reconnaissance for potential attackers.

## Findings

**Source:** security-sentinel agent (confidence: 85/100)

**Affected files:**
- `computer/modules/brain_v2/module.py:86-87, 100-101, 115-116, 135-136, 151-152, 167-168, 178-179`

**Current behavior:**
```python
except Exception as e:
    logger.error(f"Error creating entity: {e}", exc_info=True)
    raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(e))
```

**Evidence:** All routes use generic exception handlers that pass `str(e)` directly to HTTPException detail field. This can expose:
- Internal file paths from FileNotFoundError
- Database connection strings from connection errors
- Stack traces if exception message includes them

## Proposed Solutions

### Option A: Generic Error Messages (Recommended)
**Approach:** Replace `detail=str(e)` with static messages, log full details server-side

**Pros:**
- Minimal changes (7 lines)
- Zero information disclosure
- Aligns with security best practices

**Cons:**
- Slightly less helpful for debugging (but logs preserve full context)

**Effort:** Small (15 minutes)
**Risk:** Low

### Option B: Error Message Sanitization
**Approach:** Create sanitize_error_message() utility that strips paths/secrets

**Pros:**
- Preserves some useful error context
- Reusable across modules

**Cons:**
- More complex (requires pattern matching)
- Risk of incomplete sanitization

**Effort:** Medium (1 hour)
**Risk:** Medium

### Option C: Development vs Production Modes
**Approach:** Show full errors in dev, generic in prod based on environment variable

**Pros:**
- Best of both worlds
- Common pattern in web frameworks

**Cons:**
- Environment variable dependency
- Risk of misconfiguration in production

**Effort:** Medium (45 minutes)
**Risk:** Medium

## Recommended Action

(To be filled during triage)

## Technical Details

**Affected components:**
- All 7 Brain v2 FastAPI routes
- HTTPException handlers

**Implementation notes:**
- Option A: Replace 7 instances of `detail=str(e)` with `detail="Internal server error"`
- Keep existing `logger.error(..., exc_info=True)` for debugging
- Consider adding request_id to logs for correlation

## Acceptance Criteria

- [ ] HTTP 500 responses contain no file paths
- [ ] HTTP 500 responses contain no exception types
- [ ] Server logs preserve full exception details with exc_info=True
- [ ] All 7 routes updated consistently
- [ ] Manual test: Trigger error, verify response shows generic message

## Work Log

### 2026-02-22
- **Created:** security-sentinel agent flagged during /para-review of PR #97

## Resources

- **PR:** #97 (Brain v2 TerminusDB MVP)
- **Review agent:** security-sentinel
- **OWASP:** [A01:2021 – Broken Access Control](https://owasp.org/Top10/A01_2021-Broken_Access_Control/)
