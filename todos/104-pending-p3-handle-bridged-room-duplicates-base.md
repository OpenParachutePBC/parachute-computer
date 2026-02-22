---
status: pending
priority: p3
issue_id: 91
tags: [code-review, architecture, python, matrix]
dependencies: []
---

# `_handle_bridged_room` duplicates base class pairing pattern

## Problem Statement

`_handle_bridged_room()` reimplements much of the pairing request creation logic that already exists in the base `BotConnector.handle_unknown_user()` method (base.py:291-353). Both create a pairing request, create a pending session with metadata, and send a notice. The Matrix version adapts this for room-based pairing but doesn't call or extend the base method.

## Findings

- **Source**: architecture-strategist (P3, confidence: 82), pattern-recognition-specialist (P3, confidence: 82)
- **Location**: `computer/parachute/connectors/matrix_bot.py:222-289` vs `computer/parachute/connectors/base.py:291-353`
- **Evidence**: Both methods follow the same sequence: check for existing pairing request → create pairing request → create pending session → send notice. The Matrix version differs in using `room_id` as `platform_user_id` and adding `bridge_metadata`.

## Proposed Solutions

### Solution A: Refactor base class to support room-based pairing
Add optional parameters to `handle_unknown_user()` for room-based pairing (room_id, bridge_metadata), so Matrix can call `super().handle_unknown_user()` with room context.

- **Pros**: DRY, single pairing flow
- **Cons**: Increases base class complexity for one platform's use case
- **Effort**: Medium
- **Risk**: Medium — changes shared code

### Solution B: Accept the duplication with a comment (Recommended for now)
Document that `_handle_bridged_room` is intentionally separate because room-based pairing is semantically different from user-based pairing. Revisit if more platforms need room-based pairing.

- **Pros**: Keeps base class simple, avoids premature abstraction
- **Cons**: Duplication remains
- **Effort**: Small (comment only)
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/matrix_bot.py`, potentially `computer/parachute/connectors/base.py`

## Acceptance Criteria

- [ ] Either: base class supports room-based pairing and Matrix uses it
- [ ] Or: duplication is documented with rationale for keeping it separate

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
- Base connector: `computer/parachute/connectors/base.py:291-353`
