---
status: pending
priority: p3
issue_id: 33
tags: [code-review, performance, correctness]
dependencies: []
---

# Use `time.monotonic()` Instead of `time.time()` for Timeouts

## Problem Statement

Timeout calculations use `time.time()` which can jump due to NTP adjustments or system clock changes. `time.monotonic()` is the correct choice for measuring elapsed time.

## Findings

- **Source**: performance-oracle
- **Location**: `computer/parachute/core/sandbox.py` — timeout logic in run methods

## Proposed Solutions

### Solution A: Replace `time.time()` with `time.monotonic()` (Recommended)
Simple find-and-replace for timeout-related time calls.
- **Pros**: Correct, simple change
- **Effort**: Small
- **Risk**: Low

## Technical Details

- **Affected files**: `computer/parachute/core/sandbox.py`

## Acceptance Criteria

- [ ] All timeout calculations use `time.monotonic()`

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-16 | Created from PR #38 code review | |

## Resources

- PR #38: https://github.com/OpenParachutePBC/parachute-computer/pull/38
