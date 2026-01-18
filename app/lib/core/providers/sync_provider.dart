import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/sync_service.dart';
import '../../features/daily/journal/services/journal_merge_service.dart';
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

/// Notifier for sync state
class SyncNotifier extends StateNotifier<SyncState> {
  final Ref _ref;
  final SyncService _syncService = SyncService();
  final JournalMergeService _journalMergeService = JournalMergeService();

  Timer? _periodicSyncTimer;
  Timer? _debouncedSyncTimer;
  Timer? _statusResetTimer;

  /// Completer to track initialization status
  Completer<void>? _initCompleter;

  /// Debounce duration for change-triggered syncs
  static const _syncDebounce = Duration(seconds: 5);

  /// Interval for periodic sync checks
  static const _periodicSyncInterval = Duration(minutes: 5);

  SyncNotifier(this._ref) : super(const SyncState()) {
    _initCompleter = Completer<void>();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      // Wire up journal merge service for entry-level merging
      _syncService.setJournalMergeService(_journalMergeService);

      // Watch for server URL changes and reinitialize
      final serverUrl = await _ref.read(serverUrlProvider.future);
      final apiKey = await _ref.read(apiKeyProvider.future);

      if (serverUrl != null && serverUrl.isNotEmpty) {
        await _syncService.initialize(serverUrl: serverUrl, apiKey: apiKey);
        debugPrint('[SyncNotifier] Initialized with server: $serverUrl');

        // Start periodic sync
        _startPeriodicSync();

        // Do an initial sync
        _scheduleSync();
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
    _periodicSyncTimer?.cancel();
    _debouncedSyncTimer?.cancel();
    _statusResetTimer?.cancel();
    super.dispose();
  }

  /// Start periodic sync timer
  void _startPeriodicSync() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(_periodicSyncInterval, (_) {
      debugPrint('[SyncNotifier] Periodic sync triggered');
      _doSyncIfIdle();
    });
  }

  /// Schedule a debounced sync (for after local changes)
  void scheduleSync() {
    debugPrint('[SyncNotifier] scheduleSync() called');
    _scheduleSync();
  }

  void _scheduleSync() {
    debugPrint('[SyncNotifier] _scheduleSync() - cancelling existing timer and setting new one');
    _debouncedSyncTimer?.cancel();
    _debouncedSyncTimer = Timer(_syncDebounce, () {
      debugPrint('[SyncNotifier] Debounced sync triggered after ${_syncDebounce.inSeconds}s');
      _doSyncIfIdle();
    });
  }

  /// Do sync only if not already syncing
  Future<void> _doSyncIfIdle() async {
    // Wait for initialization to complete first
    await initialized;

    debugPrint('[SyncNotifier] _doSyncIfIdle() called, isSyncing=${state.isSyncing}, isReady=${_syncService.isReady}');
    if (state.isSyncing) {
      debugPrint('[SyncNotifier] Skipping sync - already in progress');
      return;
    }
    if (!_syncService.isReady) {
      debugPrint('[SyncNotifier] Skipping sync - service not ready (no server configured?)');
      return;
    }
    debugPrint('[SyncNotifier] Starting sync...');
    final result = await sync(pattern: '*');
    debugPrint('[SyncNotifier] Sync complete: $result');
  }

  /// Reinitialize with new server URL
  Future<void> reinitialize(String serverUrl, {String? apiKey}) async {
    await _syncService.initialize(serverUrl: serverUrl, apiKey: apiKey);
    state = const SyncState(); // Reset state
    _startPeriodicSync();
  }

  /// Trigger a sync
  ///
  /// [pattern] defaults to "*" for full sync. Use "*.md" for markdown only.
  Future<SyncResult> sync({String pattern = '*'}) async {
    if (state.isSyncing) {
      return SyncResult.error('Sync already in progress');
    }

    if (!_syncService.isReady) {
      // Try to reinitialize
      final serverUrl = await _ref.read(serverUrlProvider.future);
      final apiKey = await _ref.read(apiKeyProvider.future);
      if (serverUrl != null && serverUrl.isNotEmpty) {
        await _syncService.initialize(serverUrl: serverUrl, apiKey: apiKey);
      } else {
        state = state.copyWith(
          status: SyncStatus.error,
          errorMessage: 'No server configured',
        );
        return SyncResult.error('No server configured');
      }
    }

    // Check sync mode setting
    final syncMode = await _ref.read(syncModeProvider.future);
    final includeBinary = syncMode == SyncMode.full;

    state = state.copyWith(status: SyncStatus.syncing, errorMessage: null, clearProgress: true);

    try {
      final result = await _syncService.sync(
        pattern: pattern,
        includeBinary: includeBinary,
        onProgress: (progress) {
          // Update state with progress
          state = state.copyWith(progress: progress);
        },
      );

      // Increment pull counter if files were pulled or merged (signals UI to refresh)
      final newPullCounter = (result.pulled > 0 || result.merged > 0)
          ? state.pullCounter + 1
          : state.pullCounter;

      // Track any new conflicts (add to existing, don't replace)
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

      // Reset to idle after a short delay (use tracked timer for proper cleanup)
      _statusResetTimer?.cancel();
      _statusResetTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && state.status == SyncStatus.success) {
          state = state.copyWith(status: SyncStatus.idle);
        }
      });

      return result;
    } catch (e) {
      state = state.copyWith(
        status: SyncStatus.error,
        errorMessage: e.toString(),
        clearProgress: true,
      );
      return SyncResult.error(e.toString());
    }
  }

  /// Called when app goes to foreground - pull latest
  Future<void> onAppResumed() async {
    debugPrint('[SyncNotifier] App resumed - syncing');
    await _doSyncIfIdle();
  }

  /// Called when app goes to background - push latest
  Future<void> onAppPaused() async {
    debugPrint('[SyncNotifier] App paused - syncing');
    // Cancel any debounced sync and do it now
    _debouncedSyncTimer?.cancel();
    await _doSyncIfIdle();
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

/// Provider for checking if sync is available (server configured)
final syncAvailableProvider = Provider<bool>((ref) {
  final serverUrl = ref.watch(serverUrlProvider);
  return serverUrl.when(
    data: (url) => url != null && url.isNotEmpty,
    loading: () => false,
    error: (_, __) => false,
  );
});

/// Provider that exposes the pull counter - watch this to refresh UI after pulls
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
