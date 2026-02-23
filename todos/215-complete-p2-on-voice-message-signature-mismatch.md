---
status: complete
priority: p2
issue_id: "215"
tags: [code-review, python, quality, chat]
dependencies: []
---

# on_voice_message signature doesn't match base class declaration

## Problem Statement

`BotConnector.on_voice_message` declares `(self, update: Any, context: Any)` (no default for `context`). Discord's override is `(self, update: Any, context: Any = None)`. This signature mismatch means:

1. Mypy/pyright will flag this as an override incompatibility (Liskov substitution violation)
2. The base class says `context` is required; Discord says it's optional — callers of the base class type will not know the parameter can be omitted

This was likely introduced to match the call site `await self.on_voice_message(message, None)` inside `on_message`, but the correct fix is to either update the base class signature or pass `None` explicitly (which already happens at the call site).

## Findings

- `discord_bot.py:271` — `async def on_voice_message(self, update: Any, context: Any = None)` — `= None` not in base
- `base.py:on_voice_message` — `async def on_voice_message(self, update: Any, context: Any)` — required parameter
- python-reviewer confidence: 83; architecture-strategist confidence: 85

## Proposed Solutions

### Option 1: Remove default from Discord override (Recommended)
Change `context: Any = None` to `context: Any` in `discord_bot.py:on_voice_message`. The call site already passes `None` explicitly.

**Pros:** Restores Liskov substitution compliance, trivial change.
**Effort:** Tiny
**Risk:** None

### Option 2: Add default to base class signature
Change `base.py:on_voice_message` to `context: Any = None`.

**Pros:** Consistent with how all connectors call it (always passing `None`).
**Cons:** Weakens the interface contract; encourages callers to omit context.
**Effort:** Tiny
**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py:271`
- `computer/parachute/connectors/base.py:on_voice_message`

## Acceptance Criteria

- [ ] Discord's `on_voice_message` signature matches base class
- [ ] Mypy/pyright reports no override incompatibility
- [ ] Behavior unchanged

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by python-reviewer (confidence 83)

## Resources

- **PR:** #117
- **Issue:** #88
