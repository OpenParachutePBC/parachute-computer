---
status: pending
priority: p2
issue_id: 75
tags: [code-review, quality, flutter]
dependencies: []
---

# Dead Source Labels in Flutter _SourceBadge Switch

## Problem Statement

The `_SourceBadge` widget still has switch cases for `'vault_agents'` and `'custom_agents'` — source values the server no longer emits after this PR.

## Findings

- **Source**: pattern-recognition-specialist (P2, confidence 91)
- **Location**: `app/lib/features/settings/screens/capabilities_screen.dart:1589-1592`
- **Evidence**: Server only emits `'builtin'` and `'sdk'` after consolidation.

## Proposed Solutions

### Solution A: Remove dead cases (Recommended)
Delete the `'vault_agents'` and `'custom_agents'` switch arms.
- **Pros**: Clean code, no confusion about supported sources
- **Effort**: Small (2 lines)
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/settings/screens/capabilities_screen.dart`

## Acceptance Criteria
- [ ] No dead source label cases in _SourceBadge
- [ ] _iconForSource also cleaned up if applicable

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | Incomplete migration in Phase 4 |

## Resources
- PR: #75
