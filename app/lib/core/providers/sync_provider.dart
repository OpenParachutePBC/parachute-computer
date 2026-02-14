import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sync_service.dart';
import 'app_state_provider.dart';

/// Sync state for UI
class SyncState {
  final SyncStatus status;
  final SyncResult? lastResult;
  final DateTime? lastSyncTime;
  final String? errorMessage;
  /// Counter that increments each time files are pulled from server
  /// UI can watch this to know when to refresh local data
  final int pullCounter;
  /// Current sync progress (when syncing)
  final SyncProgress? progress;
  /// List of unresolved conflicts (file paths or file#entryId for journal entry conflicts)
  final List<String> unresolvedConflicts;

  const SyncState({
    this.status = SyncStatus.idle,
    this.lastResult,
    this.lastSyncTime,
    this.errorMessage,
    this.pullCounter = 0,
    this.progress,
    this.unresolvedConflicts = const [],
  });

  SyncState copyWith({
    SyncStatus? status,
    SyncResult? lastResult,
    DateTime? lastSyncTime,
    String? errorMessage,
    int? pullCounter,
    SyncProgress? progress,
    List<String>? unresolvedConflicts,
    bool clearProgress = false,
  }) {
    return SyncState(
      status: status ?? this.status,
      lastResult: lastResult ?? this.lastResult,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      errorMessage: errorMessage,
      pullCounter: pullCounter ?? this.pullCounter,
      progress: clearProgress ? null : (progress ?? this.progress),
      unresolvedConflicts: unresolvedConflicts ?? this.unresolvedConflicts,
    );
  }

  bool get isSyncing => status == SyncStatus.syncing;
  bool get hasError => status == SyncStatus.error;
  bool get isIdle => status == SyncStatus.idle;
  bool get hasConflicts => unresolvedConflicts.isNotEmpty;

  /// Progress display string for UI
  String? get progressText {
    if (progress == null) return null;
    final p = progress!;
    if (p.total == 0) return p.phase;
    return '${p.phase}: ${p.current}/${p.total}';
  }
}

/// Provider for setting up a JournalMerger implementation.
///
/// Consuming apps should override this to provide their JournalMergeService:
/// ```dart
/// final journalMergerProvider = Provider<JournalMerger?>((ref) {
///   return JournalMergeService(); // implements JournalMerger
/// });
/// ```
final journalMergerProvider = Provider<JournalMerger?>((ref) {
  return null; // Default: no journal merge support
});

/// Notifier for sync state
class SyncNotifier extends StateNotifier<SyncState> {
  final Ref _ref;
  final SyncService _syncService = SyncService();

  Timer? _debouncedPushTimer;
  Timer? _statusResetTimer;

  /// Completer to track initialization status
  Completer<void>? _initCompleter;

  /// Debounce duration for push operations
  static const _pushDebounce = Duration(seconds: 3);

  /// Track last sync time for incremental pulls (Unix timestamp)
  double _lastSyncTimestamp = 0;

  /// Files pending push (accumulated during debounce)
  final Set<String> _pendingPushFiles = {};

