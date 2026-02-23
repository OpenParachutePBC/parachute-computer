---
status: complete
priority: p2
issue_id: "209"
tags: [code-review, python, quality, chat]
dependencies: []
---

# 'message' parameter shadowed by local variable in _route_to_chat

## Problem Statement

In `_route_to_chat(self, session_id: str, message: str)`, the `message` parameter is rebound as a local variable inside the `typed_error` and `warning` event handlers:

```python
async for event in orchestrate(session_id=session_id, message=message, ...):
    ...
    elif event_type == "typed_error":
        message = event.get("content", "")   # ← shadows the parameter!
        response_text = f"Error: {message}"
    elif event_type == "warning":
        message = event.get("content", "")   # ← shadows again
        response_text = f"Warning: {message}"
```

This PR introduced this shadowing in `matrix_bot.py` by renaming `msg` → `message` to match `discord_bot.py`. The `discord_bot.py` version already had the same pattern. After the rebinding, the original `message` (the user's input text) is lost within the loop body. While the current code doesn't reuse `message` after the rebind in the same loop iteration, the pattern is fragile and will silently produce wrong behavior if future code needs to reference the original message inside those branches.

## Findings

- `discord_bot.py:503` — `message = event.get("content", "")` inside `typed_error` handler
- `discord_bot.py:508` — `message = event.get("content", "")` inside `warning` handler
- `matrix_bot.py:819` — same pattern (introduced by this PR's `msg→message` rename)
- `matrix_bot.py:824` — same pattern
- python-reviewer confidence: 88

## Proposed Solutions

### Option 1: Use distinct variable name for event content (Recommended)
Replace `message = event.get("content", "")` with `error_content = event.get("content", "")` (or `event_content`) in both handlers. Update the `f"Error: {message}"` and `f"Warning: {message}"` to use the new name.

**Pros:** Eliminates shadowing, zero behavioral change, improves readability.
**Effort:** Small
**Risk:** None

### Option 2: Move _route_to_chat to base class with source parameter
If `_route_to_chat` is refactored into `BotConnector` (see duplication todo), the fix can be included as part of that refactor.

**Pros:** Fixes duplication and shadowing together.
**Cons:** Larger scope than necessary for this issue alone.
**Effort:** Medium

## Recommended Action

## Technical Details

**Affected files:**
- `computer/parachute/connectors/discord_bot.py:503,508`
- `computer/parachute/connectors/matrix_bot.py:819,824`

## Acceptance Criteria

- [ ] No local variable named `message` shadows the `message` parameter in `_route_to_chat`
- [ ] Event content uses a distinct name (`error_content`, `event_content`, etc.)
- [ ] Tests pass without modification

## Work Log

### 2026-02-23 - Code Review Discovery

**By:** Claude Code
**Actions:**
- Found during PR #117 review by python-reviewer (confidence 88)
- The matrix_bot.py instance was introduced by this PR's `msg→message` rename

## Resources

- **PR:** #117
- **Issue:** #88
