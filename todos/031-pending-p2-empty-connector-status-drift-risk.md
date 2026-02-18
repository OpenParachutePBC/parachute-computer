---
status: pending
priority: p2
issue_id: 55
tags: [code-review, python, quality, bot-connector]
dependencies: []
---

# _EMPTY_CONNECTOR_STATUS Dict Risks Drift from BotConnector.status

## Problem Statement

`bots.py` defines `_EMPTY_CONNECTOR_STATUS` as a hardcoded dict that mirrors the shape of `BotConnector.status` property output. If `status` gains new fields, the empty dict won't be updated, causing inconsistent API responses between running and stopped connectors.

## Findings

- **Source**: code-simplicity-reviewer (F1, confidence 92), python-reviewer (F4, confidence 82)
- **Location**: `computer/parachute/api/bots.py` — `_EMPTY_CONNECTOR_STATUS` constant
- **Evidence**: The dict has keys `state`, `uptime_seconds`, `started_at`, `last_error`, `reconnect_attempts`, `last_message_time` matching the `BotConnector.status` property. If `status` adds a field, the constant drifts silently.

## Proposed Solutions

### Solution A: Use a class method for the empty/default status (Recommended)
Add a `@classmethod` or `@staticmethod` to `BotConnector` that returns the default status dict:
```python
@staticmethod
def empty_status() -> dict:
    return {"state": "stopped", "uptime_seconds": None, ...}
```
- **Pros**: Single source of truth, no drift
- **Cons**: Adds a method to the base class
- **Effort**: Small
- **Risk**: Low

### Solution B: Keep the constant but add a comment/test
Add a test that asserts `_EMPTY_CONNECTOR_STATUS.keys() == connector.status.keys()`.
- **Pros**: Catches drift at test time
- **Cons**: Doesn't prevent drift, just detects it
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/api/bots.py`, optionally `computer/parachute/connectors/base.py`
- **Database changes**: None

## Acceptance Criteria

- [ ] Empty status and live status have identical key sets
- [ ] Adding a field to `status` property cannot silently drift

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from /para-review | Two agents flagged independently |

## Resources

- PR branch: `feat/bot-connector-resilience`
- Issue: #55
