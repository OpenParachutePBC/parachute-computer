# Flutter Navigation & Layout Consistency Fixes

**Status**: Brainstorm complete, ready for planning
**Priority**: P2 (UX polish and correctness)
**Modules**: app

---

## What We're Building

Fix five navigation and layout consistency issues in the Flutter chat interface:

1. **LayoutBuilder post-frame callback anti-pattern** -- ChatShell uses `addPostFrameCallback` inside `build()` to update `chatLayoutModeProvider`, triggering unnecessary provider invalidations on every frame and potential rebuild cascades on rotation.

2. **Embedded mode state mismatch on delete/archive** -- `_navigateBackFromSession()` clears `currentSessionIdProvider` and `newChatModeProvider` but does not reset `newChatModeProvider` when coming from a delete or archive action, causing UI state to become inconsistent.

3. **Session resume race condition** -- `_resumeSession()` calls `unarchiveSessionProvider` async but immediately enables input regardless of whether the unarchive succeeds, letting users send messages to a still-archived session.

4. **Bottom sheet height constraints inconsistent** -- Some bottom sheets enforce `maxHeight: MediaQuery.of(context).size.height * 0.85` (per CLAUDE.md convention) while others omit the constraint entirely, risking overflow on smaller screens.

5. **Session title text overflow with badges** -- The embedded toolbar accommodates title + badges + icon buttons, but when many badges are present the title text can overflow despite the `Flexible(flex: 0)` wrapper on the badges row.

These are correctness and polish issues that affect reliability across screen sizes and navigation flows.

---

## Why This Approach

### Issue 1: LayoutBuilder Post-Frame Callback

**Current code** (`chat_shell.dart` lines 23-30):
```dart
return LayoutBuilder(
  builder: (context, constraints) {
    final mode = ChatLayoutBreakpoints.fromWidth(constraints.maxWidth);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatLayoutModeProvider.notifier).state = mode;
    });
    // ...
  },
);
```

**Problem**: `addPostFrameCallback` inside `build()` fires after every frame where the LayoutBuilder rebuilds. On rotation or resize, this triggers a provider state change, which invalidates all watchers of `chatLayoutModeProvider`, causing a cascade of rebuilds. The callback also accumulates -- rapid resizing queues multiple callbacks.

**Better pattern**: Derive the layout mode reactively. Instead of imperatively setting a `StateProvider` from a callback, compute it from a width provider or use `ref.listen` to detect changes. The simplest fix: compare old and new mode before setting state to avoid no-op invalidations, or restructure so the mode is derived from constraints without a side-effect callback.

### Issue 2: Embedded Mode State on Delete/Archive

**Current code** (`chat_screen.dart` lines 1660-1667):
```dart
void _navigateBackFromSession() {
  if (widget.embeddedMode) {
    ref.read(currentSessionIdProvider.notifier).state = null;
    ref.read(newChatModeProvider.notifier).state = false;
  } else {
    Navigator.of(context).pop();
  }
}
```

**Problem**: This method is called for both delete and archive flows. Setting `newChatModeProvider = false` is correct when the user is leaving a chat. But the calling code (`_handleAppBarAction` for 'archive' and 'delete') navigates back first, then performs the async operation. If the user had been in new-chat mode before navigating to the session, the state is lost. More importantly, there is no differentiation between "user pressed back" vs "session was destroyed" -- the cleanup should also invalidate session-specific state like `chatMessagesProvider`.

### Issue 3: Resume Race Condition

**Current code** (`chat_screen.dart` lines 1726-1748):
```dart
Future<void> _resumeSession(ChatSession session) async {
  try {
    await ref.read(unarchiveSessionProvider)(session.id);
  } on AppError catch (e) {
    // Show error but continue anyway
  } catch (e) {
    // Continue anyway
  }
  ref.read(chatMessagesProvider.notifier).enableSessionInput(session);
  ref.invalidate(chatSessionsProvider);
}
```

**Problem**: The comment "Continue anyway -- the local state change is more important" means that if the server rejects the unarchive (network error, session not found, permission denied), the app still enables the input field. The user can type and send messages, but those messages will fail because the server still considers the session archived. The input should only be enabled on successful unarchive.

### Issue 4: Bottom Sheet Height Constraints

**Sheets WITH `maxHeight` constraint** (per CLAUDE.md convention):
- `session_config_sheet.dart` -- `maxHeight: 0.85`
- `session_info_sheet.dart` -- `maxHeight: 0.85`
- `unified_session_settings.dart` -- `maxHeight: 0.85`
- `new_chat_sheet.dart` -- `maxHeight: 0.85`
- `session_selector.dart` -- `maxHeight: 0.6`

**Sheets WITHOUT `maxHeight` constraint**:
- `context_settings_sheet.dart` -- uses `mainAxisSize: MainAxisSize.min` but no max constraint
- `message_bubble.dart` `_showAudioPlayer` -- no constraint at all
- `chat_hub_screen.dart` `_showApprovalDialog` -- `isScrollControlled: true` but no max constraint
- `session_list_panel.dart` `_showWorkspacePicker` -- no constraint

**Risk**: On smaller screens or with keyboard open, unconstrained sheets can overflow or become full-screen unintentionally. The `claude_code_import_screen.dart` `_showProjectPicker` uses `DraggableScrollableSheet` with `maxChildSize: 0.9`, which is an acceptable alternative pattern.

