---
status: pending
priority: p2
issue_id: 55
tags: [code-review, python, quality, bot-connector]
dependencies: []
---

# _fire_hook Event Param Typed Any Instead of HookEvent

## Problem Statement

`BotConnector._fire_hook()` accepts `event: Any` instead of the more specific `HookEvent` enum type. This weakens type safety and allows passing arbitrary strings where only `HookEvent` values should be used.

## Findings

- **Source**: python-reviewer (F3, confidence 85)
- **Location**: `computer/parachute/connectors/base.py` — `_fire_hook` method signature
- **Evidence**: The method is always called with `HookEvent.BOT_CONNECTOR_DOWN` or `HookEvent.BOT_CONNECTOR_RECONNECTED`, but the signature allows any value.

## Proposed Solutions

### Solution A: Type the parameter as HookEvent (Recommended)
```python
async def _fire_hook(self, event: "HookEvent", **kwargs: Any) -> None:
```
Use a string annotation to avoid circular import if needed.
- **Pros**: Type safety, IDE support, catches mistakes
- **Cons**: May need TYPE_CHECKING import
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/connectors/base.py`
- **Database changes**: None

## Acceptance Criteria

- [ ] `_fire_hook` event parameter typed as `HookEvent`
- [ ] Type checker passes

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from /para-review | |

## Resources

- PR branch: `feat/bot-connector-resilience`
- Issue: #55
