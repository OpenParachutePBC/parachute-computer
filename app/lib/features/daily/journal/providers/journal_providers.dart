import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart' show aiServerUrlProvider;
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/services/computer_service.dart' show DailyAgentInfo;
import '../models/chat_log.dart';
import '../models/journal_entry.dart';
import '../models/journal_day.dart';
import '../models/agent_card.dart';
import '../services/chat_log_service.dart';
import '../services/daily_api_service.dart';
import '../services/journal_local_cache.dart';
import '../services/pending_entry_queue.dart';

// ============================================================================
// Daily API Service Providers (server-backed)
// ============================================================================

/// Provider for DailyApiService — mirrors chatServiceProvider pattern
final dailyApiServiceProvider = Provider<DailyApiService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? 'http://localhost:3333';
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = DailyApiService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(service.dispose);
  return service;
});

/// Provider for the local SQLite cache — offline fallback for journal entries.
///
/// Opens once per app session; disposed when no longer referenced.
/// Falls back to in-memory database if documents directory is unavailable.
final journalLocalCacheProvider = FutureProvider<JournalLocalCache>((ref) async {
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
/// - Phase 2: flush pending queue → fetch server → update cache.
/// - If server returns empty (offline/error): Phase 1 data stays visible.
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

  // Phase 1 — serve from cache immediately.
  final cached = cache.getEntries(dateStr);
  if (cached.isNotEmpty) {
    final pendingForDate = _pendingForDate(pendingQueue, dateStr);
    onCacheHit(JournalDay.fromEntries(date, [...cached, ...pendingForDate]));
  }

  // Phase 2 — flush pending creates, then fetch from server.
  await pendingQueue.flush(api);
  final serverEntries = await api.getEntries(date: dateStr);

  if (serverEntries.isNotEmpty) {
    cache.putEntries(dateStr, serverEntries);
  }

  final sourceEntries = serverEntries.isNotEmpty ? serverEntries : cached;
  final pendingForDate = _pendingForDate(pendingQueue, dateStr);
  return JournalDay.fromEntries(date, [...sourceEntries, ...pendingForDate]);
}

List<JournalEntry> _pendingForDate(PendingEntryQueue queue, String dateStr) =>
    queue.entries
        .where((e) => _formatDateForApi(e.createdAt) == dateStr)
        .toList();

// ============================================================================
// Chat Log Providers
// ============================================================================

/// Async provider for ChatLogService
final chatLogServiceFutureProvider = FutureProvider.autoDispose<ChatLogService>((ref) async {
  final fileSystemService = ref.watch(fileSystemServiceProvider);
  await fileSystemService.initialize();
  return ChatLogService.create(fileSystemService: fileSystemService);
});

/// Provider for the selected date's chat log
final selectedChatLogProvider = FutureProvider.autoDispose<ChatLog?>((ref) async {
  final date = ref.watch(selectedJournalDateProvider);
  ref.watch(journalRefreshTriggerProvider);

  final chatLogService = await ref.watch(chatLogServiceFutureProvider.future);
  return chatLogService.loadChatLog(date);
});

// ============================================================================
// Card Providers (graph-backed)
// ============================================================================

/// Fetch all Card nodes for a date from the server.
///
/// Family parameter: YYYY-MM-DD date string.
/// Returns empty list if offline or server unavailable.
final cardsProvider =
    FutureProvider.autoDispose.family<List<AgentCard>, String>((ref, dateStr) async {
  ref.watch(journalRefreshTriggerProvider);
  final api = ref.watch(dailyApiServiceProvider);
  return api.fetchCards(dateStr);
});

/// Fetch registered Caller (agent definition) nodes from the server.
///
/// Used by [AgentTriggerCard] to enumerate agents without local file reads.
final callersProvider =
    FutureProvider.autoDispose<List<DailyAgentInfo>>((ref) async {
  ref.watch(journalRefreshTriggerProvider);
  final api = ref.watch(dailyApiServiceProvider);
  return api.fetchCallers();
});