  SyncNotifier(this._ref) : super(const SyncState()) {
    _initCompleter = Completer<void>();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      // Check if sync is disabled (Parachute Computer mode - app and server share filesystem)
      final syncDisabled = _ref.read(syncDisabledProvider);
      if (syncDisabled) {
        debugPrint('[SyncNotifier] Sync disabled - app and server share the same vault');
        return;
      }

      // Wire up journal merger if available
      final journalMerger = _ref.read(journalMergerProvider);
      if (journalMerger != null) {
        _syncService.setJournalMerger(journalMerger);
      }

      // Watch for server URL changes and reinitialize
      final serverUrl = await _ref.read(serverUrlProvider.future);
      final apiKey = await _ref.read(apiKeyProvider.future);

      if (serverUrl != null && serverUrl.isNotEmpty) {
        await _syncService.initialize(serverUrl: serverUrl, apiKey: apiKey);
        debugPrint('[SyncNotifier] Initialized with server: $serverUrl');

        _lastSyncTimestamp = DateTime.now().millisecondsSinceEpoch / 1000.0;
      } else {
        debugPrint('[SyncNotifier] No server URL configured, sync disabled');
      }
    } finally {
      _initCompleter?.complete();
    }
  }

  /// Wait for initialization to complete
  Future<void> get initialized => _initCompleter?.future ?? Future.value();

  @override
  void dispose() {
    _debouncedPushTimer?.cancel();
    _statusResetTimer?.cancel();
    super.dispose();
  }

  /// Check if sync is disabled (Parachute Computer mode)
  bool get _isSyncDisabled => _ref.read(syncDisabledProvider);

  /// Schedule a file to be pushed to server (debounced)
  void schedulePush(String relativePath) {
    if (_isSyncDisabled) return;
    debugPrint('[SyncNotifier] schedulePush($relativePath)');
    _pendingPushFiles.add(relativePath);
    _schedulePushDebounced();
  }

  /// Schedule multiple files to be pushed
  void schedulePushFiles(List<String> relativePaths) {
    if (_isSyncDisabled) return;
    if (relativePaths.isEmpty) return;
    debugPrint('[SyncNotifier] schedulePushFiles(${relativePaths.length} files)');
    _pendingPushFiles.addAll(relativePaths);
    _schedulePushDebounced();
  }

  void _schedulePushDebounced() {
    _debouncedPushTimer?.cancel();
    _debouncedPushTimer = Timer(_pushDebounce, () {
      _doPendingPush();
    });
  }

  Future<void> _doPendingPush() async {
    if (_pendingPushFiles.isEmpty) return;
    await initialized;

    if (!_syncService.isReady) {
      debugPrint('[SyncNotifier] Skipping push - service not ready');
      return;
    }

    final filesToPush = List<String>.from(_pendingPushFiles);
    _pendingPushFiles.clear();

    debugPrint('[SyncNotifier] Pushing ${filesToPush.length} files...');
    state = state.copyWith(status: SyncStatus.syncing);

    try {
      final pushed = await _syncService.pushFiles('Daily', filesToPush);
      debugPrint('[SyncNotifier] Pushed $pushed files');
      state = state.copyWith(status: SyncStatus.idle);
    } catch (e) {
      debugPrint('[SyncNotifier] Push error: $e');
      state = state.copyWith(status: SyncStatus.error, errorMessage: e.toString());
    }
  }

  /// Pull changes from server for a specific date (user-triggered refresh)
  Future<SyncResult> pullDate(DateTime date) async {
    await initialized;

    if (!_syncService.isReady) {
      return SyncResult.error('Sync service not ready');
    }

    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    debugPrint('[SyncNotifier] pullDate($dateStr) - user-triggered refresh');

    state = state.copyWith(status: SyncStatus.syncing);

    try {
      final result = await syncDate(date);
      _lastSyncTimestamp = DateTime.now().millisecondsSinceEpoch / 1000.0;

      state = state.copyWith(
        status: SyncStatus.idle,
        lastResult: result,
        lastSyncTime: DateTime.now(),
      );

      return result;
    } catch (e) {
      state = state.copyWith(status: SyncStatus.error, errorMessage: e.toString());
      return SyncResult.error(e.toString());
    }
  }

  /// Pull all changes from server since last sync
  Future<SyncResult> pullChanges() async {
    await initialized;

    if (!_syncService.isReady) {
      return SyncResult.error('Sync service not ready');
    }

    debugPrint('[SyncNotifier] pullChanges() since $_lastSyncTimestamp');
    state = state.copyWith(status: SyncStatus.syncing);

    try {
      final changedPaths = await _syncService.getServerChanges(
        'Daily',
        sinceTimestamp: _lastSyncTimestamp,
        pattern: '*',
        includeBinary: false,
      );

      if (changedPaths == null) {
        state = state.copyWith(status: SyncStatus.error, errorMessage: 'Failed to get changes');
        return SyncResult.error('Failed to get server changes');
      }

      if (changedPaths.isEmpty) {
        debugPrint('[SyncNotifier] No changes on server since last sync');
        state = state.copyWith(status: SyncStatus.idle);
        return SyncResult(success: true, pulled: 0, pushed: 0, merged: 0, conflicts: const []);
      }

      final pulled = await _syncService.pullFiles('Daily', changedPaths);
      _lastSyncTimestamp = DateTime.now().millisecondsSinceEpoch / 1000.0;

      debugPrint('[SyncNotifier] Pulled $pulled changed files');

      final result = SyncResult(
        success: true,
        pulled: pulled,
        pushed: 0,
        merged: 0,
        conflicts: const [],
      );

      state = state.copyWith(
        status: SyncStatus.idle,
        lastResult: result,
        lastSyncTime: DateTime.now(),
        pullCounter: pulled > 0 ? state.pullCounter + 1 : state.pullCounter,
      );

      return result;
    } catch (e) {
      state = state.copyWith(status: SyncStatus.error, errorMessage: e.toString());
      return SyncResult.error(e.toString());
    }
  }

  /// Pull a specific file from server
  Future<bool> pullFile(String relativePath) async {
    await initialized;

    if (!_syncService.isReady) {
      debugPrint('[SyncNotifier] Sync service not ready for pullFile');
      return false;
    }

    debugPrint('[SyncNotifier] pullFile($relativePath)');

    try {
      final pulled = await _syncService.pullFiles('Daily', [relativePath]);
      if (pulled > 0) {
        state = state.copyWith(
          pullCounter: state.pullCounter + 1,
        );
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[SyncNotifier] Error in pullFile: $e');
      return false;
    }
  }

  /// Schedule a debounced sync
  void scheduleSync() {
    debugPrint('[SyncNotifier] scheduleSync() called - scheduling push only');
    _schedulePushDebounced();
  }

  /// Schedule sync for a specific date
  void scheduleSyncForDate(DateTime date) {
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    debugPrint('[SyncNotifier] scheduleSyncForDate($dateStr) - scheduling push');
    _schedulePushDebounced();
  }

  /// Reinitialize with new server URL
  Future<void> reinitialize(String serverUrl, {String? apiKey}) async {
    await _syncService.initialize(serverUrl: serverUrl, apiKey: apiKey);
    state = const SyncState();
    _lastSyncTimestamp = DateTime.now().millisecondsSinceEpoch / 1000.0;
  }

  /// Trigger a sync
  Future<SyncResult> sync({String pattern = '*'}) async {
    if (state.isSyncing) {
      return SyncResult.error('Sync already in progress');
    }

    if (!_syncService.isReady) {
      final serverUrl = await _ref.read(serverUrlProvider.future);
      final apiKey = await _ref.read(apiKeyProvider.future);
      if (serverUrl != null && serverUrl.isNotEmpty) {
        await _syncService.initialize(serverUrl: serverUrl, apiKey: apiKey);
      } else {
        state = state.copyWith(status: SyncStatus.error, errorMessage: 'No server configured');
        return SyncResult.error('No server configured');
      }
    }

    final syncMode = await _ref.read(syncModeProvider.future);
    final includeBinary = syncMode == SyncMode.full;

    state = state.copyWith(status: SyncStatus.syncing, errorMessage: null, clearProgress: true);

    try {
      final result = await _syncService.sync(
        pattern: pattern,
        includeBinary: includeBinary,
        onProgress: (progress) {
          state = state.copyWith(progress: progress);
        },
      );

      final newPullCounter = (result.pulled > 0 || result.merged > 0)
          ? state.pullCounter + 1
          : state.pullCounter;

      final newConflicts = [...state.unresolvedConflicts];
      for (final conflict in result.conflicts) {
        if (!newConflicts.contains(conflict)) {
          newConflicts.add(conflict);
        }
      }

      state = state.copyWith(
        status: result.success ? SyncStatus.success : SyncStatus.error,
        lastResult: result,
        lastSyncTime: DateTime.now(),
        errorMessage: result.success ? null : result.errors.join(', '),
        pullCounter: newPullCounter,
        unresolvedConflicts: newConflicts,
        clearProgress: true,
      );

      if (result.pulled > 0 || result.merged > 0) {
        debugPrint('[SyncNotifier] Pulled ${result.pulled} files, merged ${result.merged}, pullCounter=$newPullCounter');
      }
      if (result.conflicts.isNotEmpty) {
        debugPrint('[SyncNotifier] New conflicts: ${result.conflicts}');
      }

      _statusResetTimer?.cancel();
      _statusResetTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && state.status == SyncStatus.success) {
          state = state.copyWith(status: SyncStatus.idle);
        }
      });

      return result;
    } catch (e) {
      state = state.copyWith(status: SyncStatus.error, errorMessage: e.toString(), clearProgress: true);
      return SyncResult.error(e.toString());
    }
  }

  /// Trigger a date-scoped sync for a specific day.
  Future<SyncResult> syncDate(DateTime date) async {
    if (state.isSyncing) {
      return SyncResult.error('Sync already in progress');
    }

    if (!_syncService.isReady) {
      final serverUrl = await _ref.read(serverUrlProvider.future);
      final apiKey = await _ref.read(apiKeyProvider.future);
      if (serverUrl != null && serverUrl.isNotEmpty) {
        await _syncService.initialize(serverUrl: serverUrl, apiKey: apiKey);
      } else {
        state = state.copyWith(status: SyncStatus.error, errorMessage: 'No server configured');
        return SyncResult.error('No server configured');
      }
    }

    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final syncMode = await _ref.read(syncModeProvider.future);
    final includeBinary = syncMode == SyncMode.full;

    state = state.copyWith(status: SyncStatus.syncing, errorMessage: null, clearProgress: true);

    try {
      final result = await _syncService.syncDate(
        date: dateStr,
        includeBinary: includeBinary,
        onProgress: (progress) {
          state = state.copyWith(progress: progress);
        },
      );

      final newPullCounter = (result.pulled > 0 || result.merged > 0)
          ? state.pullCounter + 1
          : state.pullCounter;

      final newConflicts = [...state.unresolvedConflicts];
      for (final conflict in result.conflicts) {
        if (!newConflicts.contains(conflict)) {
          newConflicts.add(conflict);
        }
      }

      state = state.copyWith(
        status: result.success ? SyncStatus.success : SyncStatus.error,
        lastResult: result,
        lastSyncTime: DateTime.now(),
        errorMessage: result.success ? null : result.errors.join(', '),
        pullCounter: newPullCounter,
        unresolvedConflicts: newConflicts,
        clearProgress: true,
      );

      debugPrint('[SyncNotifier] Date-scoped sync for $dateStr: pushed=${result.pushed}, pulled=${result.pulled}, merged=${result.merged}');

      _statusResetTimer?.cancel();
      _statusResetTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && state.status == SyncStatus.success) {
          state = state.copyWith(status: SyncStatus.idle);
        }
      });

      return result;
    } catch (e) {
      state = state.copyWith(status: SyncStatus.error, errorMessage: e.toString(), clearProgress: true);
      return SyncResult.error(e.toString());
    }
  }

  /// Called when app goes to foreground
  Future<void> onAppResumed() async {
    debugPrint('[SyncNotifier] App resumed - no automatic sync (push-on-change model)');
  }

  /// Called when app goes to background
  Future<void> onAppPaused() async {
    if (_pendingPushFiles.isNotEmpty) {
      debugPrint('[SyncNotifier] App paused with ${_pendingPushFiles.length} pending files - flushing');
      _debouncedPushTimer?.cancel();
      await _doPendingPush();
    } else {
      debugPrint('[SyncNotifier] App paused - no pending changes');
    }
  }

  /// Check if server is reachable
  Future<bool> checkConnection() async {
    return _syncService.isServerReachable();
  }
}

