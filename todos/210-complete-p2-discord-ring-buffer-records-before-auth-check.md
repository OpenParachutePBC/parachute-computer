---
status: complete
priority: p2
issue_id: "210"
tags: [code-review, security, python, chat]
dependencies: []
---

# Discord ring buffer records group messages before is_user_allowed check

## Problem Statement

In `discord_bot.py:on_text_message`, the ring buffer recording at line 154 fires before the `is_user_allowed` check at line 166. This means messages from disallowed or unknown users are silently stored in the group history buffer and will appear inside the `<group_context>` XML block prepended to subsequent AI sessions for legitimate users.

This is a mild prompt-injection risk: a disallowed user in the same Discord channel can craft a message that gets injected into an allowed user's AI context, influencing the model's responses.

**Cross-platform comparison:**
- Telegram (`telegram.py:323`) — `is_user_allowed` guard fires and returns early **before** `group_history.record` at line 342
- Matrix (`matrix_bot.py:363`) — authorization check fires before any recording
- Discord (`discord_bot.py:154`) — recording fires **before** the `is_user_allowed` guard at line 166

## Findings

- `discord_bot.py:154` — `self.group_history.record(...)` called before allowed-user gate
- `discord_bot.py:166` — `if not self.is_user_allowed(user_id): return`
- `telegram.py:323,342` — correct ordering: guard first, record second
- pattern-recognition-specialist confidence: 88

## Proposed Solutions

### Option 1: Move group_history.record after is_user_allowed check (Recommended)
Swap the order: check `is_user_allowed` first (return early if disallowed), then record to the ring buffer. Mirrors Telegram's structure exactly.

**Pros:** Closes prompt-injection vector, matches cross-platform pattern.
**Cons:** Disallowed users' messages are no longer buffered — minor context gap for group conversations.
**Effort:** Small (move ~4 lines)
**Risk:** Low

### Option 2: Keep recording all messages, sanitize content before injection
Continue buffering all senders but mark disallowed-user messages as untrusted in the buffer, and strip or annotate them when constructing `<group_context>`.

**Pros:** Preserves full conversation context for AI.
**Cons:** More complex; requires buffer schema change and sanitization logic.
**Effort:** Medium
**Risk:** Medium (more moving parts)

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py:154` (recording line)
- `computer/parachute/connectors/discord_bot.py:166` (guard line)

## Acceptance Criteria

- [ ] `group_history.record` moved to after the `is_user_allowed` early-return check
- [ ] Existing group history tests pass
- [ ] Behavior matches Telegram's ordering

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by pattern-recognition-specialist (confidence 88)
- Telegram comparison: `telegram.py:323,342` shows correct ordering

## Resources

- **PR:** #117
- **Issue:** #88
