import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/config/app_config.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart'
    show aiServerUrlProvider;
import 'package:parachute/core/providers/app_state_provider.dart'
    show apiKeyProvider;
import 'package:parachute/core/providers/backend_health_provider.dart'
    show periodicServerHealthProvider;
import 'package:parachute/core/providers/connectivity_provider.dart'
    show isServerAvailableProvider, serverReachableOverrideProvider;
import 'package:parachute/core/services/graph_api_service.dart';
import '../models/journal_entry.dart';
import '../models/journal_day.dart';
import '../services/daily_api_service.dart';
import '../services/journal_local_cache.dart';
import '../services/pending_entry_queue.dart';

// ============================================================================
// Daily API Service Providers (server-backed)
// ============================================================================

/// Provider for DailyApiService — mirrors chatServiceProvider pattern
final dailyApiServiceProvider = Provider<DailyApiService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? AppConfig.defaultServerUrl;
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = DailyApiService(
    baseUrl: baseUrl,
    apiKey: apiKey,
    onReachabilityChanged: (reachable) {
      // Fast-fail / fast-recover: immediately update connectivity state
      // without waiting for the next 30s periodic health check.
      ref.read(serverReachableOverrideProvider.notifier).state = reachable;
    },
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Provider for GraphApiService — v2 graph API client.
///
/// Used by DailyApiService internally for all server communication.
final graphApiServiceProvider = Provider<GraphApiService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? AppConfig.defaultServerUrl;
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  return GraphApiService(
    baseUrl: baseUrl,
    apiKey: apiKey,
    onReachabilityChanged: (reachable) {
      ref.read(serverReachableOverrideProvider.notifier).state = reachable;
    },
  );
});

/// Provider for the local SQLite cache — offline fallback for journal entries.
///
/// Opens once per app session; disposed when no longer referenced.
/// Falls back to in-memory database if documents directory is unavailable.
final journalLocalCacheProvider = FutureProvider<JournalLocalCache>((
  ref,
) async {
  final cache = await JournalLocalCache.open();
  ref.onDispose(cache.dispose);
  return cache;
});

/// Provider for PendingEntryQueue — SharedPreferences-backed offline queue
final pendingQueueProvider = FutureProvider<PendingEntryQueue>((ref) async {
  final queue = await PendingEntryQueue.create();
  ref.onDispose(queue.dispose);
  return queue;
});

/// Provider for tracking the currently selected date
final selectedJournalDateProvider = StateProvider<DateTime>((ref) {
  return DateTime.now();
});

/// Provider for triggering journal refresh
final journalRefreshTriggerProvider = StateProvider<int>((ref) => 0);

