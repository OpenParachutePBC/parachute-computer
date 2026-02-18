---
status: pending
priority: p2
issue_id: 55
tags: [code-review, security, python, bot-connector]
dependencies: []
---

# _SENSITIVE_PATTERNS Regex Gaps for Token Sanitization

## Problem Statement

The `_SENSITIVE_PATTERNS` list in `base.py` catches `bot_token=...` and `token=...` patterns but misses:
1. Bare Telegram bot tokens (format: `123456:ABC-DEF...`)
2. URL-embedded tokens (e.g., `https://api.telegram.org/bot<token>/...`)

If an exception message contains a raw token string, `_sanitize_error()` won't catch it.

## Findings

- **Source**: security-sentinel (F2, confidence 85)
- **Location**: `computer/parachute/connectors/base.py` — `_SENSITIVE_PATTERNS` list
- **Evidence**: Current patterns are `r"bot_token=[^\s,]+"`, `r"token=[^\s,]+"`, `r"/home/[^\s]+"`, `r"C:\\Users\\[^\s]+"`. Missing: bare Telegram token format `\d+:[A-Za-z0-9_-]+` and URL-embedded tokens.

## Proposed Solutions

### Solution A: Add Telegram token pattern (Recommended)
Add a regex for the Telegram bot token format:
```python
_SENSITIVE_PATTERNS = [
    # ... existing patterns ...
    r"\d{8,}:[A-Za-z0-9_-]{30,}",  # Bare Telegram bot tokens
]
```
- **Pros**: Catches the most likely leak vector
- **Cons**: Could false-positive on other numeric:alpha strings (unlikely in error messages)
- **Effort**: Small
- **Risk**: Low

### Solution B: Add URL-embedded token pattern too
Also catch `https://api.telegram.org/bot<token>/`:
```python
r"api\.telegram\.org/bot[^\s/]+",
```
- **Pros**: Comprehensive
- **Cons**: Marginal — these URLs rarely appear in exceptions
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/base.py`
- **Database changes**: None

## Acceptance Criteria

- [ ] Bare Telegram tokens in error messages are sanitized
- [ ] Existing sanitization tests still pass
- [ ] New test: verify bare token format is caught

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from /para-review | Defense in depth — sanitize what you can |

## Resources

- PR branch: `feat/bot-connector-resilience`
- Issue: #55
