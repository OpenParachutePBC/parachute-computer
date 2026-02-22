---
status: done
priority: p2
issue_id: 50
tags: [code-review, flutter, error-handling, riverpod]
dependencies: []
---

# Unguarded `await ref.read(chatSessionsProvider.future)` in Refresh Handlers

## Problem Statement

Now that `chatSessionsProvider` can throw (per Fix 3a in PR #65), two `RefreshIndicator.onRefresh` handlers have unguarded `await` calls that will propagate the exception up to the Flutter framework. This could cause unhandled exception crashes during pull-to-refresh when the server is down.

## Findings

- **Source**: architecture-strategist (92), performance-oracle (85)
- **Location**: `app/lib/features/chat/screens/chat_hub_screen.dart` (~line 580), `app/lib/features/chat/screens/agent_hub_screen.dart` (~line 274)
- **Evidence**: Both files call `await ref.read(chatSessionsProvider.future)` inside `onRefresh` callbacks without try/catch. RefreshIndicator expects the Future to complete normally.

## Proposed Solutions

### Solution A: Wrap in try/catch, show snackbar on error
```dart
onRefresh: () async {
  try {
    ref.invalidate(chatSessionsProvider);
    await ref.read(chatSessionsProvider.future);
  } catch (_) {
    // Provider error state will be shown by the main UI
  }
}
```
- **Pros**: Prevents unhandled exception, provider error state already shown by `.when(error:)` handler
- **Cons**: Silent catch in refresh handler
- **Effort**: Small
- **Risk**: Low

### Solution B: Let provider handle it, remove the await
Just invalidate without awaiting — the provider's error state will update the UI naturally.
- **Pros**: Simpler, no try/catch needed
- **Cons**: RefreshIndicator spinner may not dismiss correctly
- **Effort**: Small
- **Risk**: Low

## Technical Details

- **Affected files**: `app/lib/features/chat/screens/chat_hub_screen.dart`, `app/lib/features/chat/screens/agent_hub_screen.dart`
- **Components**: Pull-to-refresh handlers

## Acceptance Criteria

- [ ] Pull-to-refresh does not crash when server is down
- [ ] Error state is visible to user after failed refresh

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-17 | Created from PR #65 review | New throw path creates downstream impact |

## Resources

- PR: #65
- Issue: #50
