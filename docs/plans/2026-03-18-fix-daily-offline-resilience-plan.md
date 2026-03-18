---
title: "fix: Daily offline resilience — gate on connectivity, fast-fail health"
type: fix
date: 2026-03-18
issue: 288
---

# Daily Offline Resilience

## Overview

The Daily journal has solid offline infrastructure (SQLite cache, pending entry queue, two-phase cache-first loading, reconnect flush, pending sync banner) — but several code paths bypass connectivity checks, causing 15-second timeout hangs when offline. This plan targets the specific gaps.

## Problem Statement

When the device is offline:

1. **Text/compose entry creation waits 15 seconds** — `_addTextEntry()` calls `api.createEntry()` without checking `isServerAvailableProvider`. It waits for the full 15-second HTTP timeout before falling back to the pending queue.

2. **Journal loading hangs during Phase 2 flush** — `_loadJournal()` calls `pendingQueue.flush(api)` and `_flushPendingOps(api, cache)` before checking connectivity. Each pending entry's API call waits 15 seconds to timeout. If you have 3 pending entries, that's 45 seconds of spinning.

3. **No fast-fail on API errors** — When the first API call fails, the health state isn't updated. The `periodicServerHealthProvider` only polls every 30 seconds. So the next call also waits 15 seconds to timeout instead of being gated immediately.

4. **Initial health check takes 10 seconds offline** — The health endpoint has a 10-second timeout. On first app launch while offline, `isServerAvailableProvider` is in `loading` state (returns `false`) for 10 seconds before resolving to `networkError`.

## Proposed Solution

### Phase 1: Gate entry creation on connectivity (immediate UX win)

**File: `app/lib/features/daily/journal/screens/journal_screen.dart`**

In `_addTextEntry()` and `_addComposeEntry()`, check `isServerAvailableProvider` before calling the API. If offline, skip the API call entirely and go straight to the pending queue via `_appendEntryToCache(null, ...)`.

```dart
Future<void> _addTextEntry(String text) async {
  final isAvailable = ref.read(isServerAvailableProvider);
  if (!isAvailable) {
    debugPrint('[JournalScreen] Offline — queueing text entry directly');
    await _appendEntryToCache(null, content: text);
    return;
  }
  final api = ref.read(dailyApiServiceProvider);
  final entry = await api.createEntry(content: text);
  await _appendEntryToCache(entry, content: text);
}
```

Same pattern for `_addComposeEntry()`.

- [x] `_addTextEntry`: check `isServerAvailableProvider` before API call
- [x] `_addComposeEntry`: check `isServerAvailableProvider` before API call

### Phase 2: Gate flush operations on connectivity

**File: `app/lib/features/daily/journal/providers/journal_providers.dart`**

In `_loadJournal()`, check connectivity before calling `pendingQueue.flush(api)` and `_flushPendingOps(api, cache)`. Only flush when online.

```dart
// Phase 2 — flush pending ops only when online, then fetch from server.
final isAvailable = ref.read(isServerAvailableProvider);
if (isAvailable) {
  await pendingQueue.flush(api);
  await _flushPendingOps(api, cache);
}

if (!isAvailable) {
  // Offline: skip server fetch, return cached entries only
  ...
}
```

This consolidates the connectivity check — flush and fetch are both gated together.

- [x] `_loadJournal`: gate `pendingQueue.flush()` on `isServerAvailableProvider`
- [x] `_loadJournal`: gate `_flushPendingOps()` on `isServerAvailableProvider`

### Phase 3: Fast-fail health state on API errors

**File: `app/lib/core/providers/backend_health_provider.dart`**

Add a `StateProvider<bool?>` for API call results that can immediately override the health state. When any Daily API call fails with a network error, set this to `false`. When any succeeds, set to `true`. The `isServerAvailableProvider` watches both this override and the periodic health check.

**File: `app/lib/core/providers/connectivity_provider.dart`**

```dart
/// Override for fast-fail/fast-recover. Set by API callers on success/failure.
/// null = no override, use periodic health check.
final serverReachableOverrideProvider = StateProvider<bool?>((ref) => null);

/// Is the server available? Checks override first, then periodic health.
final isServerAvailableProvider = Provider<bool>((ref) {
  // Fast-fail override takes precedence
  final override = ref.watch(serverReachableOverrideProvider);
  if (override != null) return override;

  // Fall back to periodic health check
  final healthAsync = ref.watch(periodicServerHealthProvider);
  return healthAsync.when(
    data: (health) => health != null && health.isHealthy,
    loading: () => false,
    error: (err, st) => false,
  );
});
```

