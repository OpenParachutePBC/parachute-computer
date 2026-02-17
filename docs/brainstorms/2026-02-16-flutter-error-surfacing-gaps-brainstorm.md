# Flutter App Error Surfacing Gaps

**Status**: Brainstorm complete, ready for planning
**Priority**: P2 (UX reliability)
**Modules**: app

---

## What We're Building

Close the gaps where errors happen in the Flutter app but are never shown to users. There are five identified problem areas:

1. **Daily journal silent failures** -- `journalServiceFutureProvider` and `selectedJournalProvider` errors in CRUD operations are caught and `debugPrint`'d but not surfaced to the user (e.g., `_addTextEntry`, `_addVoiceEntry`, `_updatePendingTranscription`, `_deleteEntry`).

2. **Streaming errors lost on session switch** -- `prepareForSessionSwitch()` resets the `ChatMessagesState` to a clean loading state, discarding any error that was present. If a user switches away from a session that just errored, then switches back, the error is gone with no trace.

3. **FutureProviders with no retry mechanism** -- `chatSessionsProvider` and `claudeUsageProvider` fall back to empty lists or error-state objects on server failure. The UI renders empty content with no indication that something went wrong and no way to retry.

4. **typedError events lack structured logging** -- When a `typedError` stream event arrives, only the message string is logged via `debugPrint`. The full `TypedError` object (code, actions, retry info, original error) is discarded in the log path.

5. **StreamingTranscriptionProvider swallows initialization errors** -- When `autoPauseTranscriptionServiceProvider` fails, `streamingTranscriptionProvider` returns `Stream.value(const StreamingTranscriptionState())` -- an empty default state. The user sees no recording feedback and thinks the service is ready when it actually failed to initialize.

---

## Why This Approach

The app already has a solid error infrastructure that is underutilized:

- **`AppError` hierarchy** (`core/errors/app_error.dart`) -- `NetworkError`, `ServerUnreachableError`, `FileSystemError`, `SessionError`, `TranscriptionError` with user-friendly messages.
- **`TypedError` model** (`chat/models/typed_error.dart`) -- Rich structured errors with error codes, recovery actions, retry info.
- **`ErrorRecoveryCard`** (`chat/widgets/error_recovery_card.dart`) -- Full recovery UI with keyboard shortcuts, severity-based styling, expandable technical details.
- **`ErrorBoundary` / `ScreenErrorBoundary`** (`core/widgets/error_boundary.dart`) -- Widget-level error catching with fallback UI.
- **`showAppError`** (`core/widgets/error_snackbar.dart`) -- Snackbar helper for `AppError` display.

The gap is not missing infrastructure -- it is that these tools are not wired into the error paths. The fix is to connect the existing error machinery to the places where errors are currently swallowed.

---

## Key Decisions

### 1. Journal Screen: Surface CRUD Errors via Snackbar

**Current**: `_addTextEntry`, `_addVoiceEntry`, `_updatePendingTranscription`, and `_deleteEntry` catch exceptions and only `debugPrint`. Only `_addPhotoEntry` and `_addHandwritingEntry` show snackbars on failure.

**Decision**: All journal CRUD catch blocks should show user-visible error feedback. Use `showAppError` for typed errors where possible, fall back to SnackBar with error message for generic exceptions. The existing `_addPhotoEntry` pattern is the right model.

**Note**: The `journalAsync.when()` on line 139 of `journal_screen.dart` already handles errors correctly with `JournalErrorState` + retry. The gap is in the imperative CRUD methods, not the reactive provider watching.

### 2. Session Switch: Preserve Last Error in Session Metadata

**Current**: `prepareForSessionSwitch()` creates a fresh `ChatMessagesState` with `isLoading: true`, discarding error state.

**Decision**: When switching away from a session with an active error, preserve the error in a lightweight per-session error cache (a simple `Map<String, String>` on the notifier). When `loadSession` completes, check if there was a cached error and restore it to state. This way, switching back to a failed session shows the error instead of pretending nothing happened.

### 3. FutureProviders: Add Error State + Retry to UI

**Current**: `chatSessionsProvider` catches server errors and returns `[]`. `claudeUsageProvider` catches errors and returns `ClaudeUsage(error: e.toString())`.

**Decision**: The providers themselves can stay as-is (graceful degradation is good). The fix belongs in the **UI layer** that consumes these providers. The session list screen and usage display should detect the error-fallback state and show:
- A banner or inline message: "Could not reach server"
- A retry button that calls `ref.invalidate()` on the provider

