import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:parachute/core/config/app_config.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/backend_health_provider.dart' show serverTranscriptionAvailableProvider;
import 'package:parachute/core/providers/app_state_provider.dart' show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart' show aiServerUrlProvider;
import 'package:parachute/core/providers/sync_provider.dart';
import 'package:parachute/core/providers/connectivity_provider.dart' show isServerAvailableProvider;
import 'package:parachute/core/services/tag_service.dart' show TagInfo, tagServiceProvider;
import '../../recorder/providers/service_providers.dart';
import '../models/entry_metadata.dart' show TranscriptionStatus;
import '../models/journal_day.dart';
import '../models/journal_entry.dart';
import '../providers/journal_providers.dart';
import '../providers/journal_screen_state_provider.dart';
import '../widgets/journal_header.dart';
import '../widgets/journal_content_view.dart';
import '../widgets/journal_empty_state.dart';
import '../widgets/journal_input_bar.dart';
import '../widgets/mini_audio_player.dart';
import '../widgets/pending_sync_banner.dart';
import 'entry_detail_screen.dart';
import '../../recorder/widgets/playback_controls.dart';
import '../utils/journal_helpers.dart';

/// Main journal screen showing today's journal entries
///
/// The daily journal is the home for captures - voice notes, typed thoughts,
/// and links to longer recordings.
class JournalScreen extends ConsumerStatefulWidget {
  const JournalScreen({super.key});

  @override
  ConsumerState<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends ConsumerState<JournalScreen> with WidgetsBindingObserver {
  final ScrollController _scrollController = ScrollController();

  // Guard to prevent multiple rapid audio plays
  bool _isPlayingAudio = false;

  // Flag to scroll to bottom after new entry is added
  bool _shouldScrollToBottom = false;

  // Audio playback state
  String? _currentlyPlayingAudioPath;
  String? _currentlyPlayingTitle;

  // Server transcription polling
  final Set<String> _pollingEntryIds = {};
  final Map<String, Timer> _pollingTimeouts = {};
  Timer? _transcriptionPollTimer;
  static const _pollInterval = Duration(seconds: 5);
  static const _pollTimeout = Duration(minutes: 5);

  // Local journal cache to avoid loading flash on updates
  JournalDay? _cachedJournal;
  DateTime? _cachedJournalDate;

  // Track last known pull counter to detect changes
  int? _lastPullCounter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _transcriptionPollTimer?.cancel();
    for (final timer in _pollingTimeouts.values) {
      timer.cancel();
    }
    _pollingTimeouts.clear();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
  }

  @override
  Widget build(BuildContext context) {
    // Watch the selected date and its journal
    final selectedDate = ref.watch(selectedJournalDateProvider);
    final journalAsync = ref.watch(selectedJournalProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Check if sync pulled new files - refresh providers if so
    _handleSyncPullChanges(selectedDate);

    // Check if viewing today
    final isToday = _isToday(selectedDate);

    // Clear cache if date changed
    _updateCacheIfNeeded(selectedDate);

    // Update the cached journal via ref.listen rather than mutating inside build().
    // ref.listen fires after the current build completes, so setState here is safe
    // and won't cause a mid-build mutation.
    ref.listen<AsyncValue<JournalDay>>(selectedJournalProvider, (_, next) {
      next.whenData((journal) {
        if (mounted) {
          setState(() {
            _cachedJournal = journal;
            _cachedJournalDate = ref.read(selectedJournalDateProvider);
          });
          // Restart polling for any entries still being server-transcribed
          _restartPollingForInFlightEntries();
        }
      });
    });

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            JournalHeader(
              selectedDate: selectedDate,
              isToday: isToday,
              journalAsync: journalAsync,
              onRefresh: _refreshJournal,
            ),

            // Pending sync banner
            PendingSyncBanner(
              onRetry: _retryPendingSync,
            ),

            // Journal entries - use cached data during loading to avoid flash
            Expanded(
              child: journalAsync.when(
                data: (journal) => _buildJournalContent(context, journal, selectedDate, isToday),
                loading: () {
                  // Use cached journal if available to avoid loading flash
                  if (_cachedJournal != null) {
                    return _buildJournalContent(context, _cachedJournal!, selectedDate, isToday);
                  }
                  return const Center(child: CircularProgressIndicator());
                },
                error: (error, stack) => JournalErrorState(
                  error: error,
                  onRetry: _refreshJournal,
                ),
              ),
            ),

            // Mini audio player (shows when playing)
            MiniAudioPlayer(
              currentAudioPath: _currentlyPlayingAudioPath,
              entryTitle: _currentlyPlayingTitle,
              onStop: () {
                setState(() {
                  _currentlyPlayingAudioPath = null;
                  _currentlyPlayingTitle = null;
                });
              },
            ),

            // Input bar at bottom (only show for today)
            if (isToday)
              JournalInputBar(
                onTextSubmitted: (text) => _addTextEntry(text),
                onVoiceRecorded: (transcript, audioPath, duration) =>
                    _addVoiceEntry(transcript, audioPath, duration),
                onTranscriptReady: (transcript) => _updatePendingTranscription(transcript),
                onComposeSubmitted: (title, content) =>
                    _addComposeEntry(title, content),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildJournalContent(
    BuildContext context,
    JournalDay journal,
    DateTime selectedDate,
    bool isToday,
  ) {
    // Handle scroll to bottom after new entry is added
    if (_shouldScrollToBottom) {
      _shouldScrollToBottom = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }

    if (journal.entries.isEmpty) {
      // Wrap empty state in RefreshIndicator with scrollable child
      // so pull-to-refresh works even when there are no entries
      return RefreshIndicator(
        onRefresh: _refreshJournal,
        color: BrandColors.forest,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: JournalEmptyState(isToday: isToday),
            ),
          ),
        ),
      );
    }

    return JournalContentView(
      journal: journal,
      selectedDate: selectedDate,
      isToday: isToday,
      scrollController: _scrollController,
      onRefresh: _refreshJournal,
      onEntryTap: _handleEntryTap,
      onShowEntryActions: _showEntryActions,
      onPlayAudio: _playAudio,
      onTranscribe: _handleTranscribe,
      onEnhance: _handleEnhance,
    );
  }

