---
status: complete
priority: p1
issue_id: "111"
tags: [code-review, flutter, brain, riverpod]
dependencies: []
---

# ref.read() inside FutureProvider body drops reactive dependency

## Problem Statement
`brainSavedQueriesProvider` uses `ref.read(brainQueryServiceProvider)` inside its FutureProvider body. This is unconditional in Riverpod: `ref.read()` inside a provider body severs the reactive dependency. If `brainQueryServiceProvider` changes (API key change, server config update), `brainSavedQueriesProvider` will never re-execute and will use the stale service instance.

## Findings
- app/lib/features/brain/providers/brain_ui_state_provider.dart:67 — `(ref) => ref.read(brainQueryServiceProvider).loadQueries()`

Must be `ref.watch()`. Flutter reviewer confidence 95.

## Proposed Solutions
### Option 1: Change ref.read to ref.watch
Change `ref.read` to `ref.watch`. One word change, correct fix.

## Recommended Action
Option 1 — trivial one-word fix.

## Technical Details
**Affected files:**
- app/lib/features/brain/providers/brain_ui_state_provider.dart:67

## Resources
- **PR:** #111

## Acceptance Criteria
- [ ] `brainSavedQueriesProvider` uses `ref.watch()`
- [ ] Provider rebuilds when `brainQueryServiceProvider` changes

## Work Log
### 2026-02-23 - Code Review Discovery
**By:** Claude Code
**Actions:**
- Found during PR #111 review
**Learnings:**
- Riverpod rule: `ref.read()` inside a provider body does not create a dependency — use `ref.watch()` to subscribe to changes
- `ref.read()` is for one-shot reads in callbacks and actions, not provider setup
