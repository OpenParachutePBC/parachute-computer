---
status: complete
priority: p2
issue_id: "184"
tags: [code-review, flutter, brain, architecture, riverpod]
dependencies: []
---

# brainLayoutModeStateProvider publicly exposes write interface despite supposed encapsulation

## Problem Statement
The code creates private `_brainLayoutModeStateProvider` and derives `brainLayoutModeProvider` (read-only) from it, with a comment explaining the write/read separation. Then it re-exports the private provider as public `brainLayoutModeStateProvider`, making the write interface accessible to every widget that imports brain_providers.dart. The encapsulation comment is architecturally inaccurate.

## Findings
- brain_ui_state_provider.dart:21-32 — `brainLayoutModeStateProvider = _brainLayoutModeStateProvider` re-exports the write side
- Flutter reviewer confidence 92, Architecture reviewer confidence 82, Simplicity reviewer confidence 88

## Proposed Solutions
### Option 1: Remove the brainLayoutModeStateProvider re-export
Pass the notifier as constructor param to BrainHomeScreen, or use a typed NotifierProvider with a `setLayoutMode()` method.

### Option 2: Collapse to one public StateProvider
Remove false encapsulation; document that only BrainHomeScreen should write it.

## Recommended Action
Option 2 — simpler, honest about the design.

## Technical Details
**Affected files:**
- app/lib/features/brain/providers/brain_ui_state_provider.dart:21-32

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] Only BrainHomeScreen writes layout mode
- [ ] No re-exported write interface
- [ ] Clean provider structure

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
