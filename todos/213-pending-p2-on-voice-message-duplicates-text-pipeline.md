---
status: pending
priority: p2
issue_id: "213"
tags: [code-review, python, architecture, quality, chat]
dependencies: []
---

# on_voice_message duplicates ~45 lines from on_text_message

## Problem Statement

Discord's `on_voice_message` manually reimplements the session-lookup, ack, route, reply, and remove-ack pipeline that already exists in `on_text_message`. The two methods share ~45 lines of logic that could be extracted. Telegram established a `_process_text_message` internal helper pattern for exactly this purpose. Discord and Matrix skipped this abstraction, leaving a dual-maintenance burden.

If the chat pipeline changes (e.g., new ack mechanic, session lookup change, error handling update), the fix must be applied to both `on_text_message` and `on_voice_message` in Discord, and potentially in Matrix as well.

## Findings

- `discord_bot.py:271-348` — `on_voice_message` contains ~45 lines duplicating the session/ack/route/reply pipeline
- `discord_bot.py:195-268` — `on_text_message` contains the same pipeline
- `telegram.py:_process_text_message` — existing abstraction that avoids this duplication
- architecture-strategist confidence: 88; code-simplicity confidence: 88

## Proposed Solutions

### Option 1: Extract _process_text_message helper in Discord and Matrix
Create `async def _process_text_message(self, session_id, text, user_id, display_name, chat_type, ack_fn)` that handles: ack → route → reply → remove-ack. Both `on_text_message` and `on_voice_message` call into this helper after their own auth/setup.

**Pros:** Mirrors Telegram's pattern, single pipeline to maintain, clear separation of "receive+decode" vs "process".
**Effort:** Medium
**Risk:** Low — pure refactor, behavior unchanged

### Option 2: Move shared pipeline to BotConnector base class
Implement `_process_text_message` in `BotConnector` as a template method with platform-specific hooks for ack/remove-ack.

**Pros:** Cross-platform consistency, one implementation.
**Cons:** Base class becomes more complex; Discord and Matrix ack mechanics differ significantly.
**Effort:** Large
**Risk:** Medium

### Option 3: Leave as-is with a comment
Add `# TODO: extract shared pipeline (see telegram._process_text_message)` to both methods.

**Pros:** Zero risk.
**Cons:** Debt accumulates.
**Effort:** Tiny

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py:195-348`
- `computer/parachute/connectors/telegram.py:_process_text_message`

## Acceptance Criteria

- [ ] Shared session/ack/route/reply/remove-ack pipeline extracted to helper method
- [ ] Both `on_text_message` and `on_voice_message` delegate to the helper
- [ ] All 21 existing bot connector tests pass unchanged

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by architecture-strategist (88) and code-simplicity (88)
- Telegram `_process_text_message` is the established pattern to follow

## Resources

- **PR:** #117
- **Issue:** #88
