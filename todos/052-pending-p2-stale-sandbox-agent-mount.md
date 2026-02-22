---
status: pending
priority: p2
issue_id: 75
tags: [code-review, architecture, python]
dependencies: []
---

# Stale Docker Sandbox Mount for Agent Directory

## Problem Statement

The Docker sandbox mounts `vault/.parachute/agents/` (old path) instead of `vault/.claude/agents/` (new SDK-native path). Sandboxed sessions will not have access to user-created agents after this consolidation.

## Findings

- **Source**: architecture-strategist (P2, confidence 92)
- **Location**: `computer/parachute/core/sandbox.py:165-167`
- **Evidence**: `agents_dir = self.vault_path / ".parachute" / "agents"` — this path was the old custom agents location. The new canonical path is `.claude/agents/`.

## Proposed Solutions

### Solution A: Update mount path (Recommended)
Change the mount from `.parachute/agents` to `.claude/agents`.
- **Pros**: Simple fix, aligns with consolidation
- **Cons**: None
- **Effort**: Small (2 lines)
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/core/sandbox.py`

## Acceptance Criteria
- [ ] Sandbox mounts `vault/.claude/agents/` instead of `vault/.parachute/agents/`
- [ ] Sandboxed sessions can access user-created agents

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | sandbox.py not updated in Phase 1 |

## Resources
- PR: #75
