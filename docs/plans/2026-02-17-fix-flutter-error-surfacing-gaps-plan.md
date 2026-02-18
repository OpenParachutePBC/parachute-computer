---
title: "fix: Flutter app error surfacing gaps"
type: fix
date: 2026-02-17
issue: "#50"
modules: app
files:
  - app/lib/features/daily/journal/screens/journal_screen.dart
  - app/lib/features/chat/providers/chat_message_providers.dart
  - app/lib/features/chat/providers/chat_session_providers.dart
  - app/lib/features/chat/providers/workspace_providers.dart
  - app/lib/features/chat/providers/session_search_provider.dart
  - app/lib/features/chat/widgets/usage_bar.dart
  - app/lib/features/daily/recorder/providers/streaming_transcription_provider.dart
  - app/lib/features/daily/recorder/widgets/streaming_transcription_display.dart
---

# fix: Flutter app error surfacing gaps

Wire existing error infrastructure (`AppError`, `showAppError`, `ErrorRecoveryCard`, `TypedError`) into 5 paths where errors are currently caught and silently swallowed via `debugPrint`. No new error infrastructure needed — all fixes connect existing machinery to existing catch blocks.

Brainstorm: [#50](https://github.com/OpenParachutePBC/parachute-computer/issues/50) | Brainstorm doc: `docs/brainstorms/2026-02-16-flutter-error-surfacing-gaps-brainstorm.md`

## Enhancement Summary

**Deepened on:** 2026-02-17
**Research agents used:** flutter-reviewer, architecture-strategist, code-simplicity-reviewer, parachute-conventions-reviewer, pattern-recognition-specialist

### Key Improvements from Review
1. **Fix 1 — Extract `_showErrorSnackbar` helper** instead of copying 8-line snackbar pattern into 4 more places. Reduces per-catch-block addition to one line.
2. **Fix 2 — Dropped** the `_sessionErrorCache` Map. Three reviewers rejected it as YAGNI / mutable side-channel in StateNotifier. Errors are transient — reloading the session will re-surface any persistent error condition.
3. **Fix 3 — Audit downstream providers** that call `chatSessionsProvider.future`: `workspaceSessionsProvider` and `searchedSessionsProvider` need try/catch guards.
4. **Fix 4 — Use `_log` service** (already on the notifier at line 231) instead of raw `debugPrint` for structured logging.
5. **Fix 5 — Use existing `TranscriptionModelStatus.error` enum** instead of adding a new `initError` field. Propagate error via `Stream.error()` so Riverpod's error channel handles it naturally.

### Architectural Notes
- No module boundary violations — all changes are within their respective feature directories
- Three different error surfacing patterns (snackbar, provider re-throw, stream error) are appropriate contextual diversity, not inconsistency
- `ChatMessagesNotifier` is a 1739-line God Object — future refactor opportunity, not this PR's scope

---

## Fix 1: Journal CRUD silent failures (HIGH)

**File**: `app/lib/features/daily/journal/screens/journal_screen.dart`

**Problem**: `_addTextEntry`, `_addVoiceEntry`, `_updatePendingTranscription`, and `_deleteEntry` catch exceptions and only `debugPrint`. Meanwhile, `_addPhotoEntry` (~line 468) and `_addHandwritingEntry` (~line 505) correctly show error snackbars. Inconsistent UX — some failures visible, some silent.

**Changes**:

1. **Extract a `_showErrorSnackbar` helper** to avoid copying the 8-line snackbar pattern into 4 more places (bringing total to 10+ in this already-large file):

```dart
void _showErrorSnackbar(String message) {
  if (!mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: BrandColors.error,
      duration: const Duration(seconds: 3),
    ),
  );
}
```

This is a void side-effect helper, not a "helper method returning Widget" (which conventions forbid).

2. **Add snackbar calls to the 4 silent catch blocks**:
   - **`_addTextEntry`** (~line 408): `_showErrorSnackbar('Failed to add entry');`
   - **`_addVoiceEntry`** (~line 443): `_showErrorSnackbar('Failed to add voice entry');`
   - **`_updatePendingTranscription`** (~line 568): `_showErrorSnackbar('Voice note saved, but transcript update failed');`
   - **`_deleteEntry`** (~line 1154): `_showErrorSnackbar('Failed to delete entry');`

3. **Also update `_addPhotoEntry` and `_addHandwritingEntry`** to use the same helper for consistency.

Keep existing `debugPrint` for developer logging. Add the helper call after it.

**Note on `_updatePendingTranscription`**: The `pendingTranscriptionEntryId` is cleared at ~line 528 *before* the try block. If the update fails, the user has no way to retry because the pending state is gone. The tailored message ("Voice note saved, but transcript update failed") communicates this — the audio was captured, only the text update failed.

**Edge case — snackbar stacking**: Snackbars queue naturally via `ScaffoldMessenger`. The 3-second duration prevents excessive stacking.

**Edge case — `mounted` after async**: The helper checks `mounted` internally. All four methods are `async`, so the widget may have been disposed between the failed operation and the catch block.

---

## Fix 2: ~~Streaming errors lost on session switch~~ DROPPED

**Rationale**: Three of five reviewers recommended dropping this fix:

- **Flutter reviewer**: Rejected — mutable `Map<String, String>` side-channel in StateNotifier creates dual error tracking alongside `ChatMessagesState.error`. Memory leak (no eviction), timing race with `loadSession`, and fights the intentional `copyWith` error-clearing design.
- **Simplicity reviewer**: YAGNI — errors are transient. When the user switches back, `loadSession()` rebuilds state from the server. If the error condition persists, it re-manifests. Caching the old error is actively misleading if the server has recovered.
- **Architecture reviewer**: Duplicates the existing `state.error` field. If per-session error persistence is needed, it belongs in session metadata at the server layer, not a mutable map on the notifier.

The existing `ChatMessagesState.error` field is sufficient. No changes needed.

---

## Fix 3: FutureProviders with no retry (MEDIUM)

**Files**:
- `app/lib/features/chat/providers/chat_session_providers.dart`
- `app/lib/features/chat/providers/workspace_providers.dart`
- `app/lib/features/chat/providers/session_search_provider.dart`
- `app/lib/features/chat/widgets/usage_bar.dart`

**Problem**: `chatSessionsProvider` (~line 52) catches server errors and returns `[]`. The UI renders an empty list with no indication that the server is down. The `claudeUsageProvider` (~line 186) sets `ClaudeUsage(error: e.toString())` but the UI doesn't check this field.

### 3a: chatSessionsProvider — let error propagate on total failure

**Current** (~line 79): Returns `[]` when both server and local sessions fail.

**Fix**: Keep the local fallback (graceful degradation) but re-throw if both server AND local fail:

```dart
} catch (serverError) {
  try {
    final localSessions = await chatSessionService.getLocalSessions();
    return localSessions.where((s) => !s.archived).toList();
  } catch (_) {
    // Both server and local failed — let error propagate to UI
    throw serverError;
  }
}
```

The `chat_hub_screen.dart` already has `_buildSessionsError` (~line 652) with an icon, title, message, and retry button that handles the `error:` case of `.when()`. This error handler is currently dead code — this fix activates it.

### 3b: Audit downstream providers (NEW — from review)

Two providers call `chatSessionsProvider.future` and would get unhandled exceptions if the provider starts throwing:

- **`workspaceSessionsProvider`** (`workspace_providers.dart` ~line 40): Calls `ref.watch(chatSessionsProvider.future)` when `activeSlug == null`. Add try/catch returning `[]` on error.
- **`searchedSessionsProvider`** (`session_search_provider.dart` ~line 19): Calls `ref.watch(chatSessionsProvider.future)` when query is empty. Add try/catch returning `[]` on error.

Both of these are intermediary providers — their consumers already have `.when(error:)` handlers, so wrapping with try/catch and returning `[]` preserves the current graceful-degradation behavior for filtered/searched views while the hub screen shows the error.

### 3c: claudeUsageProvider — render error in UsageBar

**Current** (`usage_bar.dart` ~line 20): When `usage.hasError || !usage.hasData`, returns `SizedBox.shrink()` — silently hides errors.

**Fix**: Show a minimal "Usage unavailable" indicator instead of hiding entirely. Keep it compact — the usage bar is a small UI element, not a place for a full `ErrorRecoveryCard`:

```dart
if (usage.hasError || !usage.hasData) {
  return Text(
    'Usage unavailable',
    style: TextStyle(color: isDark ? Colors.white54 : Colors.black38, fontSize: 12),
  );
}
```

Do NOT add retry logic to the usage bar — it refreshes automatically via `autoDispose` when the provider is re-watched.

---

## Fix 4: TypedError structured logging (LOW)

**File**: `app/lib/features/chat/providers/chat_message_providers.dart`

**Problem**: The `typedError` case (~line 1506) extracts only the message string from the `TypedError` object. Error code, recovery actions, retry capability, and original error are discarded in the log path.

**Change**: Enhance logging using the existing `_log` service (already on the notifier at line 231, already used for session load errors at line 470):

```dart
case StreamEventType.typedError:
  final typedErr = event.typedError;
  final errorMsg = typedErr?.message ?? event.errorMessage ?? 'Unknown error';

  // Enhanced logging — include full error context via existing _log service
  if (typedErr != null) {
    _log.error('Stream typed error', error: {
      'code': typedErr.code,
      'canRetry': typedErr.canRetry,
      'message': typedErr.message,
      'originalError': typedErr.originalError,
    });
  }

  // ... existing error state update logic unchanged ...
```

Using `_log.error()` instead of `debugPrint` is consistent with how the same notifier logs session load errors. The `TypedError` also has a `toJson()` method — `_log.error('Stream typed error', error: typedErr.toJson())` is an alternative one-liner.

---

## Fix 5: StreamingTranscriptionProvider swallows init errors (MEDIUM)

**Files**:
- `app/lib/features/daily/recorder/providers/streaming_transcription_provider.dart`
- `app/lib/features/daily/recorder/widgets/streaming_transcription_display.dart`

**Problem**: When `autoPauseTranscriptionServiceProvider` fails to initialize (~line 34), the error is caught and replaced with an empty default `StreamingTranscriptionState()`. The recording UI shows "Listening..." but transcription isn't working.

### 5a: Propagate init failure through Riverpod's error channel

**Reviewer consensus**: Do NOT add a new `initError` field to `StreamingTranscriptionState`. The `TranscriptionModelStatus` enum already has an `error` variant, and Riverpod's `StreamProvider` already supports error states natively. Use the existing mechanisms.

**Change in `streaming_transcription_provider.dart`** (~line 34):

```dart
error: (e, st) {
  debugPrint('[StreamingTranscription] Init error: $e');
  // Propagate error via Riverpod's error channel instead of swallowing
  return Stream.error(e, st);
},
```

This is a one-line change. The `StreamProvider` will enter `AsyncError` state, which the display widget's `.when(error:)` handler already receives.

### 5b: Show error in recording UI

**Change in `streaming_transcription_display.dart`** (~line 30):

The `error` handler currently returns `SizedBox.shrink()`. Change to show an indicator:

```dart
error: (e, st) => Text(
  'Live transcription unavailable',
  style: TextStyle(
    color: BrandColors.error,
    fontSize: 12,
  ),
),
```

No changes to `StreamingTranscriptionState` model needed. No `copyWith` modifications. Zero new fields.

**Design decision**: Recording still works even when transcription fails. The error is informational — it tells the user they won't see live transcription, but audio recording continues normally. Don't disable the record button.

---

## Files Summary

| File | Fix | Change |
|------|-----|--------|
| `journal_screen.dart` | 1 | Extract `_showErrorSnackbar` helper, add to 4 catch blocks, update 2 existing |
| `chat_message_providers.dart` | 4 | Enhanced typedError logging via `_log.error()` |
| `chat_session_providers.dart` | 3a | Re-throw when both server and local fail |
| `workspace_providers.dart` | 3b | Add try/catch guard for `chatSessionsProvider.future` |
| `session_search_provider.dart` | 3b | Add try/catch guard for `chatSessionsProvider.future` |
| `usage_bar.dart` | 3c | Show "Usage unavailable" instead of `SizedBox.shrink()` |
| `streaming_transcription_provider.dart` | 5a | `Stream.error(e, st)` instead of swallowing |
| `streaming_transcription_display.dart` | 5b | Show "Live transcription unavailable" on error |

---

## Acceptance Criteria

- [x] All 4 journal CRUD operations show snackbar on failure (via shared `_showErrorSnackbar` helper)
- [x] Existing photo/handwriting catch blocks updated to use same helper
- [x] Empty session list from server+local failure shows error state with retry button
- [x] `workspaceSessionsProvider` and `searchedSessionsProvider` handle `chatSessionsProvider` errors gracefully
- [x] Usage bar shows "Usage unavailable" instead of hiding on error
- [x] `typedError` stream events logged with code, retry capability, and original error via `_log`
- [x] Transcription init failure shows "Live transcription unavailable" in recording UI
- [x] Recording still works when transcription init fails (non-blocking error)
- [x] No new error infrastructure created — all fixes use existing machinery
- [x] `flutter analyze` passes with no new warnings

---

## Out of Scope

- **Session error cache / persistence across switches** — Dropped per reviewer consensus. Errors are transient; reloading re-surfaces persistent conditions.
- **Result wrapper type for providers** — Brainstorm recommended deferring `Result<T>` until the pattern repeats.
- **Inline error banners for journal** — Snackbars match existing patterns.
- **Error recovery actions for journal** — Snackbars are fire-and-forget. `ErrorRecoveryCard` is overkill for CRUD failures.
- **Server-side error propagation** — That's issue #49, a separate concern.
- **Raw `$e` in user-facing snackbars** — Pre-existing pattern in `_addPhotoEntry`/`_addHandwritingEntry`. Fixing all error messages to use `AppError.userMessage` is a separate improvement.
- **Snackbar style unification** — Error snackbars use non-floating style, success snackbars use floating. Pre-existing inconsistency, not this PR's scope.

---

## References

- Brainstorm: [#50](https://github.com/OpenParachutePBC/parachute-computer/issues/50)
- Related: [#40 App UI Stability](https://github.com/OpenParachutePBC/parachute-computer/issues/40)
- Related: [#49 Server-side error propagation](https://github.com/OpenParachutePBC/parachute-computer/issues/49)
- Error infrastructure: `app/lib/core/errors/app_error.dart`, `app/lib/core/widgets/error_snackbar.dart`
- Good pattern reference: `journal_screen.dart` `_addPhotoEntry` (~line 468)
- Downstream providers: `workspace_providers.dart` (~line 40), `session_search_provider.dart` (~line 19)
