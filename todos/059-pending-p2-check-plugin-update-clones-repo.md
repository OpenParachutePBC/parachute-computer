---
status: pending
priority: p2
issue_id: 75
tags: [code-review, performance, python]
dependencies: []
---

# check_plugin_update Performs Full Git Clone Instead of Lightweight Check

## Problem Statement

`check_plugin_update` does `git clone --depth 1 --bare` of the entire repo just to compare one commit hash. The old implementation used `git fetch --dry-run`. This is orders of magnitude more expensive. At 10 plugins, checking all updates takes 30+ seconds.

## Findings

- **Source**: performance-oracle (P2, confidence 92)
- **Location**: `computer/parachute/core/plugin_installer.py:579-626`
- **Evidence**: Full bare clone to temp dir, compared to previous `git fetch --dry-run` approach. `git ls-remote <url> HEAD` would be a single network round trip with zero disk I/O.

## Proposed Solutions

### Solution A: Use `git ls-remote` (Recommended)
Replace clone with `git ls-remote <url> HEAD` which returns just the remote HEAD SHA.
- **Pros**: Milliseconds vs seconds, zero disk I/O, no temp dir
- **Cons**: Less info (can't get exact "behind" count, just "different")
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/plugin_installer.py`

## Acceptance Criteria
- [ ] Update check uses `git ls-remote` instead of `git clone --bare`
- [ ] No temp directory created for update checks
- [ ] Check completes in < 5 seconds for any plugin

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | Regression from old git fetch approach |

## Resources
- PR: #75
