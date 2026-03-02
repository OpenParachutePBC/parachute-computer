import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/sync_provider.dart';
import 'package:parachute/core/providers/computer_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart' show aiServerUrlProvider;
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/services/computer_service.dart';
import '../models/chat_log.dart';
import '../models/journal_entry.dart';
import '../models/journal_day.dart';
import '../models/reflection.dart';
import '../models/agent_output.dart';
import '../services/chat_log_service.dart';
import '../services/daily_api_service.dart';
import '../services/journal_local_cache.dart';
import '../services/pending_entry_queue.dart';
import '../services/reflection_service.dart';
import '../services/agent_output_service.dart';
import '../services/local_agent_config_service.dart';

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
  final cache = await ref.read(journalLocalCacheProvider.future);

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
// Reflection Providers
// ============================================================================

/// Async provider for ReflectionService
final reflectionServiceFutureProvider = FutureProvider.autoDispose<ReflectionService>((ref) async {
  final fileSystemService = ref.watch(fileSystemServiceProvider);
  await fileSystemService.initialize();
  return ReflectionService.create(fileSystemService: fileSystemService);
});

/// Provider for the selected date's reflection (morning reflection for that day)
final selectedReflectionProvider = FutureProvider.autoDispose<Reflection?>((ref) async {
  final date = ref.watch(selectedJournalDateProvider);
  ref.watch(journalRefreshTriggerProvider);

  final reflectionService = await ref.watch(reflectionServiceFutureProvider.future);
  return reflectionService.loadReflection(date);
});

// ============================================================================
// Daily Agent Providers
// ============================================================================

/// Provider for the LocalAgentConfigService (reads agent configs from Daily/.agents/)
final localAgentConfigServiceFutureProvider = FutureProvider.autoDispose<LocalAgentConfigService>((ref) async {
  final fileSystemService = ref.watch(fileSystemServiceProvider);
  await fileSystemService.initialize();
  return LocalAgentConfigService.create(fileSystemService: fileSystemService);
});

/// Provider for the AgentOutputService
final agentOutputServiceFutureProvider = FutureProvider.autoDispose<AgentOutputService>((ref) async {
  final fileSystemService = ref.watch(fileSystemServiceProvider);
  await fileSystemService.initialize();
  return AgentOutputService.create(fileSystemService: fileSystemService);
});

/// Cached agent configs with TTL to avoid disk reads on every scroll
List<DailyAgentConfig>? _cachedAgentConfigs;
DateTime? _agentConfigsCacheTime;
int? _cachedAgentRefreshTrigger;
const _agentConfigsCacheTtl = Duration(minutes: 5);

/// Provider for the list of configured daily agents (reads locally from Daily/.agents/)
///
/// This works offline - no server connection needed.
/// Uses in-memory caching to avoid disk reads during scroll.
/// Cache is invalidated when journalRefreshTriggerProvider changes.
final localAgentConfigsProvider = FutureProvider.autoDispose<List<DailyAgentConfig>>((ref) async {
  // Watch refresh trigger - when it changes, we need to clear the cache
  final refreshTrigger = ref.watch(journalRefreshTriggerProvider);

  // Clear cache if refresh trigger changed (user requested refresh)
  if (_cachedAgentRefreshTrigger != null && _cachedAgentRefreshTrigger != refreshTrigger) {
    _cachedAgentConfigs = null;
    _agentConfigsCacheTime = null;
  }
  _cachedAgentRefreshTrigger = refreshTrigger;

  // Return cached if valid
  if (_cachedAgentConfigs != null && _agentConfigsCacheTime != null) {
    final elapsed = DateTime.now().difference(_agentConfigsCacheTime!);
    if (elapsed < _agentConfigsCacheTtl) {
      return _cachedAgentConfigs!;
    }
  }

  final service = await ref.watch(localAgentConfigServiceFutureProvider.future);
  final configs = await service.discoverAgents();

  // Update cache
  _cachedAgentConfigs = configs;
  _agentConfigsCacheTime = DateTime.now();

  return configs;
});

/// Provider for a specific agent's outputs
final agentOutputsProvider = FutureProvider.autoDispose.family<List<AgentOutput>, String>((ref, agentName) async {
  ref.watch(journalRefreshTriggerProvider);

  final service = await ref.watch(agentOutputServiceFutureProvider.future);
  final agents = await ref.watch(localAgentConfigsProvider.future);

  final agentConfig = agents.where((a) => a.name == agentName).firstOrNull;
  if (agentConfig == null) {
    return [];
  }

  return service.listAgentOutputs(agentName, agentConfig.outputDirectory);
});

/// Provider for all agent outputs for a specific date
final agentOutputsForDateProvider = FutureProvider.autoDispose.family<List<AgentOutput>, DateTime>((ref, date) async {
  ref.watch(journalRefreshTriggerProvider);

  final service = await ref.watch(agentOutputServiceFutureProvider.future);
  final agents = await ref.watch(localAgentConfigsProvider.future);

  return service.listOutputsForDate(agents, date);
});

/// Enum for agent output loading state
enum AgentLoadingState {
  /// Output available locally
  ready,
  /// Checking server for output
  checking,
  /// Pulling output from server
  pulling,
  /// No output available anywhere
  notAvailable,
  /// Server not connected, using local only
  offline,
}

/// State for each agent's loading status
class AgentLoadingStatus {
  final String agentName;
  final String displayName;
  final AgentLoadingState state;
  final String? outputPath;