For `chatSessionsProvider`: detect the empty-list-from-error case by adding an `isOfflineFallback` flag or wrapping in a result type.
For `claudeUsageProvider`: the `ClaudeUsage.error` field already signals failure -- the UI just needs to render it.

### 4. TypedError: Log the Full Object

**Current** (lines 1405-1418 of `chat_message_providers.dart`):
```dart
case StreamEventType.typedError:
  final typedErr = event.typedError;
  final errorMsg = typedErr?.message ?? event.errorMessage ?? 'Unknown error';
  // Only errorMsg is used; typedErr code, actions, originalError are ignored in logging
```

**Decision**: When logging `typedError` events, include the error code, whether retry is possible, and the original error. Use the app's `logger` service instead of `debugPrint` for structured output. This is a small change with big debugging payoff.

### 5. StreamingTranscriptionProvider: Propagate Init Failure

**Current** (lines 34-37 of `streaming_transcription_provider.dart`):
```dart
error: (e, st) {
  debugPrint('[StreamingTranscription] Error: $e');
  return Stream.value(const StreamingTranscriptionState());
}
```

**Decision**: Add an `error` field to `StreamingTranscriptionState` so initialization failures are visible downstream. The recording UI should check for this error state and show a message like "Transcription unavailable" instead of silently proceeding with no transcription feedback. Same pattern for `interimTextProvider` and `vadActivityProvider`.

---

## Architecture

### Files to Modify

**Daily journal error surfacing:**
- `app/lib/features/daily/journal/screens/journal_screen.dart` -- Add snackbar error feedback to `_addTextEntry`, `_addVoiceEntry`, `_updatePendingTranscription`, `_deleteEntry` catch blocks

**Session switch error preservation:**
- `app/lib/features/chat/providers/chat_message_providers.dart` -- Cache error before `prepareForSessionSwitch()` clears state; restore on `loadSession` if present

**FutureProvider retry mechanism:**
- `app/lib/features/chat/providers/chat_session_providers.dart` -- Consider wrapping return type or adding error signal
- Chat hub screen (wherever sessions list is rendered) -- Add error banner + retry button
- Usage display widget -- Render `ClaudeUsage.error` with retry

**TypedError structured logging:**
- `app/lib/features/chat/providers/chat_message_providers.dart` -- Enhance `typedError` case logging with full error details

**Streaming transcription error propagation:**
- `app/lib/features/daily/recorder/providers/streaming_transcription_provider.dart` -- Add error field to `StreamingTranscriptionState`; propagate init failure
- Recording UI widgets -- Check and display transcription service error state

### Existing Infrastructure to Leverage

- `AppError` sealed class hierarchy for typed errors
- `showAppError()` snackbar helper
- `ErrorRecoveryCard` for rich error display
- `ErrorBoundary` / `ScreenErrorBoundary` for widget-level catching
- `TypedError` model with recovery actions
- `logger` service for structured logging

---

## Open Questions

### 1. Should journal CRUD errors use snackbars or inline error state?
Snackbars are simpler and consistent with the existing `_addPhotoEntry` pattern. Inline errors (like an error banner at the top of the journal) would be more persistent but require more UI work. **Recommendation**: Snackbars for now, matching existing patterns.

### 2. Should we introduce a result wrapper type for FutureProviders?
A `Result<T>` or `AsyncResult<T>` could carry both data and error metadata (e.g., "loaded from fallback"). This would be cleaner than sentinel values but adds a new pattern. **Recommendation**: Start with the simpler approach (detect empty + add retry) and introduce `Result<T>` only if the pattern repeats in more providers.

### 3. How far should transcription error propagation go?
Should the recording button be disabled if transcription fails to initialize, or should recording still work (just without live transcription feedback)? **Recommendation**: Recording should still work -- the transcription error is informational, not blocking. Show a "live transcription unavailable" indicator but allow recording.

---

## Success Criteria

- All journal CRUD operations show user-visible error feedback on failure
- Switching away from and back to a session with an error still shows the error
- Empty session list from server failure shows "Server unavailable" + retry button
- `typedError` stream events log error code, retry capability, and original error
- Transcription initialization failure is visible in recording UI
- No new error infrastructure needed -- all fixes use existing `AppError`/`TypedError`/snackbar/`ErrorRecoveryCard` machinery

---

## Related Issues

- #40: App UI Stability (overlapping error handling improvements)