/// Formats a DateTime as YYYY-MM-DD for API calls.
String _formatDateForApi(DateTime date) {
  final y = date.year.toString();
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Provider for today's journal — cache-first, then server.
///
/// Phase 1: emits cached entries immediately (instant display, works offline).
/// Phase 2: fetches from server, updates cache, emits fresh data.
final todayJournalProvider =
    AsyncNotifierProvider.autoDispose<_TodayJournalNotifier, JournalDay>(
      _TodayJournalNotifier.new,
    );

class _TodayJournalNotifier extends AutoDisposeAsyncNotifier<JournalDay> {
  @override
  Future<JournalDay> build() async {
    ref.watch(journalRefreshTriggerProvider);

    // Flush pending queue when connectivity restores (offline → online transition).
    // Guard on previous == null to ignore the stream's initial emission on (re)start.
    //
    // NOTE: ref.listen callbacks must be synchronous — async lambdas silently
    // discard errors. We fire-and-forget a Future and handle errors inside it.
    // The try/catch also protects against StateError if the notifier is disposed
    // between when the health event fires and when the awaited calls complete.
    ref.listen(periodicServerHealthProvider, (previous, next) {
      if (previous == null) return;
      final wasHealthy = previous.valueOrNull?.isHealthy ?? false;
      final isHealthy = next.valueOrNull?.isHealthy ?? false;
      if (!wasHealthy && isHealthy) {
        Future(() async {
          try {
            final api = ref.read(dailyApiServiceProvider);
            // Register required tags/tools on (re)connect
            await api.registerApp();
            final queue = await ref.read(pendingQueueProvider.future);
            await queue.flush(api);
            // Also flush pending deletes/edits that queued while offline.
            final cache = await ref.read(journalLocalCacheProvider.future);
            await _flushPendingOps(api, cache);
            // _loadJournal already calls flush on every build; no need to increment
            // the refresh trigger here — that would cause a redundant rebuild cycle.
          } catch (e) {
            debugPrint(
              '[_TodayJournalNotifier] Error flushing on reconnect: $e',
            );
          }
        });
      }
    });

    return _loadJournal(ref, DateTime.now(), (day) => state = AsyncData(day));
  }
}

/// Provider for a specific date's journal — cache-first, then server.
final selectedJournalProvider =
    AsyncNotifierProvider.autoDispose<_SelectedJournalNotifier, JournalDay>(
      _SelectedJournalNotifier.new,
    );

class _SelectedJournalNotifier extends AutoDisposeAsyncNotifier<JournalDay> {
  @override
  Future<JournalDay> build() async {
    final date = ref.watch(selectedJournalDateProvider);
    ref.watch(journalRefreshTriggerProvider);
    return _loadJournal(ref, date, (day) => state = AsyncData(day));
  }
}

/// Two-phase journal load: cache first, then server.
///
/// [onCacheHit] is called synchronously when cached entries are available so
/// the notifier can update its state before the server fetch completes — giving
/// instant display even while the network request is in flight.
///
/// Cache strategy:
/// - Phase 1: read SQLite cache → call [onCacheHit] if entries found.
/// - Phase 2: flush pending ops → fetch server → update cache.
/// - If server is unreachable (null): Phase 1 data stays visible.
/// - If server returns HTTP 200 empty: cache is cleared (authoritative empty).
/// - Server is always authoritative when reachable.
Future<JournalDay> _loadJournal(
  Ref ref,
  DateTime date,
  void Function(JournalDay) onCacheHit,
) async {
  final dateStr = _formatDateForApi(date);
  final api = ref.read(dailyApiServiceProvider);
  final pendingQueue = await ref.read(pendingQueueProvider.future);

  // Cache open is fast (SQLite, usually < 5 ms). Awaiting guarantees Phase 1
  // always has access to cached data, even on the very first call.
  // ref.watch establishes a dependency so the notifier rebuilds if the cache
  // provider is ever invalidated (e.g., in tests or after vault change).
  final cache = await ref.watch(journalLocalCacheProvider.future);

  // Phase 1 — serve from cache immediately (excludes pending_delete entries).
  final cached = cache.getEntries(dateStr);
  if (cached.isNotEmpty) {
    final pendingForDate = _pendingForDate(pendingQueue, dateStr);
    onCacheHit(JournalDay.fromEntries(date, [...cached, ...pendingForDate]));
  }

  // Phase 2 — flush pending ops and fetch from server (only when online).
  final isAvailable = ref.watch(isServerAvailableProvider);
  if (!isAvailable) {
    // Offline: skip flush + server fetch, return cached entries only.
    // Flushing when offline would wait 15s per pending entry for timeout.
    final freshCached = cache.getEntries(dateStr);
    final pendingForDate = _pendingForDate(pendingQueue, dateStr);
    return JournalDay.fromEntries(date, [...freshCached, ...pendingForDate]);
  }

  await pendingQueue.flush(api);
  await _flushPendingOps(api, cache);

  // getEntries returns null on network error, [] on authoritative empty.
  final serverEntries = await api.getEntries(date: dateStr);

  if (serverEntries != null) {
    // Server was reachable — it's authoritative.
    if (serverEntries.isEmpty) {
      // HTTP 200 with no entries: this date is genuinely empty.
      // Clear stale cache (removes any leftover entries from deleted sessions etc.).
      cache.clearDate(dateStr);
    } else {
      // UPSERT preserves pending_delete/pending_edit states (see putEntries docs).
      cache.putEntries(dateStr, serverEntries);
      // Prune synced entries the server no longer returns — handles the case
      // where entries were deleted server-side but still exist in local cache.
      cache.removeStaleEntries(dateStr, serverEntries.map((e) => e.id).toSet());
    }
  }

  // Re-read cache: now reflects the merged truth — server entries minus
  // pending_delete, plus pending_edit's locally-modified content, or the
  // previous cached snapshot when the server was unreachable.
  final freshCached = cache.getEntries(dateStr);
  final pendingForDate = _pendingForDate(pendingQueue, dateStr);
  return JournalDay.fromEntries(date, [...freshCached, ...pendingForDate]);
}

/// Re-entrancy guard for [_flushPendingOps].
///
/// [selectedJournalProvider] and [todayJournalProvider] may both be alive
/// simultaneously — without this guard both would call _flushPendingOps at the
/// same time, sending duplicate DELETE/PATCH requests for the same IDs.
bool _flushPendingOpsActive = false;

/// Flush pending delete and edit operations for all dates.
///
/// Called during Phase 2 of every journal load and on network reconnect.
/// Re-entrant calls are dropped — the in-flight flush covers them.
Future<void> _flushPendingOps(
  DailyApiService api,
  JournalLocalCache cache,
) async {
  if (_flushPendingOpsActive) return;
  _flushPendingOpsActive = true;
  try {
    // Flush pending deletes
    final deleteIds = cache.getPendingDeletes();
    for (final id in deleteIds) {
      final ok = await api.deleteEntry(id);
      if (ok) {
        // 204 or 404 both treated as success — entry is gone from server.
        cache.removeEntry(id);
      }
      // If ok == false (server error), leave as pending_delete for next flush.
    }

    // Flush pending edits
    final editEntries = cache.getPendingEdits();
    for (final entry in editEntries) {
      final updated = await api.updateEntry(
        entry.id,
        content: entry.content,
        metadata: entry.title.isNotEmpty ? {'title': entry.title} : null,
      );
      if (updated != null) {
        // Update cache with the server's authoritative response and clear the flag.
        cache.markSynced(
          entry.id,
          content: updated.content,
          title: updated.title,
        );
      }
      // If null (offline or server error), leave as pending_edit for next flush.
    }
  } finally {
    _flushPendingOpsActive = false;
  }
}

List<JournalEntry> _pendingForDate(PendingEntryQueue queue, String dateStr) =>
    queue.entries
        .where((e) => _formatDateForApi(e.createdAt) == dateStr)
        .toList();

// ============================================================================
// Sync Status Providers
// ============================================================================

/// Count of entries pending sync (queue + pending deletes + pending edits).
///
/// Returns 0 if unable to read the queue or cache.
final pendingSyncCountProvider = FutureProvider<int>((ref) async {
  try {
    final cache = await ref.watch(journalLocalCacheProvider.future);
    final queue = await ref.watch(pendingQueueProvider.future);

    final queueCount = queue.length;
    final pendingDeletes = cache.getPendingDeletes().length;
    final pendingEdits = cache.getPendingEdits().length;

    return queueCount + pendingDeletes + pendingEdits;
  } catch (e) {
    return 0;
  }
});
