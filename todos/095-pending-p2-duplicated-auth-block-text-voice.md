---
status: pending
priority: p2
issue_id: 91
tags: [code-review, quality, python, matrix]
dependencies: []
---

# Duplicated auth block between `on_text_message` and `on_voice_message`

## Problem Statement

The bridge-aware authorization logic (bridge metadata lookup, chat type detection, room allowance check) is duplicated nearly verbatim between `on_text_message()` and `on_voice_message()`. This creates a maintenance burden — any fix to the auth logic must be applied in two places, and they can easily diverge.

## Findings

- **Source**: code-simplicity-reviewer (P1, confidence: 95), architecture-strategist (P1, confidence: 92), pattern-recognition-specialist (P2, confidence: 92), python-reviewer (P2, confidence: 90)
- **Location**: `computer/parachute/connectors/matrix_bot.py:293-340` (text handler auth) and `matrix_bot.py:468-510` (voice handler auth)
- **Evidence**: Both handlers perform the same sequence: get session by bot link, extract bridge metadata, determine chat type from bridge metadata or member count, check room allowance, check mention for groups. The voice handler is a near copy-paste of the text handler's auth block.

## Proposed Solutions

### Solution A: Extract shared `_authorize_room_message()` helper (Recommended)
Create a private method that encapsulates the auth block:
```python
async def _authorize_room_message(self, room, event) -> Optional[tuple[str, Optional[Session]]]:
    """Check auth and return (chat_type, session) or None if unauthorized."""
    # Bridge metadata lookup, chat type detection, room/mention checks
    ...
```

Both handlers call this method and proceed only if it returns a result.

- **Pros**: Single source of truth for auth logic, easier to maintain
- **Cons**: Adds one method
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/matrix_bot.py`

## Acceptance Criteria

- [ ] Auth logic exists in exactly one place
- [ ] Both `on_text_message` and `on_voice_message` use the shared helper
- [ ] Behavior is identical before and after refactor
- [ ] Tests pass

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
