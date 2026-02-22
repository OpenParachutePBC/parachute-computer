---
status: pending
priority: p2
issue_id: 75
tags: [code-review, architecture, python]
dependencies: []
---

# Fragile `.suffix == ".json"` Heuristic for Manifest vs Legacy Plugins

## Problem Statement

Three places use `Path(plugin.path).suffix == ".json"` to distinguish manifest-based from legacy plugins. This implicit convention is undocumented and could silently break if a legacy plugin path ends in `.json` or if the manifest path convention changes.

## Findings

- **Source**: architecture-strategist (P2, confidence 85), pattern-recognition-specialist (related)
- **Location**: `computer/parachute/core/plugins.py:284`, `computer/parachute/core/orchestrator.py:569`
- **Evidence**: Three separate `.suffix == ".json"` checks with no explicit model field

## Proposed Solutions

### Solution A: Add explicit field to InstalledPlugin (Recommended)
Add `install_format: Literal["manifest", "legacy"] = "legacy"` field to the InstalledPlugin model.
- **Pros**: Explicit, self-documenting, no path inspection needed
- **Cons**: Model change
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `computer/parachute/models/plugin.py`, `core/plugins.py`, `core/orchestrator.py`

## Acceptance Criteria
- [ ] InstalledPlugin has an explicit `install_format` field
- [ ] All manifest vs legacy checks use the field instead of path suffix

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | Implicit path conventions are fragile |

## Resources
- PR: #75
