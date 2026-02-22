---
status: pending
priority: p3
issue_id: 91
tags: [code-review, testing, python, matrix]
dependencies: []
---

# Missing test for `_handle_bridged_room()`

## Problem Statement

`_handle_bridged_room()` is the core method that creates pairing requests and pending sessions for bridged rooms, but it has no dedicated unit test. The existing tests cover `_detect_bridge_room()` and the allowlist, but not the pairing request creation flow.

## Findings

- **Source**: pattern-recognition-specialist (P3, confidence: 80)
- **Location**: `computer/parachute/connectors/matrix_bot.py:222-289` (`_handle_bridged_room`)
- **Evidence**: `TestDetectBridgeRoom` tests detection logic, `TestAllowlistRoomApproval` tests allowlist persistence, but no test verifies that `_handle_bridged_room` creates a pairing request with correct fields, creates a pending session, or sends the room notice.

## Proposed Solutions

### Solution A: Add `TestHandleBridgedRoom` test class (Recommended)
Test that:
- Pairing request is created with correct platform/user_id/display fields
- Pending session is created with bridge metadata
- Room notice is sent
- Duplicate invites don't create duplicate pairing requests

- **Pros**: Covers the most important new behavior
- **Cons**: Requires mocking database and client
- **Effort**: Medium
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/tests/unit/test_bot_connectors.py`

## Acceptance Criteria

- [ ] Test verifies pairing request creation with correct fields
- [ ] Test verifies pending session creation with bridge metadata
- [ ] Test verifies duplicate pairing requests are not created

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
