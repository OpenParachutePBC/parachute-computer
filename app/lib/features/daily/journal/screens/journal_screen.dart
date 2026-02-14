import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/sync_provider.dart';
import '../../recorder/providers/service_providers.dart';
import '../models/journal_day.dart';
import '../models/journal_entry.dart';
import '../providers/journal_providers.dart';
import '../providers/journal_screen_state_provider.dart';
import '../widgets/journal_header.dart';
import '../widgets/journal_content_view.dart';
import '../widgets/journal_empty_state.dart';
import '../widgets/journal_input_bar.dart';
import '../widgets/mini_audio_player.dart';
import '../widgets/entry_edit_modal.dart';
import '../widgets/send_to_chat_sheet.dart';
import '../widgets/journal_entry_row.dart';
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

  // Editing state
  String? _editingEntryId;
  String? _editingEntryContent;
  String? _editingEntryTitle;

  // Guard to prevent multiple rapid audio plays
  bool _isPlayingAudio = false;

  // Flag to scroll to bottom after new entry is added
  bool _shouldScrollToBottom = false;

  // Audio playback state
  String? _currentlyPlayingAudioPath;
  String? _currentlyPlayingTitle;

  // Draft caching
  Timer? _draftSaveTimer;
  static const _draftKeyPrefix = 'journal_draft_';

  // Save state tracking for UI feedback
  bool _isSaving = false;
  bool _hasDraftSaved = false;

  /// Get current save state for UI indicator
  EntrySaveState get _currentSaveState {
    if (_isSaving) return EntrySaveState.saving;
    if (_hasDraftSaved) return EntrySaveState.draftSaved;
    return EntrySaveState.saved;
  }

  // Local journal cache to avoid loading flash on updates
  JournalDay? _cachedJournal;
  DateTime? _cachedJournalDate;

  // Track last known pull counter to detect changes
  int? _lastPullCounter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkForPendingDrafts();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flushPendingDraft();
    _draftSaveTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Save draft when app goes to background
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _flushPendingDraft();
    }
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

    // Update cache when data is available
    journalAsync.whenData((journal) {
      _cachedJournal = journal;
      _cachedJournalDate = selectedDate;
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
                onPhotoCaptured: (imagePath) => _addPhotoEntry(imagePath),
                onHandwritingCaptured: (imagePath, linedBackground) =>
                    _addHandwritingEntry(imagePath, linedBackground),
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
    // Watch agent outputs and chat log for the selected date
    final agentOutputsAsync = ref.watch(agentOutputsForDateProvider(selectedDate));
    final chatLogAsync = ref.watch(selectedChatLogProvider);

    // Handle scroll to bottom after new entry is added
    if (_shouldScrollToBottom) {
      _shouldScrollToBottom = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToBottom();
      });
    }

    // Check if we have any content at all
    final hasJournalEntries = journal.entries.isNotEmpty;
    final agentOutputs = agentOutputsAsync.valueOrNull ?? [];
    final hasAgentOutputs = agentOutputs.isNotEmpty;
    final hasChatLog = chatLogAsync.valueOrNull?.hasContent ?? false;
    final hasAnyContent = hasJournalEntries || hasAgentOutputs || hasChatLog;

    if (!hasAnyContent) {
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
      editingEntryId: _editingEntryId,
      currentSaveState: _currentSaveState,
      scrollController: _scrollController,
      onRefresh: _refreshJournal,
      onSaveCurrentEdit: _saveCurrentEdit,
      onEntryTap: _handleEntryTap,
      onShowEntryActions: _showEntryActions,
      onPlayAudio: _playAudio,
      onTranscribe: _handleTranscribe,
      onEnhance: _handleEnhance,
      onContentChanged: _handleContentChanged,
      onTitleChanged: _handleTitleChanged,
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
          ref.invalidate(selectedReflectionProvider);
          ref.invalidate(localAgentConfigsProvider);
          ref.invalidate(agentOutputsForDateProvider(selectedDate));
          ref.read(journalRefreshTriggerProvider.notifier).state++;
        }
      });
    }
    _lastPullCounter = pullCounter;
  }

  // ========== Refresh and Scroll ==========

  Future<void> _refreshJournal() async {
    // Refresh from disk immediately
    ref.invalidate(selectedJournalProvider);
    ref.invalidate(selectedReflectionProvider);

    // Also refresh agent providers - clear the cache and re-read from disk
    ref.invalidate(localAgentConfigsProvider);
    final selectedDate = ref.read(selectedJournalDateProvider);
    ref.invalidate(agentOutputsForDateProvider(selectedDate));
    ref.read(journalRefreshTriggerProvider.notifier).state++;

    // Pull changes from server for this specific date (user-triggered refresh)
    debugPrint('[JournalScreen] Refreshing - pulling changes for $selectedDate...');
    ref.read(syncProvider.notifier).pullDate(selectedDate);
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

  // ========== Draft Management ==========

  void _flushPendingDraft() {
    if (_editingEntryId != null && (_editingEntryContent != null || _editingEntryTitle != null)) {
      _draftSaveTimer?.cancel();
      _saveDraft(_editingEntryId!, _editingEntryContent, _editingEntryTitle);
      debugPrint('[JournalScreen] Flushed pending draft for $_editingEntryId');
    }
  }

  Future<void> _checkForPendingDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_draftKeyPrefix));
    if (keys.isNotEmpty) {
      debugPrint('[JournalScreen] Found ${keys.length} pending draft(s)');
    }
  }

  void _saveDraftDebounced(String entryId, String? content, String? title) {
    _draftSaveTimer?.cancel();
    if (mounted) {
      setState(() {
        _isSaving = true;
        _hasDraftSaved = false;
      });
    }
    _draftSaveTimer = Timer(const Duration(milliseconds: 500), () {
      _saveDraft(entryId, content, title);
    });
  }

  Future<void> _saveDraft(String entryId, String? content, String? title) async {
    if (content == null && title == null) return;

    final prefs = await SharedPreferences.getInstance();
    final key = '$_draftKeyPrefix$entryId';
    final draftValue = '${title ?? ''}|||${content ?? ''}';
    await prefs.setString(key, draftValue);
    debugPrint('[JournalScreen] Draft saved for entry $entryId');

    if (mounted) {
      setState(() {
        _isSaving = false;
        _hasDraftSaved = true;
      });
    }
  }

  Future<({String? title, String? content})?> _loadDraft(String entryId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_draftKeyPrefix$entryId';
    final draftValue = prefs.getString(key);

    if (draftValue == null) return null;

    final parts = draftValue.split('|||');
    if (parts.length != 2) return null;

    final title = parts[0].isEmpty ? null : parts[0];
    final content = parts[1].isEmpty ? null : parts[1];

    if (title == null && content == null) return null;

    debugPrint('[JournalScreen] Draft loaded for entry $entryId');
    return (title: title, content: content);
  }

  Future<void> _clearDraft(String entryId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_draftKeyPrefix$entryId';
    await prefs.remove(key);
    debugPrint('[JournalScreen] Draft cleared for entry $entryId');
  }

  // ========== Entry CRUD Operations ==========

  Future<void> _addTextEntry(String text) async {
    debugPrint('[JournalScreen] Adding text entry...');

    try {
      final service = await ref.read(journalServiceFutureProvider.future);
      final result = await service.addTextEntry(content: text);

      debugPrint('[JournalScreen] Entry added, updating cache...');
      setState(() {
        _cachedJournal = result.journal;
        _shouldScrollToBottom = true;
      });

      ref.invalidate(selectedJournalProvider);
      ref.read(journalRefreshTriggerProvider.notifier).state++;

      final selectedDate = ref.read(selectedJournalDateProvider);
      final journalPath = JournalHelpers.journalPathForDate(selectedDate);
      debugPrint('[JournalScreen] Scheduling push for $journalPath after text entry...');
      ref.read(syncProvider.notifier).schedulePush(journalPath);
    } catch (e, st) {
      debugPrint('[JournalScreen] Error adding text entry: $e\n$st');
    }
  }

  Future<void> _addVoiceEntry(String transcript, String audioPath, int duration) async {
    debugPrint('[JournalScreen] Adding voice entry...');

    try {
      final service = await ref.read(journalServiceFutureProvider.future);
      final result = await service.addVoiceEntry(
        transcript: transcript,
        audioPath: audioPath,
        durationSeconds: duration,
      );

      // Track if this entry needs transcription update (empty transcript)
      if (transcript.isEmpty) {
        ref.read(journalScreenStateProvider.notifier).setPendingTranscription(result.entry.id);
        debugPrint('[JournalScreen] Entry ${result.entry.id} pending transcription');
      }

      debugPrint('[JournalScreen] Voice entry added, updating cache...');
      setState(() {
        _cachedJournal = result.journal;
        _shouldScrollToBottom = true;
      });

      ref.invalidate(selectedJournalProvider);
      ref.read(journalRefreshTriggerProvider.notifier).state++;

      final selectedDate = ref.read(selectedJournalDateProvider);
      final journalPath = JournalHelpers.journalPathForDate(selectedDate);
      debugPrint('[JournalScreen] Scheduling push for $journalPath after voice entry...');
      ref.read(syncProvider.notifier).schedulePush(journalPath);
    } catch (e, st) {
      debugPrint('[JournalScreen] Error adding voice entry: $e\n$st');
    }
  }

  Future<void> _addPhotoEntry(String imagePath) async {
    debugPrint('[JournalScreen] Adding photo entry: $imagePath');

    try {
      final service = await ref.read(journalServiceFutureProvider.future);
      final result = await service.addPhotoEntry(imagePath: imagePath);

      debugPrint('[JournalScreen] Photo entry added, updating cache...');
      setState(() {
        _cachedJournal = result.journal;
        _shouldScrollToBottom = true;
      });

      ref.invalidate(selectedJournalProvider);
      ref.read(journalRefreshTriggerProvider.notifier).state++;

      final selectedDate = ref.read(selectedJournalDateProvider);
      final journalPath = JournalHelpers.journalPathForDate(selectedDate);
      debugPrint('[JournalScreen] Scheduling push for $journalPath after photo entry...');
      ref.read(syncProvider.notifier).schedulePush(journalPath);
    } catch (e, st) {
      debugPrint('[JournalScreen] Error adding photo entry: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add photo: $e'),
            backgroundColor: BrandColors.error,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _addHandwritingEntry(String imagePath, bool linedBackground) async {
    debugPrint('[JournalScreen] Adding handwriting entry: $imagePath (lined: $linedBackground)');

    try {
      final service = await ref.read(journalServiceFutureProvider.future);
      final result = await service.addHandwritingEntry(
        imagePath: imagePath,
        linedBackground: linedBackground,
      );

      debugPrint('[JournalScreen] Handwriting entry added, updating cache...');
      setState(() {
        _cachedJournal = result.journal;
        _shouldScrollToBottom = true;
      });

      ref.invalidate(selectedJournalProvider);
      ref.read(journalRefreshTriggerProvider.notifier).state++;

      final selectedDate = ref.read(selectedJournalDateProvider);
      final journalPath = JournalHelpers.journalPathForDate(selectedDate);
      debugPrint('[JournalScreen] Scheduling push for $journalPath after handwriting entry...');
      ref.read(syncProvider.notifier).schedulePush(journalPath);
    } catch (e, st) {
      debugPrint('[JournalScreen] Error adding handwriting entry: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add handwriting: $e'),
            backgroundColor: BrandColors.error,
            duration: const Duration(seconds: 3),
          ),
        );
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
      final service = await ref.read(journalServiceFutureProvider.future);
      final selectedDate = ref.read(selectedJournalDateProvider);

      final existingEntry = _cachedJournal?.getEntry(entryId);
      final entry = JournalEntry(
        id: entryId,
        title: existingEntry?.title ?? JournalHelpers.formatTime(DateTime.now()),
        content: transcript,
        type: JournalEntryType.voice,
        createdAt: existingEntry?.createdAt ?? DateTime.now(),
        audioPath: existingEntry?.audioPath,
        durationSeconds: existingEntry?.durationSeconds,
      );

      await service.updateEntry(selectedDate, entry);
      debugPrint('[JournalScreen] Transcription update complete');

      if (_cachedJournal != null) {
        setState(() {
          _cachedJournal = _cachedJournal!.updateEntry(entry);
        });
      }

      ref.invalidate(selectedJournalProvider);

      // Auto-enhance if enabled
      if (transcript.isNotEmpty) {
        final autoEnhance = await ref.read(autoEnhanceProvider.future);
        if (autoEnhance) {
          debugPrint('[JournalScreen] Auto-enhancing transcription...');
          await Future.delayed(const Duration(milliseconds: 100));
          if (mounted) {
            _handleEnhance(entry);
          }
        }
      }
    } catch (e, st) {
      debugPrint('[JournalScreen] Error updating transcription: $e\n$st');
    }
  }

  // ========== Entry Actions ==========

  void _handleEntryTap(JournalEntry entry) {
    if (_editingEntryId == entry.id) return;

    if (_editingEntryId != null) {
      _saveCurrentEdit();
    }

    _showEntryDetail(context, entry);
  }

  Future<void> _startEditing(JournalEntry entry) async {
    if (entry.id == 'preamble' || entry.id.startsWith('plain_')) {
      return;
    }

    if (_editingEntryId != null) {
      await _saveCurrentEdit();
    }

    final draft = await _loadDraft(entry.id);
    final hasUnsavedDraft = draft != null &&
        ((draft.content != null && draft.content != entry.content) ||
            (draft.title != null && draft.title != entry.title));

    setState(() {
      _editingEntryId = entry.id;
      _isSaving = false;
      _hasDraftSaved = hasUnsavedDraft;

      if (hasUnsavedDraft) {
        _editingEntryContent = draft.content ?? entry.content;
        _editingEntryTitle = draft.title ?? entry.title;
      } else {
        _editingEntryContent = entry.content;
        _editingEntryTitle = entry.title;
      }
    });

    if (hasUnsavedDraft && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.restore, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Text('Draft restored'),
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

  Future<void> _saveCurrentEdit() async {
    if (_editingEntryId == null) return;

    _draftSaveTimer?.cancel();

    final entryId = _editingEntryId!;
    final newContent = _editingEntryContent;
    final newTitle = _editingEntryTitle;

    setState(() {
      _editingEntryId = null;
      _editingEntryContent = null;
      _editingEntryTitle = null;
      _isSaving = false;
      _hasDraftSaved = false;
    });

    if (newContent == null && newTitle == null) {
      await _clearDraft(entryId);
      return;
    }

    try {
      final service = await ref.read(journalServiceFutureProvider.future);
      final selectedDate = ref.read(selectedJournalDateProvider);

      final journal = await service.loadDay(selectedDate);
      final entry = journal.entries.firstWhere(
        (e) => e.id == entryId,
        orElse: () => throw Exception('Entry not found'),
      );

      final updatedEntry = entry.copyWith(
        content: newContent ?? entry.content,
        title: newTitle ?? entry.title,
      );

      await service.updateEntry(selectedDate, updatedEntry);
      debugPrint('[JournalScreen] Saved edit for entry $entryId');

      await _clearDraft(entryId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                const Text('Saved'),
              ],
            ),
            backgroundColor: BrandColors.forest,
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }

      ref.invalidate(selectedJournalProvider);
    } catch (e) {
      debugPrint('[JournalScreen] Error saving edit: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'),
            backgroundColor: BrandColors.error,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _handleContentChanged(String entryId, String newContent) {
    if (_editingEntryId == entryId) {
      _editingEntryContent = newContent;
      _saveDraftDebounced(entryId, newContent, _editingEntryTitle);
    }
  }

  void _handleTitleChanged(String entryId, String newTitle) {
    if (_editingEntryId == entryId) {
      _editingEntryTitle = newTitle;
      _saveDraftDebounced(entryId, _editingEntryContent, newTitle);
    }
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

    ref.read(journalScreenStateProvider.notifier).startTranscription(entry.id);
    debugPrint('[JournalScreen] Starting transcription for entry ${entry.id}');

    try {
      final fileSystemService = ref.read(fileSystemServiceProvider);
      final vaultPath = await fileSystemService.getRootPath();
      final fullAudioPath = '$vaultPath/$audioPath';

      final audioFile = File(fullAudioPath);
      if (!await audioFile.exists()) {
        throw Exception('Audio file not found at $fullAudioPath');
      }

      final postProcessingService = ref.read(recordingPostProcessingProvider);
      final result = await postProcessingService.process(
        audioPath: fullAudioPath,
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

      debugPrint('[JournalScreen] Transcription complete: ${transcript.length} chars');

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
        final service = await ref.read(journalServiceFutureProvider.future);
        final selectedDate = ref.read(selectedJournalDateProvider);
        final updatedEntry = entry.copyWith(content: transcript);
        await service.updateEntry(selectedDate, updatedEntry);

        if (mounted && _cachedJournal != null) {
          setState(() {
            _cachedJournal = _cachedJournal!.updateEntry(updatedEntry);
          });
        }

        ref.invalidate(selectedJournalProvider);

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

        // Auto-enhance if enabled
        final autoEnhance = await ref.read(autoEnhanceProvider.future);
        if (autoEnhance) {
          debugPrint('[JournalScreen] Auto-enhancing transcription...');
          await Future.delayed(const Duration(milliseconds: 100));
          if (mounted) {
            _handleEnhance(updatedEntry);
          }
        }
      }
    } catch (e) {
      debugPrint('[JournalScreen] Transcription failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Transcription failed: $e'),
            backgroundColor: BrandColors.error,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        ref.read(journalScreenStateProvider.notifier).completeTranscription(entry.id);
      }
    }
  }

  Future<void> _handleEnhance(JournalEntry entry) async {
    // Enhancement not yet available in Parachute Daily
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('AI enhancement coming soon!'),
          backgroundColor: BrandColors.turquoise,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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

      final fullPath = await JournalHelpers.getFullAudioPath(relativePath);
      debugPrint('[JournalScreen] Full audio path: $fullPath');

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

  void _showEntryDetail(BuildContext context, JournalEntry entry) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canEdit = entry.id != 'preamble' && !entry.id.startsWith('plain_');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => EntryEditModal(
        entry: entry,
        canEdit: canEdit,
        audioPlayer: entry.hasAudio ? _buildAudioPlayer(context, entry, isDark) : null,
        onSave: (updatedEntry) async {
          final service = await ref.read(journalServiceFutureProvider.future);
          final selectedDate = ref.read(selectedJournalDateProvider);
          await service.updateEntry(selectedDate, updatedEntry);
          ref.invalidate(selectedJournalProvider);
        },
      ),
    );
  }

  Widget _buildAudioPlayer(BuildContext context, JournalEntry entry, bool isDark) {
    final audioPath = entry.audioPath;
    if (audioPath == null) return const SizedBox.shrink();

    return FutureBuilder<String>(
      future: JournalHelpers.getFullAudioPath(audioPath),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            padding: const EdgeInsets.all(16),
            child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        if (!snapshot.hasData || snapshot.hasError) {
          return Container(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Audio not available',
              style: TextStyle(color: BrandColors.driftwood),
            ),
          );
        }

        final fullPath = snapshot.data!;
        final duration = Duration(seconds: entry.durationSeconds ?? 0);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: PlaybackControls(filePath: fullPath, duration: duration),
        );
      },
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
            if (entry.content.isNotEmpty)
              ListTile(
                leading: Icon(Icons.chat_bubble_outline, color: BrandColors.turquoise),
                title: const Text('Send to Chat'),
                onTap: () {
                  Navigator.pop(context);
                  SendToChatSheet.show(context, content: entry.content, title: entry.title);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(context);
                _startEditing(entry);
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
      debugPrint('[JournalScreen] Deleting entry...');

      try {
        final service = await ref.read(journalServiceFutureProvider.future);
        await service.deleteEntry(journal.date, entry.id);
        debugPrint('[JournalScreen] Entry deleted successfully');

        ref.invalidate(selectedJournalProvider);
        ref.read(journalRefreshTriggerProvider.notifier).state++;

        final journalPath = JournalHelpers.journalPathForDate(journal.date);
        debugPrint('[JournalScreen] Scheduling push for $journalPath after delete...');
        ref.read(syncProvider.notifier).schedulePush(journalPath);
      } catch (e, st) {
        debugPrint('[JournalScreen] Error deleting entry: $e\n$st');
      }
    }
  }
}