  const AgentLoadingStatus({
    required this.agentName,
    required this.displayName,
    required this.state,
    this.outputPath,
  });

  AgentLoadingStatus copyWith({
    String? agentName,
    String? displayName,
    AgentLoadingState? state,
    String? outputPath,
  }) {
    return AgentLoadingStatus(
      agentName: agentName ?? this.agentName,
      displayName: displayName ?? this.displayName,
      state: state ?? this.state,
      outputPath: outputPath ?? this.outputPath,
    );
  }
}

/// Provider that checks server for agent outputs and tracks loading state
///
/// This provider:
/// 1. First loads local outputs (fast, works offline)
/// 2. If connected to server, checks which agents have outputs available
/// 3. For any agents with outputs on server but not locally, triggers a sync
/// 4. Returns loading states for each agent so UI can show appropriate feedback
final agentLoadingStatusProvider = FutureProvider.autoDispose.family<List<AgentLoadingStatus>, DateTime>((ref, date) async {
  ref.watch(journalRefreshTriggerProvider);

  // Get local agent configs
  final agents = await ref.watch(localAgentConfigsProvider.future);
  if (agents.isEmpty) {
    return [];
  }

  // Get local outputs
  final outputService = await ref.watch(agentOutputServiceFutureProvider.future);
  final localOutputs = await outputService.listOutputsForDate(agents, date);
  final localAgentNames = localOutputs.map((o) => o.agentName).toSet();

  // Build initial status - mark all configured agents
  final statusMap = <String, AgentLoadingStatus>{};
  for (final agent in agents) {
    final hasLocal = localAgentNames.contains(agent.name);
    statusMap[agent.name] = AgentLoadingStatus(
      agentName: agent.name,
      displayName: agent.displayName,
      state: hasLocal ? AgentLoadingState.ready : AgentLoadingState.checking,
      outputPath: hasLocal ? localOutputs.firstWhere((o) => o.agentName == agent.name).filePath : null,
    );
  }

  // Check if server is connected
  final serverConnected = ref.watch(serverConnectedProvider).valueOrNull ?? false;
  if (!serverConnected) {
    // Mark all non-ready agents as offline
    for (final agent in agents) {
      if (statusMap[agent.name]?.state == AgentLoadingState.checking) {
        statusMap[agent.name] = statusMap[agent.name]!.copyWith(
          state: AgentLoadingState.offline,
        );
      }
    }
    return statusMap.values.toList();
  }

  // Check server for available outputs
  final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  final server = ComputerService();
  final serverStatus = await server.getDailyAgentsStatus(date: dateStr);

  if (serverStatus == null) {
    // Server check failed, mark as offline
    for (final agent in agents) {
      if (statusMap[agent.name]?.state == AgentLoadingState.checking) {
        statusMap[agent.name] = statusMap[agent.name]!.copyWith(
          state: AgentLoadingState.offline,
        );
      }
    }
    return statusMap.values.toList();
  }

  // Find agents that have outputs on server but not locally
  final needsPull = <String>[];
  for (final serverAgent in serverStatus.agents) {
    final agentName = serverAgent.name;
    if (serverAgent.hasOutput && !localAgentNames.contains(agentName)) {
      // Server has output we don't have locally - need to pull
      needsPull.add(serverAgent.outputPath!);
      statusMap[agentName] = statusMap[agentName]?.copyWith(
        state: AgentLoadingState.pulling,
        outputPath: serverAgent.outputPath,
      ) ?? AgentLoadingStatus(
        agentName: agentName,
        displayName: serverAgent.displayName,
        state: AgentLoadingState.pulling,
        outputPath: serverAgent.outputPath,
      );
    } else if (!serverAgent.hasOutput && !localAgentNames.contains(agentName)) {
      // No output anywhere
      statusMap[agentName] = statusMap[agentName]?.copyWith(
        state: AgentLoadingState.notAvailable,
      ) ?? AgentLoadingStatus(
        agentName: agentName,
        displayName: serverAgent.displayName,
        state: AgentLoadingState.notAvailable,
      );
    }
  }

  // Pull missing outputs from server
  if (needsPull.isNotEmpty) {
    debugPrint('[AgentLoadingStatus] Pulling ${needsPull.length} agent outputs from server');
    final syncNotifier = ref.read(syncProvider.notifier);

    // Pull the files
    for (final outputPath in needsPull) {
      await syncNotifier.pullFile(outputPath);
    }

    // Trigger refresh to reload outputs
    ref.read(journalRefreshTriggerProvider.notifier).state++;
  }

  return statusMap.values.toList();
});

/// State notifier for triggering agent runs
class AgentTriggerNotifier extends StateNotifier<AsyncValue<AgentRunResult?>> {
  final String agentName;
  final Ref _ref;

  AgentTriggerNotifier(this.agentName, this._ref) : super(const AsyncValue.data(null));

  Future<void> trigger({String? date, bool force = false}) async {
    state = const AsyncValue.loading();

    try {
      final server = ComputerService();
      final result = await server.triggerDailyAgent(agentName, date: date, force: force);
      state = AsyncValue.data(result);

      // Trigger refresh to pick up new output
      if (result.success) {
        _ref.read(journalRefreshTriggerProvider.notifier).state++;
      }
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  void reset() {
    state = const AsyncValue.data(null);
  }
}

