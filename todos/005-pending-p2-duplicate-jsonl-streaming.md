---
status: pending
priority: p2
issue_id: 33
tags: [code-review, architecture, duplication]
dependencies: []
---

# ~60 Lines of Duplicated JSONL Streaming Logic

## Problem Statement

`run_persistent()` and `run_agent()` in `sandbox.py` share ~60 lines of nearly identical JSONL event parsing and streaming logic. This duplication creates a maintenance burden — any change to event handling must be made in two places.

## Findings

- **Source**: architecture-strategist, python-reviewer, code-simplicity-reviewer
- **Location**: `computer/parachute/core/sandbox.py` — `run_persistent()` and `run_agent()`
- **Evidence**: Both methods contain identical patterns for reading stdout lines, parsing JSON, emitting text/error/done events

## Proposed Solutions

### Solution A: Extract shared `_stream_jsonl()` helper (Recommended)
Create `async def _stream_jsonl(self, proc, session_id) -> AsyncGenerator[dict, None]` that both methods call.
- **Pros**: DRY, single place to fix bugs
- **Cons**: Minor refactor
- **Effort**: Medium
- **Risk**: Low

### Solution B: Leave as-is for now
The duplication is contained and both methods may diverge over time.
- **Pros**: No risk of breakage
- **Cons**: Maintenance burden persists
- **Effort**: None
- **Risk**: Low (but tech debt accumulates)

## Technical Details

- **Affected files**: `computer/parachute/core/sandbox.py`

## Acceptance Criteria

- [ ] JSONL streaming logic exists in one place only
- [ ] Both `run_persistent` and `run_agent` use the shared helper
- [ ] No behavioral change in event streaming

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
