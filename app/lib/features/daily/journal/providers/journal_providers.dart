import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/sync_provider.dart';
import 'package:parachute/core/providers/base_server_provider.dart';
import 'package:parachute/core/services/base_server_service.dart';
import '../models/chat_log.dart';
import '../models/journal_day.dart';
import '../models/journal_entry.dart';
import '../models/reflection.dart';
import '../models/agent_output.dart';
import '../services/chat_log_service.dart';
import '../services/para_id_service.dart';
import '../services/journal_service.dart';
import '../services/reflection_service.dart';
import '../services/agent_output_service.dart';
import '../services/local_agent_config_service.dart';

/// Async provider that properly initializes the journal service
///
/// Use this when you need the fully initialized service.
/// Uses FileSystemService to get the configured journal folder name.
final journalServiceFutureProvider = FutureProvider.autoDispose<JournalService>((ref) async {
  final fileSystemService = ref.watch(fileSystemServiceProvider);
  await fileSystemService.initialize();
  final journalPath = await fileSystemService.getJournalPath();

  final paraIdService = ParaIdService(modulePath: journalPath, module: 'daily');
  await paraIdService.initialize();

  final journalService = await JournalService.create(
    fileSystemService: fileSystemService,
    paraIdService: paraIdService,
  );

  await journalService.ensureDirectoryExists();

  // Wire up sync trigger for all journal data changes
  journalService.onDataChanged = () {
    debugPrint('[JournalService] Data changed, scheduling sync...');
    try {
      ref.read(syncProvider.notifier).scheduleSync();
    } catch (e) {
      debugPrint('[JournalService] Failed to schedule sync: $e');
    }
  };

  return journalService;
});

/// Provider for tracking the currently selected date
final selectedJournalDateProvider = StateProvider<DateTime>((ref) {
  return DateTime.now();
});

/// Provider for triggering journal refresh
final journalRefreshTriggerProvider = StateProvider<int>((ref) => 0);

/// Provider for today's journal
///
/// Automatically refreshes when the refresh trigger changes.
final todayJournalProvider = FutureProvider.autoDispose<JournalDay>((ref) async {
  // Watch the refresh trigger to enable manual refreshes
  ref.watch(journalRefreshTriggerProvider);

  final journalService = await ref.watch(journalServiceFutureProvider.future);
  return journalService.loadToday();
});

/// Provider for a specific date's journal
///
/// Uses the selected date from selectedJournalDateProvider.
final selectedJournalProvider = FutureProvider.autoDispose<JournalDay>((ref) async {
  final date = ref.watch(selectedJournalDateProvider);
  ref.watch(journalRefreshTriggerProvider);

  final journalService = await ref.watch(journalServiceFutureProvider.future);
  return journalService.loadDay(date);
});

/// Provider for the list of available journal dates
final journalDatesProvider = FutureProvider.autoDispose<List<DateTime>>((ref) async {
  ref.watch(journalRefreshTriggerProvider);

  final journalService = await ref.watch(journalServiceFutureProvider.future);
  return journalService.listJournalDates();
});

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
const _agentConfigsCacheTtl = Duration(minutes: 5);

