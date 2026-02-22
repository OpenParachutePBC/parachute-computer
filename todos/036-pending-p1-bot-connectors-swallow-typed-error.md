---
status: pending
priority: p1
issue_id: 67
tags: [code-review, bot-connector, python, agent-native]
dependencies: []
---

# Bot Connectors Silently Swallow `typed_error` Events

## Problem Statement

Both Telegram and Discord connectors only match `event_type == "error"`. This PR converts the main error paths from `ErrorEvent` (type `"error"`) to `TypedErrorEvent` (type `"typed_error"`). The new event type falls through unmatched, so bot users get no error feedback at all — the connector either sends partial text or "No response from agent."

This is a regression introduced by this PR for agent/bot users.

## Findings

- **Source**: agent-native-reviewer (confidence 95)
- **Location**: `computer/parachute/connectors/telegram.py:586`, `computer/parachute/connectors/discord_bot.py:439`
- **Evidence**: Both connectors' event loops only check `event_type == "error"`. After PR #67, the primary error paths emit `typed_error` instead.

## Proposed Solutions

### Solution A: Add `typed_error` handling to both connectors (Recommended)
Add `elif event_type == "typed_error"` that extracts `title` and `message` from the event dict and formats a user-friendly error message.
- **Pros**: Fixes the regression, gives bot users structured error feedback
- **Cons**: Two files to change
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

**Affected files:**
- `computer/parachute/connectors/telegram.py` — event processing loop
- `computer/parachute/connectors/discord_bot.py` — event processing loop

## Acceptance Criteria

- [ ] Telegram connector handles `typed_error` events and sends error message to user
- [ ] Discord connector handles `typed_error` events and sends error message to user
- [ ] Bot users see meaningful error messages instead of silence

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #67 review | typed_error is a new terminal event type that must be handled by all consumers |

## Resources

- PR: #67
- Issue: #49
