---
status: complete
priority: p2
issue_id: "193"
tags: [code-review, flutter, brain, performance]
dependencies: []
---

# addPostFrameCallback inside LayoutBuilder accumulates callbacks on every layout pass

## Problem Statement
`BrainHomeScreen`'s `LayoutBuilder` schedules `addPostFrameCallback` on every layout pass. During window resize on desktop, multiple callbacks per frame accumulate. Each evaluates the if-check (prevents spurious writes) but still executes callback overhead.

## Findings
- brain_home_screen.dart:32-35 — `LayoutBuilder` callback calls `addPostFrameCallback`
- Flutter reviewer confidence 85

## Proposed Solutions
### Option 1: Compute layout mode inline in LayoutBuilder
Compute layout mode directly in `LayoutBuilder` and call `ref.read(brainLayoutModeStateProvider.notifier).state = mode` inline (no post-frame callback needed). Add deduplication check.

### Option 2: Derive layout mode from MediaQuery
Derive layout mode directly from `MediaQuery` in each widget that needs it; remove layout mode provider entirely.

## Recommended Action
Option 1 — targeted fix.

## Technical Details
**Affected files:**
- app/lib/features/brain/screens/brain_home_screen.dart:32-35

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] No `addPostFrameCallback` inside `LayoutBuilder`
- [ ] Layout mode updated inline without callback accumulation

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
