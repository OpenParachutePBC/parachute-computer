---
status: pending
priority: p2
issue_id: 67
tags: [code-review, bot-connector, python, agent-native]
dependencies: []
---

# Bot Connectors Discard Warning Events

## Problem Statement

The Flutter app renders MCP/attachment warnings as inline blockquotes. Bot users (Telegram, Discord) see nothing when MCP tools vanish or attachments fail — the `warning` event type falls through the connector event loops unhandled.

## Findings

- **Source**: agent-native-reviewer (confidence 88)
- **Location**: `computer/parachute/connectors/telegram.py:586`, `computer/parachute/connectors/discord_bot.py:439`
- **Evidence**: Neither connector has a `warning` case in their event processing loops.

## Proposed Solutions

### Solution A: Add `warning` handling to both connectors (Recommended)
Add `elif event_type == "warning"` that appends a brief warning line to the response text.
- **Pros**: Parity with Flutter app experience
- **Cons**: Two files to change
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

**Affected files:**
- `computer/parachute/connectors/telegram.py`
- `computer/parachute/connectors/discord_bot.py`

## Acceptance Criteria

- [ ] Telegram connector renders warnings as brief inline text
- [ ] Discord connector renders warnings as brief inline text

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #67 review | New event types must be handled by all consumers, not just Flutter |

## Resources

- PR: #67
- Issue: #49