/// Provider for the list of configured daily agents (reads locally from Daily/.agents/)
///
/// This works offline - no server connection needed.
/// Uses in-memory caching to avoid disk reads during scroll.
final localAgentConfigsProvider = FutureProvider.autoDispose<List<DailyAgentConfig>>((ref) async {
  // Only watch refresh trigger for manual refresh, not auto-reload
  // Using read instead of watch to avoid triggering on every journal change
  final _ = ref.watch(journalRefreshTriggerProvider);

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

/// State notifier for triggering agent runs
class AgentTriggerNotifier extends StateNotifier<AsyncValue<AgentRunResult?>> {
  final String agentName;
  final Ref _ref;

  AgentTriggerNotifier(this.agentName, this._ref) : super(const AsyncValue.data(null));

  Future<void> trigger({String? date, bool force = false}) async {
    state = const AsyncValue.loading();

    try {
      final server = BaseServerService();
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

/// State notifier for managing journal entry operations
class JournalNotifier extends StateNotifier<AsyncValue<JournalDay>> {
  final JournalService _journalService;
  final Ref _ref;
  DateTime _currentDate;
  // ignore: unused_field
  String? _journalFilePath;

  JournalNotifier(this._journalService, this._ref, this._currentDate)
      : super(const AsyncValue.loading()) {
    _loadJournal();
  }

  // TODO: Add local RAG indexing when sqlite search is implemented
  // ignore: unused_element
  void _indexEntry(JournalEntry entry) {
    // Future: index in local SQLite RAG database
  }

  // ignore: unused_element
  void _removeEntryFromIndex(String entryId) {
    // Future: remove from local SQLite RAG database
  }

  DateTime get currentDate => _currentDate;

  Future<void> _loadJournal() async {
    state = const AsyncValue.loading();
    try {
      final journal = await _journalService.loadDay(_currentDate);
      _journalFilePath = journal.filePath;
      state = AsyncValue.data(journal);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Change to a different date
  Future<void> changeDate(DateTime date) async {
    _currentDate = DateTime(date.year, date.month, date.day);
    await _loadJournal();
  }

  /// Go to today
  Future<void> goToToday() async {
    await changeDate(DateTime.now());
  }

  /// Refresh the current journal
  Future<void> refresh() async {
    await _loadJournal();
  }

  /// Add a text entry with optimistic UI update
  /// Updates the UI immediately, saves in background
  Future<JournalEntry?> addTextEntry({
    required String content,
    String? title,
  }) async {
    try {
      final result = await _journalService.addTextEntry(
        content: content,
        title: title,
      );

      // Update state immediately with the returned journal (no reload needed!)
      _journalFilePath = result.journal.filePath;
      state = AsyncValue.data(result.journal);
      _triggerRefresh();

      // Index the new entry (fire-and-forget)
      _indexEntry(result.entry);

      return result.entry;
    } catch (e, st) {
      debugPrint('[JournalNotifier] Error adding text entry: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Add a voice entry with optimistic UI update
  Future<JournalEntry?> addVoiceEntry({
    required String transcript,
    required String audioPath,
    required int durationSeconds,
    String? title,
  }) async {
    try {
      final result = await _journalService.addVoiceEntry(
        transcript: transcript,
        audioPath: audioPath,
        durationSeconds: durationSeconds,
        title: title,
      );

      // Update state immediately with the returned journal
      _journalFilePath = result.journal.filePath;
      state = AsyncValue.data(result.journal);
      _triggerRefresh();

      // Index the new entry (fire-and-forget)
      _indexEntry(result.entry);

      return result.entry;
    } catch (e, st) {
      debugPrint('[JournalNotifier] Error adding voice entry: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Add a linked entry (for long recordings) with optimistic UI update
  Future<JournalEntry?> addLinkedEntry({
    required String linkedFilePath,
    String? audioPath,
    int? durationSeconds,
    String? title,
  }) async {
    try {
      final result = await _journalService.addLinkedEntry(
        linkedFilePath: linkedFilePath,
        audioPath: audioPath,
        durationSeconds: durationSeconds,
        title: title,
      );

      // Update state immediately with the returned journal
      _journalFilePath = result.journal.filePath;
      state = AsyncValue.data(result.journal);
      _triggerRefresh();

      // Index the new entry (fire-and-forget)
      _indexEntry(result.entry);

      return result.entry;
    } catch (e, st) {
      debugPrint('[JournalNotifier] Error adding linked entry: $e');
      debugPrint('$st');
      return null;
    }
  }

  /// Update an entry
  Future<void> updateEntry(JournalEntry entry) async {
    try {
      await _journalService.updateEntry(_currentDate, entry);
      await _loadJournal();
      _triggerRefresh();

      // Re-index the updated entry (fire-and-forget)
      _indexEntry(entry);
    } catch (e, st) {
      debugPrint('[JournalNotifier] Error updating entry: $e');
      debugPrint('$st');
    }
  }

  /// Delete an entry
  Future<void> deleteEntry(String entryId) async {
    try {
      await _journalService.deleteEntry(_currentDate, entryId);
      await _loadJournal();
      _triggerRefresh();

      // Remove from search index (fire-and-forget)
      _removeEntryFromIndex(entryId);
    } catch (e, st) {
      debugPrint('[JournalNotifier] Error deleting entry: $e');
      debugPrint('$st');
    }
  }

  void _triggerRefresh() {
    _ref.read(journalRefreshTriggerProvider.notifier).state++;
    // Schedule a sync after local changes
    debugPrint('[JournalNotifier] Triggering sync after local change...');
    try {
      _ref.read(syncProvider.notifier).scheduleSync();
      debugPrint('[JournalNotifier] Sync scheduled successfully');
    } catch (e) {
      debugPrint('[JournalNotifier] Failed to schedule sync: $e');
    }
  }
}

/// Provider for journal operations on the current date
///
/// This is the main provider to use for journal interactions.
final journalNotifierProvider =
    StateNotifierProvider<JournalNotifier, AsyncValue<JournalDay>>((ref) {
  // This will throw if the service isn't ready yet
  // In practice, ensure the service is initialized before using this
  throw UnimplementedError(
    'journalNotifierProvider must be overridden with proper initialization',
  );
});

/// Family provider for journal notifier that properly initializes
final journalNotifierFamilyProvider = FutureProvider.autoDispose.family<JournalNotifier, DateTime>(
  (ref, date) async {
    final journalService = await ref.watch(journalServiceFutureProvider.future);
    return JournalNotifier(journalService, ref, date);
  },
);