**File: `app/lib/features/daily/journal/services/daily_api_service.dart`**

The API service doesn't have access to `ref`. Instead, add a callback pattern:

```dart
/// Optional callback invoked on network success/failure for fast-fail health updates.
void Function(bool reachable)? onReachabilityChanged;
```

Call `onReachabilityChanged?.call(false)` in catch blocks, `onReachabilityChanged?.call(true)` on success. Wire it up in the provider that creates `DailyApiService`.

**Reset override on periodic health check**: When the periodic check fires, clear the override so it doesn't go stale. Add `ref.listen(periodicServerHealthProvider, ...)` that sets the override to `null`.

- [x] Add `serverReachableOverrideProvider` to connectivity_provider.dart
- [x] Update `isServerAvailableProvider` to check override first
- [x] Add `onReachabilityChanged` callback to `DailyApiService`
- [x] Wire callback in the `dailyApiServiceProvider` to set override
- [x] Clear override when periodic health check fires

### Phase 4: Reduce initial health check timeout

**File: `app/lib/core/services/backend_health_service.dart`**

Reduce the health check timeout from 10 seconds to 3 seconds. The health endpoint is lightweight (`/api/health`) — if it can't respond in 3 seconds, the server is effectively unreachable. This cuts the initial offline detection from 10 seconds to 3 seconds.

- [x] Reduce health check timeout from 10s to 3s

### Phase 5: Polish pending sync banner behavior

The `PendingSyncBanner` already exists and works. Two polish items:

**File: `app/lib/features/daily/journal/widgets/pending_sync_banner.dart`**

1. After retry succeeds, invalidate `pendingSyncCountProvider` so the count updates immediately (it should already via `ref.watch` on the queue/cache, but verify).

2. Show "Syncing..." state during retry to avoid the user tapping Retry multiple times.

**File: `app/lib/features/daily/journal/screens/journal_screen.dart`**

3. In `_retryPendingSync`, check connectivity first — don't attempt flush if offline.

- [x] Verify pending count updates after successful retry
- [x] Add syncing state to retry button (or disable during sync)
- [x] Gate `_retryPendingSync` on connectivity check

## Acceptance Criteria

- [x] Creating a text entry offline is instant — no spinner, no 15-second wait
- [x] Creating a compose entry offline is instant — same
- [x] Opening Daily offline shows cached entries immediately, no long spinner
- [x] After one API call fails, subsequent calls are gated immediately (fast-fail)
- [x] After connectivity returns, first successful call unblocks all API calls (fast-recover)
- [x] Pending sync banner shows correct count and retry works
- [x] Health check timeout is 3s, not 10s

## Technical Considerations

- **`_addVoiceEntryViaServer` already checks connectivity** (line 618) — no change needed
- **Cards/agents providers already check connectivity** (lines 306, 324) — no change needed
- **Journal two-phase load already caches first** — Phase 1 shows cached entries immediately; only Phase 2 is affected
- **`pendingQueue.flush()` has internal re-entrancy guard** — safe to call from multiple paths
- **Override vs periodic health**: The override is a performance optimization, not a correctness requirement. Even without it, the periodic check catches up within 30 seconds. The override just prevents redundant 15-second timeouts in that window.

## Dependencies & Risks

- **Low risk**: All changes are additive gates on existing code paths. No new data flows.
- **No new dependencies**: Uses existing `isServerAvailableProvider` pattern everywhere.
- **Backward compatible**: If the override provider is never set, behavior is identical to current code.

## Files Changed

| File | Changes |
|------|---------|
| `app/lib/features/daily/journal/screens/journal_screen.dart` | Gate `_addTextEntry`, `_addComposeEntry`, `_retryPendingSync` on connectivity |
| `app/lib/features/daily/journal/providers/journal_providers.dart` | Gate flush operations in `_loadJournal` on connectivity |
| `app/lib/core/providers/connectivity_provider.dart` | Add `serverReachableOverrideProvider`, update `isServerAvailableProvider` |
| `app/lib/core/services/backend_health_service.dart` | Reduce timeout 10s → 3s |
| `app/lib/features/daily/journal/services/daily_api_service.dart` | Add `onReachabilityChanged` callback |
| `app/lib/features/daily/journal/widgets/pending_sync_banner.dart` | Polish retry behavior |