  // ========== Date and Cache Management ==========

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  void _updateCacheIfNeeded(DateTime selectedDate) {
    if (_cachedJournalDate != null &&
        (_cachedJournalDate!.year != selectedDate.year ||
            _cachedJournalDate!.month != selectedDate.month ||
            _cachedJournalDate!.day != selectedDate.day)) {
      _cachedJournal = null;
      _cachedJournalDate = null;
    }
  }

  void _handleSyncPullChanges(DateTime selectedDate) {
    final pullCounter = ref.watch(syncPullCounterProvider);
    if (_lastPullCounter != null && pullCounter > _lastPullCounter!) {
      debugPrint('[JournalScreen] Sync pulled files, refreshing providers...');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.invalidate(selectedJournalProvider);
          ref.read(journalRefreshTriggerProvider.notifier).state++;
        }
      });
    }
    _lastPullCounter = pullCounter;
  }

  // ========== Refresh and Scroll ==========

  Future<void> _refreshJournal() async {
    ref.invalidate(selectedJournalProvider);
    ref.read(journalRefreshTriggerProvider.notifier).state++;
    debugPrint('[JournalScreen] Refreshing - providers invalidated, will re-fetch from API');
  }

  /// Retry pending sync manually — user tapped the "Retry" button in the banner.
  ///
  /// Delegates to _refreshJournal which triggers _loadJournal in the notifier,
  /// which already handles flushing pending queue + pending ops when online.
  Future<void> _retryPendingSync() async {
    // Gate on connectivity — don't attempt sync if offline
    final isAvailable = ref.read(isServerAvailableProvider);
    if (!isAvailable) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Server unavailable — entries will sync when online'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    debugPrint('[JournalScreen] User triggered pending sync retry');
    try {
      // Refresh triggers _loadJournal which flushes pending ops + fetches from server
      await _refreshJournal();

      // Update pending count after flush
      ref.invalidate(pendingSyncCountProvider);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sync completed'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[JournalScreen] Error retrying sync: $e');
      ref.invalidate(pendingSyncCountProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  String _formatDateStr(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  // ========== Error Feedback ==========

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

  // ========== Entry CRUD Operations ==========

  /// Adds an entry to the local cache for immediate display.
  ///
  /// If [entry] is null the write failed — fall back to adding a pending entry.
  Future<void> _appendEntryToCache(JournalEntry? entry, {
    required String content,
    JournalEntryType type = JournalEntryType.text,
    String? audioPath,
    String? imagePath,
    int? durationSeconds,
  }) async {
    if (entry != null) {
      final date = ref.read(selectedJournalDateProvider);
      setState(() {
        _cachedJournal = (_cachedJournal ?? JournalDay.empty(date)).addEntry(entry);
        _shouldScrollToBottom = true;
      });
      // Write to SQLite cache immediately so Phase 1 of the next provider load
      // includes this entry — prevents the new entry flashing away when the
      // cache-first read fires before the server fetch completes.
      final cache = await ref.read(journalLocalCacheProvider.future);
      final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final existing = cache.getEntries(dateStr);
      if (!existing.any((e) => e.id == entry.id)) {
        cache.putEntries(dateStr, [...existing, entry]);
      }
    } else {
      // Offline — queue for later upload and show as pending
      final queue = await ref.read(pendingQueueProvider.future);
      final localId = 'pending-${DateTime.now().millisecondsSinceEpoch}';
      final pending = await queue.enqueue(
        localId: localId,
        content: content,
        type: _entryTypeString(type),
        audioPath: audioPath,
        imagePath: imagePath,
        durationSeconds: durationSeconds,
      );
      if (!mounted) return;
      setState(() {
        final date = ref.read(selectedJournalDateProvider);
        _cachedJournal = (_cachedJournal ?? JournalDay.empty(date)).addEntry(pending);
        _shouldScrollToBottom = true;
      });
    }
    if (!mounted) return;
    ref.invalidate(selectedJournalProvider);
    ref.read(journalRefreshTriggerProvider.notifier).state++;
  }

  static String _entryTypeString(JournalEntryType type) {
    switch (type) {
      case JournalEntryType.voice: return 'voice';
      case JournalEntryType.photo: return 'photo';
      case JournalEntryType.handwriting: return 'handwriting';
      case JournalEntryType.linked: return 'linked';
      default: return 'text';
    }
  }

  Future<void> _addTextEntry(String text) async {
    await _addEntryWithSafeQueue(content: text);
  }

  Future<void> _addComposeEntry(String title, String content) async {
    final fullContent = title.isNotEmpty ? '# $title\n\n$content' : content;
    await _addEntryWithSafeQueue(content: fullContent);
  }

  /// Create an entry with guaranteed data preservation.
  ///
  /// Saves to the pending queue FIRST so content is never lost, then
  /// attempts the server POST. On success, removes from queue and
  /// replaces the pending entry with the server's authoritative version.
  Future<void> _addEntryWithSafeQueue({
    required String content,
    JournalEntryType type = JournalEntryType.text,
    String? audioPath,
    String? imagePath,
    int? durationSeconds,
  }) async {
    // Step 1: Always save to pending queue first — content is now safe
    final queue = await ref.read(pendingQueueProvider.future);
    final localId = 'pending-${DateTime.now().millisecondsSinceEpoch}';
    final pending = await queue.enqueue(
      localId: localId,
      content: content,
      type: _entryTypeString(type),
      audioPath: audioPath,
      imagePath: imagePath,
      durationSeconds: durationSeconds,
    );
    if (!mounted) return;

    // Show immediately in UI as pending
    final date = ref.read(selectedJournalDateProvider);
    setState(() {
      _cachedJournal = (_cachedJournal ?? JournalDay.empty(date)).addEntry(pending);
      _shouldScrollToBottom = true;
    });

    // Step 2: Try server POST (only if online)
    final isAvailable = ref.read(isServerAvailableProvider);
    if (!isAvailable) {
      debugPrint('[JournalScreen] Offline — entry safe in queue ($localId)');
      if (!mounted) return;
      ref.invalidate(selectedJournalProvider);
      ref.read(journalRefreshTriggerProvider.notifier).state++;
      return;
    }

    debugPrint('[JournalScreen] Posting entry to server...');
    final api = ref.read(dailyApiServiceProvider);
    final entry = await api.createEntry(
      content: content,
      metadata: {
        if (type != JournalEntryType.text) 'type': _entryTypeString(type),
        if (audioPath != null) 'audio_path': audioPath,
        if (imagePath != null) 'image_path': imagePath,
        if (durationSeconds != null) 'duration_seconds': durationSeconds,
      },
    );

    if (entry != null) {
      // Success — remove from pending queue and replace with server entry
      await queue.remove(localId);
      if (!mounted) return;

      // Write server entry to local cache
      final cache = await ref.read(journalLocalCacheProvider.future);
      final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final existing = cache.getEntries(dateStr);
      if (!existing.any((e) => e.id == entry.id)) {
        cache.putEntries(dateStr, [...existing, entry]);
      }

      // Replace pending entry in UI with server version
      setState(() {
        _cachedJournal = _cachedJournal
            ?.removeEntry(localId)
            .addEntry(entry);
      });
      debugPrint('[JournalScreen] Entry created: ${entry.id}');
    } else {
      debugPrint('[JournalScreen] Server POST failed — entry safe in queue ($localId)');
    }

    if (!mounted) return;
    ref.invalidate(selectedJournalProvider);
    ref.read(journalRefreshTriggerProvider.notifier).state++;
  }

  Future<void> _addVoiceEntry(String transcript, String localAudioPath, int duration) async {
    debugPrint('[JournalScreen] Adding voice entry via API...');

    // Read mode once and decide whether to use server-side transcription
    final mode = await ref.read(transcriptionModeProvider.future);
    if (!mounted) return;

    final useServer = switch (mode) {
      TranscriptionMode.local => false,
      TranscriptionMode.server => true,
      TranscriptionMode.auto => ref.read(serverTranscriptionAvailableProvider),
    };

    if (useServer) {
      final success = await _addVoiceEntryViaServer(localAudioPath, duration);
      if (!mounted) return;
      if (success) return;

      // Server-only mode: don't fall back, show error
      if (mode == TranscriptionMode.server) {
        _showErrorSnackbar('Server transcription unavailable');
        // Still save the entry locally so the recording isn't lost
        await _appendEntryToCache(
          null,
          content: transcript,
          type: JournalEntryType.voice,
          audioPath: localAudioPath,
          durationSeconds: duration,
        );
        return;
      }
      debugPrint('[JournalScreen] Server upload failed, falling back to local');
    }

    await _addVoiceEntryLocally(transcript, localAudioPath, duration);
  }

  /// Upload audio to server for transcription + cleanup. Returns true on success.
  Future<bool> _addVoiceEntryViaServer(String localAudioPath, int duration) async {
    // Check connectivity — if offline, queue the voice entry instead
    final isAvailable = ref.read(isServerAvailableProvider);
    if (!isAvailable) {
      debugPrint('[JournalScreen] Offline: queueing voice entry...');
      final queue = await ref.read(pendingQueueProvider.future);
      final entry = await queue.enqueue(
        localId: _generateLocalId(),
        content: '', // Voice entries have no text content initially
        type: 'voice',
        audioPath: localAudioPath,
        durationSeconds: duration,
      );

      // Add to cache for immediate display
      await _appendEntryToCache(
        entry,
        content: '',
        type: JournalEntryType.voice,
        audioPath: localAudioPath,
        durationSeconds: duration,
      );

      // Don't delete the audio file yet — it's needed when the entry syncs
      return true;
    }

    debugPrint('[JournalScreen] Uploading voice entry to server for transcription...');
    final api = ref.read(dailyApiServiceProvider);

    final entry = await api.uploadVoiceEntry(
      audioFile: File(localAudioPath),
      durationSeconds: duration,
    );
    if (!mounted) return false;

    if (entry == null) {
      debugPrint('[JournalScreen] Server voice upload failed');
      return false;
    }

    // Cache the entry (with processing status — no text yet)
    await _appendEntryToCache(
      entry,
      content: '',
      type: JournalEntryType.voice,
      audioPath: entry.audioPath,
      durationSeconds: duration,
    );

    // Clean up local audio — server has its own copy
    try {
      await File(localAudioPath).delete();
    } catch (e) {
      debugPrint('[JournalScreen] Failed to delete staged audio: $e');
    }

    // Start polling for transcription completion
    _startPollingEntry(entry.id);

    return true;
  }

  /// Generate a unique local ID for pending entries
  String _generateLocalId() {
    return 'local_${DateTime.now().millisecondsSinceEpoch}_${DateTime.now().microsecond}';
  }

  /// Original local flow: upload audio asset, create entry, let on-device transcription handle it.
  Future<void> _addVoiceEntryLocally(String transcript, String localAudioPath, int duration) async {
    final api = ref.read(dailyApiServiceProvider);

    // Try to upload audio to server first
    final serverPath = await api.uploadAudio(File(localAudioPath));
    if (!mounted) return;

    if (serverPath != null) {
      // Online: create entry with server audio path
      final entry = await api.createEntry(
        content: transcript,
        metadata: {
          'type': 'voice',
          'audio_path': serverPath,
          'duration_seconds': duration,
          // Mark as processing if content is empty (post-hoc transcription pending)
          if (transcript.isEmpty) 'transcription_status': 'processing',
        },
      );
      if (!mounted) return;

      if (entry != null) {
        // Both upload and entry creation succeeded
        await _appendEntryToCache(
          entry,
          content: transcript,
          type: JournalEntryType.voice,
          audioPath: serverPath,
          durationSeconds: duration,
        );
        try {
          await File(localAudioPath).delete();
        } catch (e) {
          debugPrint('[JournalScreen] Failed to delete staged audio: $e');
        }
      } else {
        // Upload succeeded but entry creation failed — queue with server path so audio
        // is not re-uploaded, then clean up the local staged file.
        await _appendEntryToCache(
          null,
          content: transcript,
          type: JournalEntryType.voice,
          audioPath: serverPath,
          durationSeconds: duration,
        );
        try {
          await File(localAudioPath).delete();
        } catch (e) {
          debugPrint('[JournalScreen] Failed to delete staged audio: $e');
        }
      }
    } else {
      // Offline: queue with staged local path — PendingEntryQueue will upload on reconnect
      debugPrint('[JournalScreen] Offline — voice entry queued with staged audio');
      await _appendEntryToCache(
        null,
        content: transcript,
        type: JournalEntryType.voice,
        audioPath: localAudioPath,
        durationSeconds: duration,
      );
    }
  }

  // ========== Server Transcription Polling ==========

  /// Start polling for an entry's transcription to complete.
  void _startPollingEntry(String entryId) {
    // Guard: don't re-register if already being polled
    if (_pollingEntryIds.contains(entryId)) return;

    _pollingEntryIds.add(entryId);
    _transcriptionPollTimer ??= Timer.periodic(_pollInterval, (_) => _pollTranscriptions());

    // Set a cancellable timeout to stop polling this entry after _pollTimeout
    _pollingTimeouts[entryId] = Timer(_pollTimeout, () {
      _pollingTimeouts.remove(entryId);
      if (_pollingEntryIds.remove(entryId)) {
        debugPrint('[JournalScreen] Polling timeout for entry $entryId');
        _stopPollingIfEmpty();
      }
    });
  }

  /// Poll all in-flight entries for transcription completion.
  Future<void> _pollTranscriptions() async {
    if (_pollingEntryIds.isEmpty || !mounted) {
      _stopPollingIfEmpty();
      return;
    }

    final api = ref.read(dailyApiServiceProvider);

    for (final entryId in Set<String>.of(_pollingEntryIds)) {
      try {
        final updated = await api.getEntry(entryId);
        if (updated == null || !mounted) continue;

        // Update UI whenever content changes (raw text arrives, then
        // cleaned text replaces it a few seconds later).
        if (_cachedJournal != null) {
          final existing = _cachedJournal!.getEntry(entryId);
          if (existing != null && existing.content != updated.content) {
            setState(() {
              _cachedJournal = _cachedJournal!.updateEntry(updated);
            });
          }
        }

        // Stop polling once status reaches a terminal state (complete/failed)
        if (!updated.isServerProcessing) {
          _pollingEntryIds.remove(entryId);
          _pollingTimeouts.remove(entryId)?.cancel();
          debugPrint(
            '[JournalScreen] Entry $entryId transcription resolved: '
            '${updated.serverTranscriptionStatus}',
          );
        }
      } catch (e) {
        debugPrint('[JournalScreen] Poll error for entry $entryId: $e');
      }
    }

    _stopPollingIfEmpty();
  }

  void _stopPollingIfEmpty() {
    if (_pollingEntryIds.isEmpty) {
      _transcriptionPollTimer?.cancel();
      _transcriptionPollTimer = null;
    }
  }

  /// Restart polling for any in-flight entries in the current journal.
  /// Called when the journal data loads or refreshes.
  void _restartPollingForInFlightEntries() {
    final journal = _cachedJournal;
    if (journal == null) return;

    for (final entry in journal.entries) {
      if (entry.isServerProcessing) {
        _startPollingEntry(entry.id);
      }
    }
  }

  Future<void> _updatePendingTranscription(String transcript) async {
    final screenState = ref.read(journalScreenStateProvider);
    final entryId = screenState.pendingTranscriptionEntryId;

    if (entryId == null) {
      debugPrint('[JournalScreen] No pending entry to update');
      return;
    }

    ref.read(journalScreenStateProvider.notifier).setPendingTranscription(null);
    debugPrint('[JournalScreen] Updating entry $entryId with transcript...');

    try {
      final api = ref.read(dailyApiServiceProvider);
      final existingEntry = _cachedJournal?.getEntry(entryId);

      final serverUpdated = await api.updateEntry(entryId, content: transcript);
      if (serverUpdated == null) throw Exception('Server unreachable');
      debugPrint('[JournalScreen] Transcription update complete');

      JournalEntry? updatedEntry;
      if (existingEntry != null && _cachedJournal != null) {
        updatedEntry = existingEntry.copyWith(content: transcript);
        setState(() {
          _cachedJournal = _cachedJournal!.updateEntry(updatedEntry!);
        });
      }

      ref.invalidate(selectedJournalProvider);

      // Auto-enhance if enabled
      if (transcript.isNotEmpty) {
        final autoEnhance = await ref.read(autoEnhanceProvider.future);
        if (autoEnhance) {
          debugPrint('[JournalScreen] Auto-enhancing transcription...');
          await Future.delayed(const Duration(milliseconds: 100));
          if (mounted && updatedEntry != null) {
            _handleEnhance(updatedEntry);
          }
        }
      }
    } catch (e, st) {
      debugPrint('[JournalScreen] Error updating transcription: $e\n$st');
      _showErrorSnackbar('Voice note saved, but transcript update failed');
    }
  }

  // ========== Entry Actions ==========

  void _handleEntryTap(JournalEntry entry) {
    _showEntryDetail(context, entry);
  }

  // ========== Transcription and Enhancement ==========

  Future<void> _handleTranscribe(JournalEntry entry, JournalDay journal) async {
    final screenState = ref.read(journalScreenStateProvider);
    if (screenState.transcribingEntryIds.contains(entry.id)) return;

    final audioPath = journal.getAudioPath(entry.id);
    if (audioPath == null) {
      debugPrint('[JournalScreen] No audio path found for entry ${entry.id}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Audio file not found'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // Respect transcription mode setting — same pattern as _addVoiceEntry
    final mode = await ref.read(transcriptionModeProvider.future);
    if (!mounted) return;

    final useServer = switch (mode) {
      TranscriptionMode.local => false,
      TranscriptionMode.server => true,
      TranscriptionMode.auto => ref.read(serverTranscriptionAvailableProvider),
    };

    if (useServer) {
      await _retranscribeViaServer(entry, audioPath);
    } else {
      await _retranscribeLocally(entry, audioPath, mode);
    }
  }

  /// Re-transcribe via server: upload audio with replace_entry_id, let server pipeline handle it.
  Future<void> _retranscribeViaServer(JournalEntry entry, String audioPath) async {
    ref.read(journalScreenStateProvider.notifier).startTranscription(entry.id);
    debugPrint('[JournalScreen] Re-transcribing entry ${entry.id} via server');

    File? tempAudioFile;
    try {
      // Get the audio file — download from server if needed
      final audioFile = await _resolveAudioFile(audioPath, entry.id);
      if (audioFile == null) throw Exception('Audio file not available');
      if (audioFile.path != audioPath) tempAudioFile = audioFile;

      if (!mounted) return;
      final api = ref.read(dailyApiServiceProvider);

      final result = await api.uploadVoiceEntry(
        audioFile: audioFile,
        durationSeconds: entry.durationSeconds ?? 0,
        replaceEntryId: entry.id,
      );
      if (!mounted) return;

      if (result == null) {
        throw Exception('Server upload failed');
      }

      // Update local cache to show processing state
      final updatedEntry = entry.copyWith(
        content: '',
        serverTranscriptionStatus: TranscriptionStatus.processing,
      );
      if (_cachedJournal != null) {
        setState(() {
          _cachedJournal = _cachedJournal!.updateEntry(updatedEntry);
        });
      }

      // Start polling for transcription + cleanup completion
      _startPollingEntry(entry.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Re-transcribing on server...'),
            backgroundColor: BrandColors.turquoise,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    } catch (e) {
      debugPrint('[JournalScreen] Server re-transcribe failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Re-transcription failed: $e'),
            backgroundColor: BrandColors.error,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
ref.read(journalScreenStateProvider.notifier).completeTranscription(entry.id);
      }
      try { await tempAudioFile?.delete(); } catch (_) {}
    }
  }

  /// Re-transcribe locally via Parakeet, then trigger server cleanup.
  Future<void> _retranscribeLocally(JournalEntry entry, String audioPath, TranscriptionMode mode) async {
    ref.read(journalScreenStateProvider.notifier).startTranscription(entry.id);
    debugPrint('[JournalScreen] Re-transcribing entry ${entry.id} locally');

    File? tempAudioFile;
    try {
      // Get the audio file — download from server if needed
      final audioFile = await _resolveAudioFile(audioPath, entry.id);
      if (audioFile == null) throw Exception('Audio file not available');
      if (audioFile.path != audioPath) tempAudioFile = audioFile;

      if (!mounted) return;
      final postProcessingService = ref.read(recordingPostProcessingProvider);
      final result = await postProcessingService.process(
        audioPath: audioFile.path,
        onProgress: (status, progress) {
          if (mounted) {
            ref.read(journalScreenStateProvider.notifier).updateTranscriptionProgress(
                  entry.id,
                  progress,
                );
          }
        },
      );
      final transcript = result.transcript;

      debugPrint('[JournalScreen] Local transcription complete: ${transcript.length} chars');

      if (transcript.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No speech detected in recording'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (!mounted) return;
        final api = ref.read(dailyApiServiceProvider);
        final updatedEntry = entry.copyWith(content: transcript);
        final serverUpdated = await api.updateEntry(entry.id, content: transcript);
        if (serverUpdated == null) throw Exception('Server unreachable — transcript not saved');

        if (mounted && _cachedJournal != null) {
          setState(() {
            _cachedJournal = _cachedJournal!.updateEntry(updatedEntry);
          });
          ref.invalidate(selectedJournalProvider);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  const Text('Transcription complete'),
                ],
              ),
              backgroundColor: BrandColors.forest,
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          );
        }

        // After local transcription, trigger server-side cleanup
        if (mounted) {
          _handleEnhance(updatedEntry);
        }
      }
    } catch (e) {
      debugPrint('[JournalScreen] Local transcription failed: $e');
      if (mounted) {
        final msg = e is SocketException
            ? 'Cannot reach server to download audio'
            : 'Transcription failed: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: BrandColors.error,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        ref.read(journalScreenStateProvider.notifier).completeTranscription(entry.id);
      }
      try { await tempAudioFile?.delete(); } catch (_) {}
    }
  }

  /// Resolve an audio path to a local file, downloading from server if needed.
  Future<File?> _resolveAudioFile(String audioPath, String entryId) async {
    // Use local file if it exists (absolute path on same machine as server)
    if (audioPath.startsWith('/') && await File(audioPath).exists()) {
      return File(audioPath);
    }
    // Otherwise download from server to a temp file
    final serverBaseUrl = await ref.read(aiServerUrlProvider.future);
    final apiKey = await ref.read(apiKeyProvider.future);
    final audioUrl = JournalHelpers.getAudioUrl(audioPath, serverBaseUrl);
    final headers = <String, String>{
      if (apiKey != null && apiKey.isNotEmpty) 'X-API-Key': apiKey,
    };
    final response = await http
        .get(Uri.parse(audioUrl), headers: headers)
        .timeout(const Duration(minutes: 2),
            onTimeout: () => throw TimeoutException('Audio download timed out'));
    if (response.statusCode != 200) {
      throw Exception('Audio not available (HTTP ${response.statusCode})');
    }
    final tempDir = await getTemporaryDirectory();
    final ext = audioPath.contains('.') ? audioPath.split('.').last : 'wav';
    final tempFile = File('${tempDir.path}/transcribe_$entryId.$ext');
    await tempFile.writeAsBytes(response.bodyBytes);
    return tempFile;
  }

  Future<void> _handleEnhance(JournalEntry entry) async {
    if (entry.content.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No content to clean up'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final api = ref.read(dailyApiServiceProvider);
    final success = await api.cleanupEntry(entry.id);
    if (!mounted) return;

    if (success) {
      // Update local state to show cleanup in progress
      final updatedEntry = entry.copyWith(
        serverTranscriptionStatus: TranscriptionStatus.transcribed,
      );
      if (_cachedJournal != null) {
        setState(() {
          _cachedJournal = _cachedJournal!.updateEntry(updatedEntry);
        });
      }

      // Start polling for cleanup completion
      _startPollingEntry(entry.id);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cleaning up text...'),
          backgroundColor: BrandColors.turquoise,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Cleanup unavailable — check server connection'),
          backgroundColor: BrandColors.error,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // ========== Audio Playback ==========

  Future<void> _playAudio(String relativePath, {String? entryTitle}) async {
    if (_isPlayingAudio) {
      debugPrint('[JournalScreen] Audio play already in progress, ignoring');
      return;
    }

    _isPlayingAudio = true;
    debugPrint('[JournalScreen] Playing audio: $relativePath');

    try {
      final audioService = ref.read(audioServiceProvider);
      await audioService.initialize();

      final serverBaseUrl =
          ref.read(aiServerUrlProvider).valueOrNull ?? AppConfig.defaultServerUrl;
      final fullPath = JournalHelpers.getAudioUrl(relativePath, serverBaseUrl);
      debugPrint('[JournalScreen] Audio URL: $fullPath');

      if (!fullPath.startsWith('http://') && !fullPath.startsWith('https://')) {
        final file = File(fullPath);
        if (!await file.exists()) {
          debugPrint('[JournalScreen] ERROR: Audio file does not exist at: $fullPath');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Audio file not found'),
                    Text(
                      relativePath,
                      style: TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                  ],
                ),
                backgroundColor: BrandColors.error,
                duration: const Duration(seconds: 3),
              ),
            );
          }
          return;
        }

        final fileSize = await file.length();
        debugPrint('[JournalScreen] Audio file size: $fileSize bytes');

        if (fileSize == 0) {
          debugPrint('[JournalScreen] ERROR: Audio file is empty!');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Audio file is empty'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }
      }

      final success = await audioService.playRecording(fullPath);
      debugPrint('[JournalScreen] playRecording returned: $success');

      if (success) {
        setState(() {
          _currentlyPlayingAudioPath = fullPath;
          _currentlyPlayingTitle = entryTitle ?? 'Audio';
        });
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not play audio file'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('[JournalScreen] Error playing audio: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error playing audio: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      Future.delayed(const Duration(milliseconds: 500), () {
        _isPlayingAudio = false;
      });
    }
  }

  // ========== Entry Detail and Actions ==========

  Future<void> _showEntryDetail(BuildContext context, JournalEntry entry, {bool startInEditMode = false}) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Fetch tags from graph and system-wide tag list when online
    var displayEntry = entry;
    var allTags = <String>[];
    final isOnline = ref.read(isServerAvailableProvider);
    if (isOnline) {
      final tagService = ref.read(tagServiceProvider);
      try {
        final results = await Future.wait([
          tagService.getEntityTags('note', entry.id),
          tagService.listTags(),
        ]);
        final graphTags = results[0] as List<String>;
        final tagInfos = results[1] as List<TagInfo>;
        // Use graph tags as source of truth when online; keep metadata
        // tags if graph has no record yet (entry not yet migrated).
        if (graphTags.isNotEmpty) {
          displayEntry = entry.copyWith(tags: graphTags);
        }
        allTags = tagInfos.map((t) => t.tag).toList();
      } catch (_) {
        // Fall back to metadata tags on error
      }
    }

    if (!context.mounted) return;

    // All entry types use the unified detail screen
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EntryDetailScreen(
          entry: displayEntry,
          startInEditMode: startInEditMode,
          allTags: allTags,
          audioPlayer: entry.hasAudio ? _buildAudioPlayer(context, entry, isDark) : null,
          onSave: (updatedEntry) async {
            final api = ref.read(dailyApiServiceProvider);
            final metadata = {
              'title': updatedEntry.title,
              if (updatedEntry.tags != null && updatedEntry.tags!.isNotEmpty)
                'tags': updatedEntry.tags,
            };
            final serverUpdated = await api.updateEntry(
              updatedEntry.id,
              content: updatedEntry.content,
              metadata: metadata,
            );
            if (!mounted) return;
            if (serverUpdated == null) {
              // Server unreachable — queue the edit for retry.
              final cache = await ref.read(journalLocalCacheProvider.future);
              if (!mounted) return;
              cache.markForEdit(
                updatedEntry.id,
                content: updatedEntry.content,
                title: updatedEntry.title,
              );
            }

            // Sync tag changes to graph — best-effort alongside metadata.
            // Metadata is the durable path; backend migration catches gaps.
            if (!mounted) return;
            final oldTags = Set<String>.from(displayEntry.tags ?? []);
            final newTags = Set<String>.from(updatedEntry.tags ?? []);
            if (oldTags != newTags) {
              final tagService = ref.read(tagServiceProvider);
              for (final t in newTags.difference(oldTags)) {
                tagService.addTag('note', updatedEntry.id, t).then((ok) {
                  if (!ok) debugPrint('[JournalScreen] Tag sync failed: add "$t" to ${updatedEntry.id}');
                });
              }
              for (final t in oldTags.difference(newTags)) {
                tagService.removeTag('note', updatedEntry.id, t).then((ok) {
                  if (!ok) debugPrint('[JournalScreen] Tag sync failed: remove "$t" from ${updatedEntry.id}');
                });
              }
            }

            if (!mounted) return;
            ref.invalidate(selectedJournalProvider);
          },
        ),
      ),
    );
  }

  Widget _buildAudioPlayer(BuildContext context, JournalEntry entry, bool isDark) {
    final audioPath = entry.audioPath;
    if (audioPath == null) return const SizedBox.shrink();

    final serverBaseUrl = ref.read(aiServerUrlProvider).valueOrNull ?? AppConfig.defaultServerUrl;
    final audioUrl = JournalHelpers.getAudioUrl(audioPath, serverBaseUrl);
    final duration = Duration(seconds: entry.durationSeconds ?? 0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: PlaybackControls(filePath: audioUrl, duration: duration),
    );
  }

  void _showEntryActions(BuildContext context, JournalDay journal, JournalEntry entry) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? BrandColors.charcoal : BrandColors.stone,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),

            // Actions
            ListTile(
              leading: const Icon(Icons.visibility_outlined),
              title: const Text('View details'),
              onTap: () {
                Navigator.pop(context);
                _showEntryDetail(context, entry);
              },
            ),
            if (entry.content.isNotEmpty)
              ListTile(
                leading: Icon(Icons.copy_outlined, color: BrandColors.forest),
                title: const Text('Copy text'),
                onTap: () {
                  Navigator.pop(context);
                  _copyEntryContent(entry);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(context);
                _showEntryDetail(context, entry, startInEditMode: true);
              },
            ),
            if (entry.type == JournalEntryType.voice && entry.hasAudio)
              ListTile(
                leading: Icon(Icons.transcribe, color: BrandColors.turquoise),
                title: const Text('Re-transcribe audio'),
                subtitle: const Text('Replace text with fresh transcription'),
                onTap: () {
                  Navigator.pop(context);
                  _handleTranscribe(entry, journal);
                },
              ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: BrandColors.error),
              title: Text('Delete', style: TextStyle(color: BrandColors.error)),
              onTap: () {
                Navigator.pop(context);
                _deleteEntry(context, journal, entry);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _copyEntryContent(JournalEntry entry) {
    if (entry.content.isEmpty) return;

    Clipboard.setData(ClipboardData(text: entry.content));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Text('Copied to clipboard'),
            ],
          ),
          backgroundColor: BrandColors.forest,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
  }

  Future<void> _deleteEntry(BuildContext context, JournalDay journal, JournalEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Entry'),
        content: const Text('Are you sure you want to delete this entry?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: BrandColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      debugPrint('[JournalScreen] Deleting entry ${entry.id}...');

      // Mark as pending_delete immediately — removes from cache and hides from UI.
      // This makes deletion feel instant whether we're online or offline.
      final cache = await ref.read(journalLocalCacheProvider.future);
      cache.markForDelete(entry.id);

      if (mounted && _cachedJournal != null) {
        setState(() {
          _cachedJournal = _cachedJournal!.removeEntry(entry.id);
        });
      }

      // Attempt the server delete now. If it succeeds, fully remove the local
      // row. If it fails (offline, server error), the pending_delete flag stays
      // and _flushPendingOps will retry on the next journal load or reconnect.
      final api = ref.read(dailyApiServiceProvider);
      final ok = await api.deleteEntry(entry.id);
      if (ok) {
        cache.removeEntry(entry.id);
        debugPrint('[JournalScreen] Entry deleted from server');
      } else {
        debugPrint('[JournalScreen] Delete queued for retry (offline or server error)');
      }

      if (!mounted) return;
      ref.invalidate(selectedJournalProvider);
      ref.read(journalRefreshTriggerProvider.notifier).state++;
    }
  }
}