### Issue 5: Embedded Toolbar Title Overflow

**Current code** (`chat_screen.dart` lines 488-575):
```dart
Row(
  children: [
    Expanded(child: _buildTitle(context, isDark, currentSessionId, chatState)),
    Flexible(flex: 0, child: Row(mainAxisSize: MainAxisSize.min, children: [
      // Agent badge, Model badge, Working directory indicator
    ])),
    // Action buttons
  ],
)
```

**Problem**: The outer Row gives `Expanded` to the title and `Flexible(flex: 0)` to the badges. This is almost correct -- badges shrink before the title does. But when all three badges are present (agent + model + working directory) plus action buttons, the available space for the title can shrink to near zero. The title itself uses `TextOverflow.ellipsis` but the badges Row does not shrink gracefully enough -- individual badge containers have fixed padding and minimum content that does not compress.

---

## Key Decisions

### 1. Fix LayoutBuilder with Guard, Not Full Restructure

**Decision**: Add a guard to only update `chatLayoutModeProvider` when the mode actually changes. This is the minimal fix that eliminates redundant invalidations without restructuring the provider graph.

```dart
final currentMode = ref.read(chatLayoutModeProvider);
if (currentMode != mode) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ref.read(chatLayoutModeProvider.notifier).state = mode;
  });
}
```

A full restructure (deriving mode from a width provider) would be cleaner but is a larger change. The guard is sufficient for P2 priority.

### 2. Clear All Session-Specific State on Delete/Archive

**Decision**: When a session is deleted or archived in embedded mode, clear `currentSessionIdProvider`, `newChatModeProvider`, AND invalidate `chatMessagesProvider` to ensure no stale state leaks. The `_navigateBackFromSession` method should handle this consistently regardless of the action that triggered it.

### 3. Gate Input on Successful Unarchive

**Decision**: Only call `enableSessionInput()` if `unarchiveSessionProvider` succeeds. On failure, keep the session in archived/read-only state and show a clear error.

```dart
try {
  await ref.read(unarchiveSessionProvider)(session.id);
  // Only enable input on success
  ref.read(chatMessagesProvider.notifier).enableSessionInput(session);
  ref.invalidate(chatSessionsProvider);
} on AppError catch (e) {
  if (mounted) showAppError(context, e);
  // Do NOT enable input -- session is still archived
}
```

### 4. Enforce maxHeight on All Bottom Sheets

**Decision**: Apply the `maxHeight: MediaQuery.of(context).size.height * 0.85` constraint (the existing CLAUDE.md convention) to all bottom sheets that currently lack it. For sheets using `DraggableScrollableSheet` with `maxChildSize <= 0.9`, leave them as-is since that pattern handles height correctly.

Sheets to fix:
- `context_settings_sheet.dart`
- `message_bubble.dart` `_showAudioPlayer`
- `chat_hub_screen.dart` `_showApprovalDialog`
- `session_list_panel.dart` `_showWorkspacePicker`

### 5. Add Overflow Protection to Badge Row

**Decision**: Wrap the badges in an `OverflowBar` or add `overflow: TextOverflow.ellipsis` with `maxLines: 1` to individual badge text widgets. When space is extremely tight (e.g., narrow tablet with long title), hide the least-important badge first (working directory indicator).

---

## Open Questions

### 1. Should chatLayoutModeProvider be derived instead of imperatively set?
The guard fix is minimal and correct. But a `Provider` that derives from a `widthProvider` (set by LayoutBuilder) would eliminate the callback pattern entirely. Worth considering in a larger refactor pass.

### 2. Should _navigateBackFromSession differentiate between back/delete/archive?
Currently it handles all three the same way. Delete should probably also clear the messages provider immediately (no fade-out), while archive could show a brief "Archived" confirmation. Not required for P2 but worth noting.

### 3. Should we add a loading state to the resume button?
While the unarchive request is in flight, the resume button should probably show a spinner to prevent double-taps and give feedback. Minor UX polish.

---

## Files to Modify

| File | Changes |
|------|---------|
| `app/lib/features/chat/screens/chat_shell.dart` | Add mode-change guard to LayoutBuilder callback |
| `app/lib/features/chat/screens/chat_screen.dart` | Fix `_navigateBackFromSession` state cleanup; fix `_resumeSession` race condition; review embedded toolbar overflow |
| `app/lib/features/chat/widgets/context_settings_sheet.dart` | Add maxHeight constraint |
| `app/lib/features/chat/widgets/message_bubble.dart` | Add maxHeight to audio player sheet |
| `app/lib/features/chat/screens/chat_hub_screen.dart` | Add maxHeight to approval dialog sheet |
| `app/lib/features/chat/widgets/session_list_panel.dart` | Add maxHeight to workspace picker sheet |

---

## Success Criteria

- No redundant `chatLayoutModeProvider` invalidations on resize/rotation (verify with Riverpod observer logs)
- Delete/archive in embedded mode returns to clean empty state with no stale session data
- Resume button only enables input after successful server unarchive; failed unarchive shows error and keeps session read-only
- All bottom sheets constrained to max 85% screen height
- Embedded toolbar title truncates cleanly with ellipsis when 3+ badges are present
- No RenderFlex overflow errors at 600px, 601px, 1199px, 1200px breakpoints

---

## Related Issues

- #41: App UI Stability (overlapping overflow and navigation fixes)
