---
status: pending
priority: p2
issue_id: 75
tags: [code-review, flutter, quality]
dependencies: []
---

# RefreshIndicator Spinner Dismisses Instantly (No Await on Refetch)

## Problem Statement

All four `RefreshIndicator.onRefresh` callbacks in `capabilities_screen.dart` use `() async => ref.invalidate(provider)`. Since `ref.invalidate()` returns `void` (not a `Future`), the `async` wrapper completes immediately. The pull-to-refresh spinner flashes for a single frame with no visual feedback that data is actually being refetched.

## Findings

- **Source**: flutter-reviewer (P2, confidence 92)
- **Location**: `app/lib/features/settings/screens/capabilities_screen.dart:192-193, 397-398, 567-568, 802-803`
- **Evidence**: `onRefresh: () async => ref.invalidate(agentsProvider)` — void return wrapped in instantly-completed Future

## Proposed Solutions

### Solution A: Await the provider future after invalidation (Recommended)
```dart
onRefresh: () async {
  ref.invalidate(agentsProvider);
  await ref.read(agentsProvider.future);
},
```
- **Pros**: Spinner stays visible until data loads, proper UX feedback
- **Cons**: None
- **Effort**: Small (4 locations)
- **Risk**: None

## Recommended Action
<!-- Filled during triage -->

## Technical Details
- **Affected files**: `app/lib/features/settings/screens/capabilities_screen.dart`

## Acceptance Criteria
- [ ] Pull-to-refresh spinner stays visible until data loads on all 4 tabs
- [ ] `onRefresh` awaits the provider's future

## Work Log
| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-19 | Created from PR #75 code review | ref.invalidate() is void, must await .future |

## Resources
- PR: #75