/// Provider for sync state
final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  return SyncNotifier(ref);
});

/// Provider for checking if sync is available
final syncAvailableProvider = Provider<bool>((ref) {
  final syncDisabled = ref.watch(syncDisabledProvider);
  if (syncDisabled) return false;

  final serverUrl = ref.watch(serverUrlProvider);
  return serverUrl.when(
    data: (url) => url != null && url.isNotEmpty,
    loading: () => false,
    error: (_, __) => false,
  );
});

/// Provider that exposes the pull counter
final syncPullCounterProvider = Provider<int>((ref) {
  return ref.watch(syncProvider.select((state) => state.pullCounter));
});

/// Widget that observes app lifecycle and triggers sync
class SyncLifecycleObserver extends StatefulWidget {
  final Widget child;
  final WidgetRef ref;

  const SyncLifecycleObserver({
    super.key,
    required this.child,
    required this.ref,
  });

  @override
  State<SyncLifecycleObserver> createState() => _SyncLifecycleObserverState();
}

class _SyncLifecycleObserverState extends State<SyncLifecycleObserver>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final syncNotifier = widget.ref.read(syncProvider.notifier);
    final syncAvailable = widget.ref.read(syncAvailableProvider);

    if (!syncAvailable) return;

    switch (state) {
      case AppLifecycleState.resumed:
        syncNotifier.onAppResumed();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        syncNotifier.onAppPaused();
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
