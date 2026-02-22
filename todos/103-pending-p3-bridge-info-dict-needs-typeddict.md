---
status: pending
priority: p3
issue_id: 91
tags: [code-review, quality, python, matrix]
dependencies: []
---

# `bridge_info: dict` should use TypedDict

## Problem Statement

`_detect_bridge_room()` returns `Optional[dict]` with keys `bridge_type`, `ghost_users`, `remote_chat_type`. Callers access these keys by string without type safety. A `TypedDict` would provide static analysis support and document the expected shape.

## Findings

- **Source**: python-reviewer (P3, confidence: 85)
- **Location**: `computer/parachute/connectors/matrix_bot.py:587-634` (`_detect_bridge_room` return type)
- **Evidence**: Return type is `Optional[dict]`, callers use `bridge_info["remote_chat_type"]`, `bridge_info.get("bridge_type")` etc. No type safety.

## Proposed Solutions

### Solution A: Add `BridgeInfo` TypedDict (Recommended)
```python
class BridgeInfo(TypedDict):
    bridge_type: str
    ghost_users: list[str]
    remote_chat_type: str  # "dm" | "group"
```

- **Pros**: Type safety, self-documenting
- **Cons**: Minor addition
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/matrix_bot.py`

## Acceptance Criteria

- [ ] `_detect_bridge_room` returns `Optional[BridgeInfo]` with TypedDict
- [ ] All callers type-check correctly

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
