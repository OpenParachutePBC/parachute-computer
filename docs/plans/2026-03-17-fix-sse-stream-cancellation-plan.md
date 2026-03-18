---
title: "Fix SSE stream cancellation — provider rebuild kills active HTTP streams"
type: fix
date: 2026-03-17
issue: 283
---

# Fix SSE stream cancellation — provider rebuild kills active HTTP streams

Chat sessions stall mid-response because `chatServiceProvider` rebuilds destroy the shared `http.Client`, severing all active SSE connections.

## Problem

`chatServiceProvider` uses `ref.watch()` on two async providers (`aiServerUrlProvider`, `apiKeyProvider`). When either re-emits — even the same value during `AsyncLoading → AsyncData` transitions — Riverpod rebuilds the provider, calling `service.dispose()` → `_client.close()`. This kills **all** active SSE streams simultaneously.

**Evidence from server logs (2026-03-17):**
- Two concurrent sessions (`3d6de969`, `c819bc2e`) cancel within 2-6 seconds of each other — proves shared resource disruption, not per-session issue
- Server continues producing output after client disconnects (`result_len > 0`) — the model isn't stalling, the pipe is breaking
- Cancellation frequency jumped from ~19/day (Mar 6) to 74/day (Mar 17), correlating with Mar 13 changes (`apiKeyProvider` → secure storage migration, ChatMessagesNotifier decomposition)
- `CancelledError` (not `client_disconnected`) — disconnect happens at TCP layer when `http.Client.close()` severs connections

**Chain of events:**
1. Async provider re-emits (e.g., `apiKeyProvider` loading → data)
2. `chatServiceProvider` rebuilds → old `ChatService.dispose()` → `_client.close()`
3. All SSE byte streams die → `BackgroundStreamManager` source subscriptions get `onDone`
4. Server detects TCP disconnect → `CancelledError` → `reason=cancelled`
5. Orchestrator keeps running (orphaned SDK process) but nobody is listening
6. User sees response freeze with no error indication

## Acceptance Criteria

- [x] `chatServiceProvider` does NOT rebuild when `aiServerUrlProvider` / `apiKeyProvider` re-emit during async transitions
- [x] Active SSE streams survive provider lifecycle changes
- [x] Two concurrent chat sessions can stream without either being cancelled by the other's lifecycle
- [x] User sees an error indication (not silent freeze) if a stream genuinely dies
- [x] Server-side: early returns in `_run_trusted` always yield a DoneEvent for clean client-side handling
- [x] `claude-agent-sdk` upgraded from 0.1.44 → 0.1.49

## Solution

### Fix 1: Stabilize `chatServiceProvider` (PRIMARY FIX)

**File:** `app/lib/features/chat/providers/chat_session_providers.dart`

Replace `ref.watch()` with `ref.read()` + `ref.listen()` to avoid rebuilds on async state transitions. The ChatService only needs the resolved values, not reactive updates during loading.

```dart
final chatServiceProvider = Provider<ChatService>((ref) {
  // Read resolved values once — don't watch async transitions
  final baseUrl = ref.read(aiServerUrlProvider).valueOrNull
      ?? AppConfig.defaultServerUrl;
  final apiKey = ref.read(apiKeyProvider).valueOrNull;

  final service = ChatService(baseUrl: baseUrl, apiKey: apiKey);

  // Listen for ACTUAL value changes (not loading→data transitions)
  // and update the service's config without rebuilding
  ref.listen(aiServerUrlProvider, (prev, next) {
    final newUrl = next.valueOrNull;
    if (newUrl != null && newUrl != service.baseUrl) {
      service.updateBaseUrl(newUrl);
    }
  });
  ref.listen(apiKeyProvider, (prev, next) {
    final newKey = next.valueOrNull;
    if (newKey != service.apiKey) {
      service.updateApiKey(newKey);
    }
  });

  ref.onDispose(() => service.dispose());
  return service;
});
```

**File:** `app/lib/features/chat/services/chat_service.dart`

Add mutable config methods (no HTTP client recreation needed — just update the stored values used for future requests):

```dart
void updateBaseUrl(String newUrl) {
  baseUrl = newUrl;
  _cachedHeaders = null; // Reset cached headers
}

void updateApiKey(String? newKey) {
  apiKey = newKey;
  _cachedHeaders = null;
}
```

Change `baseUrl` and `apiKey` from `final` to mutable fields.

### Fix 2: Server-side — always yield DoneEvent on early exit

**File:** `computer/parachute/core/orchestrator.py`

The `event_timeout` and `error` handlers at lines 1114-1154 return early without yielding a DoneEvent. This means the SSE client never gets a terminal event and can't distinguish "stream complete" from "stream stalled."

Wrap the SDK event loop in a try/finally that always yields DoneEvent:

```python
# After the SDK event loop (line ~1156), in a finally block:
finally:
    # Always yield a done event so the client knows streaming ended
    if not done_event_yielded:
        yield DoneEvent(
            session_id=captured_session_id or session.id,
            end_reason=end_reason,
        ).model_dump(by_alias=True)
```

This applies to the `event_timeout` (line 1127) and `error` (line 1154) early-return paths.

### Fix 3: Upgrade claude-agent-sdk

**File:** `computer/pyproject.toml`

Bump `claude-agent-sdk>=0.1.29` → `claude-agent-sdk>=0.1.49` (5 versions behind; may contain fixes for event parsing or subprocess lifecycle).

### Fix 4: Client-side error surfacing (minor)

**File:** `app/lib/features/chat/services/chat_service.dart`

The synthetic done event at line 246 (`'Stream ended without explicit done event'`) should log a warning and include metadata so the UI can show "Response interrupted" instead of silently freezing:

```dart
debugPrint('[ChatService] ⚠️ Stream ended without done event — possible disconnect');
yield StreamEvent(
  type: StreamEventType.done,
  data: {'note': 'Stream ended without explicit done event', 'interrupted': true},
);
```

## Technical Considerations

- **`ref.read` vs `ref.watch` in providers**: Using `ref.read` in a `Provider` is intentional here — we want the value at creation time, not reactive rebuilds. The `ref.listen` calls handle genuine value changes without destroying the service.
- **Mutable ChatService fields**: Making `baseUrl`/`apiKey` mutable is safe because they're only read when constructing new HTTP requests, not during active streams. Active streams use the already-established TCP connection.
- **DoneEvent on early exit**: Must track whether a DoneEvent was already yielded to avoid duplicates. The existing `end_reason` variable can gate this.
- **SDK upgrade risk**: 0.1.44 → 0.1.49 is a minor bump. The monkey-patch in `claude_sdk.py` may need adjustment if the SDK's internal structure changed.

## Files to Modify

**Flutter (app/):**
- `lib/features/chat/providers/chat_session_providers.dart` — Fix 1: stabilize provider
- `lib/features/chat/services/chat_service.dart` — Fix 1: add mutable config + Fix 4: error surfacing

**Python (computer/):**
- `parachute/core/orchestrator.py` — Fix 2: DoneEvent on early exit
- `pyproject.toml` — Fix 3: SDK version bump

## Dependencies & Risks

- **Low risk**: Fix 1 is the primary change and is purely additive (no behavioral change to other providers)
- **SDK upgrade**: Run existing tests after upgrading to catch any breaking changes
- **No migration needed**: All changes are backward-compatible
