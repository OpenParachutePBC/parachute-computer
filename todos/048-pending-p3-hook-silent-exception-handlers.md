---
status: pending
priority: p3
issue_id: 73
tags: [code-review, python, error-handling]
dependencies: []
---

# Silent Exception Handlers in Activity Hook Helpers

## Problem Statement

Four helper functions in `activity_hook.py` use bare `except Exception:` with no logging, making debugging difficult. The top-level handler (line 148) logs warnings, but helper failures are invisible.

## Findings

- **Sources**: pattern-recognition-specialist (confidence 85), python-reviewer (confidence 82)
- **Locations**:
  - `computer/parachute/hooks/activity_hook.py:257-258` (`get_session_title`)
  - `computer/parachute/hooks/activity_hook.py:268-269` (`get_session_with_title`)
  - `computer/parachute/hooks/activity_hook.py:279-280` (`get_session_agent_type`)
  - `computer/parachute/hooks/activity_hook.py:381-382` (`get_daily_summarizer_session`)

## Proposed Solutions

### Solution A: Add debug-level logging (Recommended)
```python
except Exception as e:
    logger.debug(f"Failed to get session title for {session_id[:8]}: {e}")
    return None
```
- **Pros**: Aids debugging without polluting production logs
- **Effort**: Small (10 min)
- **Risk**: None

## Recommended Action

<!-- Filled during triage -->

## Acceptance Criteria

- [ ] All exception handlers log at least at DEBUG level

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #73 review | |

## Resources

- PR: https://github.com/OpenParachutePBC/parachute-computer/pull/73
