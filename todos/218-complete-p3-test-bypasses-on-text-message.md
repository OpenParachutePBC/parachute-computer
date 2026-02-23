---
status: complete
priority: p3
issue_id: "218"
tags: [code-review, python, testing, quality, chat]
dependencies: []
---

# test_group_message_recorded_before_user_gate tests buffer directly instead of calling on_text_message

## Problem Statement

The test named `test_group_message_recorded_before_user_gate` calls `connector.group_history.record(...)` directly rather than calling `connector.on_text_message(...)`. This means the test verifies that the buffer works, not that `on_text_message` actually records to the buffer before the user gate. If the recording line is removed from `on_text_message`, the test will still pass.

## Findings

- `test_bot_connectors.py:TestDiscordRingBuffer.test_group_message_recorded_before_user_gate` — calls `group_history.record` directly
- python-reviewer confidence: 72; code-simplicity confidence: 85

## Proposed Solutions

### Option 1: Replace with integration-style test
Call `await connector.on_text_message(fake_message, None)` with a disallowed user ID. Then assert `connector.group_history.get_recent(5)` contains the message. This tests the actual behavior being claimed.

**Pros:** Test actually validates the production code path.
**Effort:** Small
**Risk:** Requires a mock Discord Message object

## Recommended Action

## Technical Details

**Affected files:**
- `computer/tests/unit/test_bot_connectors.py`

## Acceptance Criteria

- [ ] Test calls `on_text_message` rather than `group_history.record` directly
- [ ] If the record call is removed from `on_text_message`, the test fails

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code

## Resources

- **PR:** #117
