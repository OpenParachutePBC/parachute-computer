---
title: "fix: Flutter navigation & layout consistency"
type: fix
date: 2026-02-17
issue: "#51"
---

# fix: Flutter Navigation & Layout Consistency

Five correctness and polish fixes for the Flutter chat interface — redundant rebuilds, stale state, race conditions, unconstrained sheets, and toolbar overflow.

## Enhancement Summary

**Deepened on:** 2026-02-17
**Review agents used:** flutter-reviewer, architecture-strategist, code-simplicity-reviewer

### Key Improvements from Review
1. **Fix 4b simplified** — Skip audio player sheet constraint entirely; content is ~120px fixed-height, Flutter's default sheet cap handles it
2. **Fix 5 simplified** — Keep `Flexible(flex: 0)` (it's correct behavior), just add `ConstrainedBox(maxWidth: 120)` per badge widget
3. **Fix 3 hardened** — Keep generic catch block for non-AppError exceptions (SocketException, FormatException, etc.)

### Reviewer Consensus
- All three reviewers agreed: minimal, targeted fixes are correct for P2 priority
- No architectural concerns — changes are localized and don't cross module boundaries
- `clearSession()` confirmed as correct over `ref.invalidate()` by all reviewers

## Overview

The brainstorm (#51) identified five issues. SpecFlow analysis surfaced additional gaps around state cleanup semantics, error handling, and scrollability. This plan addresses all of them.

## Fixes

### 1. LayoutBuilder Post-Frame Callback Guard

**File**: `app/lib/features/chat/screens/chat_shell.dart` (lines 23-30)

**Problem**: `addPostFrameCallback` inside `build()` fires every frame, triggering redundant `chatLayoutModeProvider` invalidations and rebuild cascades.

**Fix**: Guard the callback so it only fires when the mode actually changes.

```dart
// chat_shell.dart, inside LayoutBuilder builder:
final mode = ChatLayoutBreakpoints.fromWidth(constraints.maxWidth);
final currentMode = ref.read(chatLayoutModeProvider);
if (currentMode != mode) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ref.read(chatLayoutModeProvider.notifier).state = mode;
  });
}
```

**Notes**:
- On first launch, if default (`mobile`) matches the actual width, no callback fires — this is correct; the default is already right.
- A full restructure (derived provider) is out of scope. The guard is sufficient.

---

### 2. Embedded Mode State Cleanup on Delete/Archive

**File**: `app/lib/features/chat/screens/chat_screen.dart` (~line 1660)

**Problem**: `_navigateBackFromSession()` clears `currentSessionIdProvider` and `newChatModeProvider` but leaves stale messages in `chatMessagesProvider`. The `deleteSessionProvider` can't clean up because the session ID was already nulled.

**Fix**: Call `clearSession()` (not `ref.invalidate`) to reset messages without destroying the StateNotifier and its stream manager.

```dart
void _navigateBackFromSession() {
  if (widget.embeddedMode) {
    ref.read(currentSessionIdProvider.notifier).state = null;
    ref.read(newChatModeProvider.notifier).state = false;
    ref.read(chatMessagesProvider.notifier).clearSession();
  } else {
    Navigator.of(context).pop();
  }
}
```

**Why `clearSession()` not `ref.invalidate()`**: `invalidate` would dispose and recreate the entire `ChatMessagesNotifier`, breaking active stream subscriptions and the stream manager reference. `clearSession()` is a controlled reset — matches the existing pattern used by `deleteSessionProvider` and `newChatProvider`.

---

### 3. Session Resume Race Condition

**File**: `app/lib/features/chat/screens/chat_screen.dart` (~line 1726)

**Problem**: `_resumeSession()` enables input regardless of whether the unarchive request succeeds, letting users type into a still-archived session.

**Fix**: Gate `enableSessionInput()` on successful unarchive. Keep a generic catch for non-`AppError` exceptions (SocketException, FormatException, etc.). Remove the redundant `ref.invalidate(chatSessionsProvider)` since `unarchiveSessionProvider` already handles it.

```dart
Future<void> _resumeSession(ChatSession session) async {
  try {
    await ref.read(unarchiveSessionProvider)(session.id);
    // Only enable input on success
    ref.read(chatMessagesProvider.notifier).enableSessionInput(session);
  } on AppError catch (e) {
    if (mounted) showAppError(context, e);
    // Session stays in read-only state
  } catch (e) {
    debugPrint('[ChatScreen] Unexpected error unarchiving session: $e');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to resume session: $e')),
      );
    }
  }
}
```

**Notes**:
- `unarchiveSessionProvider` already invalidates `chatSessionsProvider` and `archivedSessionsProvider` via postFrameCallback on success — no need to duplicate.
- Loading state / double-tap protection on the Resume button is out of scope (mentioned in brainstorm Open Questions).

---

### 4. Bottom Sheet maxHeight Constraints

**Files**: 4 sheets missing the CLAUDE.md convention of `maxHeight: 0.85`.

For each sheet, add `ConstrainedBox` with `maxHeight` AND ensure content is scrollable (per CLAUDE.md: `Flexible` + `SingleChildScrollView`).

#### 4a. `context_settings_sheet.dart`

Wrap the outer container in a `ConstrainedBox`. Content is short and unlikely to overflow, but add scrollability defensively.

```dart
// Wrap the existing Container
ConstrainedBox(
  constraints: BoxConstraints(
    maxHeight: MediaQuery.of(context).size.height * 0.85,
  ),
  child: Container(
    // ... existing decoration and padding
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drag handle (outside scroll)
        // ...
        // Scrollable content
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              // ... existing content children
            ),
          ),
        ),
      ],
    ),
  ),
)
```

#### 4b. `message_bubble.dart` — `_showAudioPlayer()` — **SKIP**

Audio player content is ~120px fixed-height and does not use `isScrollControlled: true`. Flutter's default sheet cap already constrains it. No change needed.

#### 4c. `chat_hub_screen.dart` — `_showApprovalDialog()`

This sheet has dynamic content (trust level radio tiles, optional message preview). Wrap the content section in `Flexible` + `SingleChildScrollView`.

```dart
builder: (sheetContext) => StatefulBuilder(
  builder: (context, setSheetState) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.85,
    ),
    child: Padding(
      // ... existing padding
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header (outside scroll)
          // ...
          // Scrollable content
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  // Trust level radios, message preview, etc.
                ],
              ),
            ),
          ),
          // Action buttons (outside scroll)
          // ...
        ],
      ),
    ),
  ),
),
```

#### 4d. `session_list_panel.dart` — `_showWorkspacePicker()`

This sheet lists workspaces — could grow unbounded. Wrap workspace list in `Flexible` + `SingleChildScrollView`.

```dart
builder: (sheetContext) => ConstrainedBox(
  constraints: BoxConstraints(
    maxHeight: MediaQuery.of(context).size.height * 0.85,
  ),
  child: Container(
    // ... existing decoration
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Drag handle + title (outside scroll)
        // ...
        // "All Chats" option (outside scroll)
        // ...
        // Scrollable workspace list
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              children: [
                // Workspace ListTiles
              ],
            ),
          ),
        ),
      ],
    ),
  ),
),
```

---

### 5. Embedded Toolbar Badge Overflow

**File**: `app/lib/features/chat/screens/chat_screen.dart` (~lines 488-587)

**Problem**: The badges `Row` with `Flexible(flex: 0)` is laid out at intrinsic width BEFORE the title. On narrow content areas (tablet at 600px = ~360px chat area), three badges can squeeze the title to near-zero.

**Fix**: Keep `Flexible(flex: 0)` (correct — lays out badges at intrinsic width first, giving title the remainder via `Expanded`). Add `ConstrainedBox(maxWidth: 120)` to each badge widget so intrinsic width can't exceed 120px. Add `overflow: TextOverflow.ellipsis` to model badge text.

```dart
// Keep existing layout structure — only wrap each badge
Flexible(
  flex: 0,
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (agentName != null) ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: _agentBadge(...),
      ),
      if (model != null) ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: _modelBadge(...),  // Add TextOverflow.ellipsis to text
      ),
      if (workingDir != null) ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: _workingDirIndicator(...),
      ),
    ],
  ),
),
```

**Key changes**:
- Keep `Flexible(flex: 0)` — it correctly gives badges intrinsic width, then title gets the rest
- Each badge constrained to `maxWidth: 120` matching `_appBarBadge` pattern
- Model badge text gets `overflow: TextOverflow.ellipsis` (currently missing)

**Testing widths** (effective content area, not window): 300px, 360px, 580px, 680px, 900px.

---

## Acceptance Criteria

- [x] No redundant `chatLayoutModeProvider` invalidations on resize/rotation
- [x] Delete/archive in embedded mode returns to clean empty state (no stale messages)
- [x] Resume button only enables input after successful server unarchive
- [x] Failed unarchive shows error snackbar and keeps session read-only
- [x] All 4 unconstrained bottom sheets have `maxHeight: 0.85` + scrollable content where needed
- [x] Embedded toolbar badges truncate with ellipsis; title always gets reasonable space
- [ ] No `RenderFlex` overflow at content widths: 300px, 360px, 580px, 680px, 900px
- [ ] No regression in mobile push-navigation flows (pop still works)
- [ ] No regression in session switching, new chat, or streaming

## Files to Modify

| File | Fix | Changes |
|------|-----|---------|
| `app/lib/features/chat/screens/chat_shell.dart` | 1 | Add mode-change guard |
| `app/lib/features/chat/screens/chat_screen.dart` | 2, 3, 5 | `_navigateBackFromSession` cleanup; `_resumeSession` race fix; embedded toolbar badges |
| `app/lib/features/chat/widgets/context_settings_sheet.dart` | 4a | Add `ConstrainedBox` + scrollable content |
| `app/lib/features/chat/widgets/message_bubble.dart` | 4b | **SKIP** — Flutter default cap handles ~120px content |
| `app/lib/features/chat/screens/chat_hub_screen.dart` | 4c | Add `ConstrainedBox` + scrollable content to approval dialog |
| `app/lib/features/chat/widgets/session_list_panel.dart` | 4d | Add `ConstrainedBox` + scrollable workspace list |

## References

- Brainstorm: `docs/brainstorms/2026-02-16-flutter-nav-layout-consistency-brainstorm.md`
- CLAUDE.md bottom sheet convention: `app/CLAUDE.md` lines 121-131
- Existing maxHeight pattern: `session_config_sheet.dart:173`
- Existing badge pattern: `_appBarBadge` method with `maxWidth: 120`
- Related: #41 (App UI Stability)
