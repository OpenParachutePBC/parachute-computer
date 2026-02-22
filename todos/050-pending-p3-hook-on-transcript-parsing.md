---
status: pending
priority: p3
issue_id: 73
tags: [code-review, python, performance]
dependencies: []
---

# O(n) Transcript Parsing on Every Hook Invocation

## Problem Statement

`read_last_exchange()` reads the entire transcript file into memory and parses all JSON lines, even though it only needs the last exchange. For long sessions (100+ exchanges), this means parsing thousands of JSON lines repeatedly.

## Findings

- **Source**: performance-oracle (confidence 95)
- **Location**: `computer/parachute/hooks/activity_hook.py:164-247`
- **Evidence**: Line 174 does `transcript_path.read_text().strip().split("\n")`, then iterates ALL lines to count exchanges and find the last user message
- **Scale**: 100-exchange session with 15 hook fires = ~1,500 total JSON parses across all invocations

## Proposed Solutions

### Solution A: Read last N lines only (Recommended)
Use reverse file seeking or read only the last ~50 lines.
- **Pros**: Constant memory, O(1) instead of O(n)
- **Cons**: More complex file reading logic
- **Effort**: Medium (30 min)
- **Risk**: Low — need to handle edge case where user message spans more than 50 lines

### Solution B: Accept as-is for MVP
Typical sessions are 10-20 exchanges. O(n) on 40 lines is negligible (~ms).
- **Pros**: No code change
- **Cons**: Degrades for power users with very long sessions
- **Effort**: None
- **Risk**: Low for typical use

## Recommended Action

<!-- Filled during triage -->

## Acceptance Criteria

- [ ] `read_last_exchange()` performs in constant time regardless of transcript size

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #73 review | Practical impact is low for typical session lengths |

## Resources

- PR: https://github.com/OpenParachutePBC/parachute-computer/pull/73
