---
status: pending
priority: p2
issue_id: 75
tags: [code-review, performance, python]
dependencies: []
---

# Orphan Git Processes on Timeout

## Problem Statement

When `asyncio.wait_for(proc.communicate(), timeout=...)` times out, the underlying git process is not killed. It continues running as an orphan, holding network connections and writing to the temp directory that `shutil.rmtree` is about to delete.

## Findings

- **Source**: performance-oracle (P2, confidence 86)
- **Location**: `computer/parachute/core/plugin_installer.py:594-600, 414-419`
- **Evidence**: `asyncio.wait_for` cancels the coroutine but doesn't kill the subprocess

## Proposed Solutions

### Solution A: Kill process on timeout (Recommended)
```python
try:
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=60)
except asyncio.TimeoutError:
    proc.kill()
    await proc.wait()
    raise RuntimeError("Git clone timed out")
```
- **Pros**: Clean resource management, no orphan processes
- **Cons**: None
- **Effort**: Small
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/plugin_installer.py`

## Acceptance Criteria
- [ ] Git processes are killed on timeout
- [ ] No orphan git processes after timeout

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | asyncio.wait_for doesn't kill subprocesses |

## Resources
- PR: #75
