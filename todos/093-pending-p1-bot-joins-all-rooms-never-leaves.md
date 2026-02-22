---
status: pending
priority: p1
issue_id: 91
tags: [code-review, security, python, matrix]
dependencies: []
---

# Bot auto-joins all rooms and never leaves non-bridged ones

## Problem Statement

When the Matrix bot receives a room invite, `_on_invite()` unconditionally joins the room before checking if it's bridged. If the room is not bridged and not in `allowed_rooms`, the bot remains in the room permanently — it never leaves. Combined with `_is_room_allowed()` returning `True` when `allowed_rooms` is empty (allow-all default), this means any user on the homeserver can invite the bot into any room and it will stay there, processing messages.

This creates an unauthorized room persistence issue: the bot accumulates room memberships it should not have.

## Findings

- **Source**: security-sentinel (P1, confidence: 92), python-reviewer (P2, confidence: 82), architecture-strategist (P2, confidence: 90)
- **Location**: `computer/parachute/connectors/matrix_bot.py:181-220` (`_on_invite` method)
- **Evidence**: Line 197 joins the room unconditionally. Lines 200-218 check for bridge patterns, but the `else` branch (non-bridged, non-allowed) has no `leave()` call. The bot stays in the room indefinitely.
- **Compounding factor**: `_is_room_allowed()` at line 653 returns `True` when `allowed_rooms` is empty, so if the user hasn't configured any rooms, every room is allowed.

## Proposed Solutions

### Solution A: Leave non-bridged, non-allowed rooms (Recommended)
After bridge detection, if the room is neither bridged nor allowed, leave it:
```python
if bridge_info:
    await self._handle_bridged_room(room_id, room_name, bridge_info)
else:
    # Not bridged, not allowed — leave the room
    await self._client.room_leave(room_id)
    logger.info("Left non-bridged, non-allowed room %s", room_id)
```

- **Pros**: Clean, simple, prevents room accumulation
- **Cons**: None
- **Effort**: Small
- **Risk**: Low

### Solution B: Only join if bridge-bot is in the invite
Don't join the room unless the inviter matches a known bridge bot pattern. This prevents joining random rooms entirely.

- **Pros**: Most secure — never joins unknown rooms
- **Cons**: Requires inspecting the invite event sender before joining; may miss some bridge setups where invites come from the admin user
- **Effort**: Small
- **Risk**: Medium — could miss legitimate bridge invites

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/matrix_bot.py`
- **Lines**: 181-220 (`_on_invite`), 653-661 (`_is_room_allowed`)

## Acceptance Criteria

- [ ] Bot leaves rooms that are not bridged and not in `allowed_rooms`
- [ ] Bot does not accumulate memberships in unauthorized rooms
- [ ] Bridged rooms still get pairing requests as before
- [ ] Already-allowed rooms still get joined normally

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|

## Resources

- PR #91: feat(matrix): bridge-aware room detection and auto-pairing
- Issue #85: Bridge-aware Matrix connector
