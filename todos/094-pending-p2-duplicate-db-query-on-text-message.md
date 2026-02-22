---
status: pending
priority: p2
issue_id: 91
tags: [code-review, performance, python, matrix]
dependencies: []
---

# Duplicate DB query in `on_text_message()`

## Problem Statement

`on_text_message()` calls `db.get_session_by_bot_link("matrix", room_id)` twice per message — once at line 304 for bridge metadata lookup, and again at line 349 for session routing. This doubles the database round-trips for every incoming Matrix message.

## Findings

- **Source**: performance-oracle (P1, confidence: 95), python-reviewer (P1, confidence: 92), architecture-strategist (P2, confidence: 90), code-simplicity-reviewer (P2, confidence: 92), pattern-recognition-specialist (P2, confidence: 88)
- **Location**: `computer/parachute/connectors/matrix_bot.py:304` and `matrix_bot.py:349`
- **Evidence**: Line 304: `session = await db.get_session_by_bot_link("matrix", room_id) if db else None` — used for bridge metadata. Line 349: `session = await db.get_session_by_bot_link("matrix", room_id) if db else None` — used for session routing. Identical call.

## Proposed Solutions

### Solution A: Hoist the DB call to a single location (Recommended)
Move the first `get_session_by_bot_link` call earlier and reuse the result:
```python
# Single DB lookup, reused for bridge metadata and session routing
session = await db.get_session_by_bot_link("matrix", room_id) if db else None
bridge_meta = (session.metadata or {}).get("bridge_metadata") if session else None
# ... later ...
# Reuse `session` instead of querying again
```

- **Pros**: Halves DB queries per message, trivial change
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/matrix_bot.py`
- **Lines**: 304, 349

## Acceptance Criteria

- [ ] Only one `get_session_by_bot_link` call per message
- [ ] Bridge metadata and session routing both use the same result
- [ ] All existing tests pass

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
