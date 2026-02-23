---
status: pending
priority: p3
issue_id: "220"
tags: [code-review, performance, python, chat]
dependencies: []
---

# on_voice_message performs two DB session lookups

## Problem Statement

`discord_bot.py:on_voice_message` queries the database for the session twice: once early to check if a session exists (to decide whether to create one), and again later to pass the session ID to `_route_to_chat`. The second lookup is redundant — the first lookup already returned the session object.

## Findings

- `discord_bot.py:on_voice_message` — two `get_or_create_session` or similar calls
- performance-oracle confidence: 76

## Proposed Solutions

### Option 1: Cache the session object from the first lookup
Store the result of the first DB call in a local variable and reuse it for the second.

**Effort:** Tiny

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py` (on_voice_message)

## Acceptance Criteria

- [ ] Session DB lookup called exactly once per `on_voice_message` invocation

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code

## Resources

- **PR:** #117
