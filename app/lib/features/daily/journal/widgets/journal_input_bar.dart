import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/model_download_provider.dart';
import '../../recorder/providers/service_providers.dart';
import '../screens/entry_detail_screen.dart';
import '../providers/journal_screen_state_provider.dart';
import '../../recorder/providers/transcription_progress_provider.dart';
import '../../recorder/providers/daily_recording_provider.dart';
import '../../recorder/providers/post_hoc_transcription_provider.dart';
import '../../recorder/widgets/recording_waveform.dart';
import 'package:parachute/features/settings/screens/settings_screen.dart';

/// Input bar for adding entries to the journal
///
/// Supports text input and voice recording with transcription.
/// Uses streaming pattern: creates entry immediately, transcribes in background.
class JournalInputBar extends ConsumerStatefulWidget {
  final Future<void> Function(String text) onTextSubmitted;
  final Future<void> Function(String transcript, String audioPath, int duration)?
      onVoiceRecorded;
  /// Called when background transcription completes - allows updating the entry
  final Future<void> Function(String transcript)? onTranscriptReady;
  /// Called when the full-screen compose screen saves an entry (title + content)
  final Future<void> Function(String title, String content)? onComposeSubmitted;

  const JournalInputBar({
    super.key,
    required this.onTextSubmitted,
    this.onVoiceRecorded,
    this.onTranscriptReady,
    this.onComposeSubmitted,
  });

  @override
  ConsumerState<JournalInputBar> createState() => _JournalInputBarState();
}

class _JournalInputBarState extends ConsumerState<JournalInputBar>
    with SingleTickerProviderStateMixin {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isSubmitting = false;
  bool _isProcessing = false;

  /// Breathing animation for the stop button during recording
  late final AnimationController _breathingController;
  late final Animation<double> _breathingAnimation;
  @override
  void initState() {
    super.initState();

    // Breathing animation for stop button during recording
    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _breathingAnimation = Tween(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _breathingController, curve: Curves.easeInOut),
    );

    // Trigger transcription model initialization in background
    // so it's ready when user wants to record
    _initializeTranscriptionModel();

  }

  /// Initialize transcription model in background so it's ready for recording
  ///
  /// This is deferred to avoid blocking app startup and to handle cases
  /// where models aren't downloaded yet.
  Future<void> _initializeTranscriptionModel() async {
    // Delay initialization to let the UI render first
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;

    try {
      final transcriptionAdapter = ref.read(transcriptionServiceAdapterProvider);
      final isReady = await transcriptionAdapter.isReady();
      if (!isReady) {
        debugPrint('[JournalInputBar] Transcription not ready - will initialize when user starts recording');
        // Don't eagerly initialize on Android - let the user trigger it
        // This avoids crashes when models haven't been downloaded yet
        // The recorder will prompt for download when needed
      }
    } catch (e) {
      debugPrint('[JournalInputBar] Failed to check transcription readiness: $e');
      // Don't crash the app - transcription will be initialized on-demand
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _breathingController.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  Future<void> _submitText() async {
    if (!_hasText || _isSubmitting) return;

    final text = _controller.text.trim();
    setState(() => _isSubmitting = true);

    try {
      await widget.onTextSubmitted(text);
      _controller.clear();
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  Future<void> _startRecording() async {
    final recState = ref.read(dailyRecordingProvider);
    if (recState.isRecording || widget.onVoiceRecorded == null) return;

    // On Android, MUST check if transcription models are downloaded before proceeding
    // This is a critical check to prevent native crashes
    if (Platform.isAndroid) {
      // First check the sync state for download progress indication
      final downloadState = ref.read(modelDownloadCurrentStateProvider);

      if (downloadState.isDownloading) {
        // Download in progress - show message
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Voice model is downloading (${downloadState.progressText}). Please wait...'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      // Always do an async disk check to be certain models are ready
      // This prevents crashes when the provider state hasn't been updated yet
      debugPrint('[JournalInputBar] Checking models on disk...');
      final modelsReady = await checkModelsReady();
      debugPrint('[JournalInputBar] Models ready: $modelsReady');

      if (!modelsReady) {
        // Models not downloaded - start download and show message
        ref.read(modelDownloadServiceProvider).startDownload();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Starting voice model download. This is a one-time ~465MB download.'),
              duration: Duration(seconds: 5),
            ),
          );
        }
        return;
      }
    }

    // Check if transcription service is ready
    final transcriptionAdapter = ref.read(transcriptionServiceAdapterProvider);
    final isModelReady = await transcriptionAdapter.isReady();

    debugPrint('[JournalInputBar] Starting recording - post-hoc mode (model ready: $isModelReady)');

    // Use simplified Daily recording (audio only, no live transcription)
    await _startDailyRecording();
  }

  /// Start Daily recording — audio only, no live transcription
  ///
  /// Uses DailyRecordingProvider for a clean recording-only flow.
  /// Transcription happens post-hoc after recording stops.
  Future<void> _startDailyRecording() async {
    try {
      final dailyNotifier = ref.read(dailyRecordingProvider.notifier);
      final started = await dailyNotifier.startRecording();

      if (!started) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not start recording. Check microphone permissions.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      // Start breathing animation for stop button
      _breathingController.repeat(reverse: true);

      debugPrint('[JournalInputBar] Daily recording started (audio only)');
    } catch (e) {
      debugPrint('[JournalInputBar] Failed to start Daily recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start recording: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _pauseRecording() async {
    final recState = ref.read(dailyRecordingProvider);
    if (!recState.isRecording || recState.isPaused) return;

    final dailyNotifier = ref.read(dailyRecordingProvider.notifier);
    final paused = await dailyNotifier.pauseRecording();
    if (!paused) return;

    _breathingController.stop();
    HapticFeedback.lightImpact();

    debugPrint('[JournalInputBar] Recording paused');
  }

  Future<void> _resumeRecording() async {
    final recState = ref.read(dailyRecordingProvider);
    if (!recState.isRecording || !recState.isPaused) return;

    final dailyNotifier = ref.read(dailyRecordingProvider.notifier);
    final resumed = await dailyNotifier.resumeRecording();
    if (!resumed) return;

    _breathingController.repeat(reverse: true);
    HapticFeedback.lightImpact();

    debugPrint('[JournalInputBar] Recording resumed');
  }

  Future<void> _discardRecording() async {
    final recState = ref.read(dailyRecordingProvider);
    if (!recState.isRecording) return;

    _breathingController.stop();
    _breathingController.reset();

    debugPrint('[JournalInputBar] Discarding recording');

    // Cancel via Daily recording provider (resets all state)
    final dailyNotifier = ref.read(dailyRecordingProvider.notifier);
    await dailyNotifier.cancelRecording();

    HapticFeedback.lightImpact();

    debugPrint('[JournalInputBar] Recording discarded');
  }

  Future<void> _stopRecording() async {
    final recState = ref.read(dailyRecordingProvider);
    if (!recState.isRecording) return;

    final durationSeconds = recState.duration.inSeconds;

    // Minimum duration check: discard recordings < 3 seconds
    if (durationSeconds < 3) {
      debugPrint('[JournalInputBar] Recording too short (${durationSeconds}s), discarding');
      await _discardRecording();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording too short — try again'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    debugPrint('[JournalInputBar] Stopping Daily recording (${durationSeconds}s)');
    await _stopDailyRecording(durationSeconds);
  }

  /// Stop Daily recording and trigger post-hoc transcription
  Future<void> _stopDailyRecording(int durationSeconds) async {
    _breathingController.stop();
    _breathingController.reset();

    setState(() {
      _isProcessing = true;
    });

    try {
      final dailyNotifier = ref.read(dailyRecordingProvider.notifier);
      final audioPath = await dailyNotifier.stopRecording();

      if (audioPath == null) {
        throw Exception('No audio file saved');
      }

      HapticFeedback.heavyImpact();

      debugPrint('[JournalInputBar] Daily recording stopped, audio at: $audioPath');

      // Create entry immediately with empty transcript — "processing" state
      // The entry appears in the list with a progress indicator
      if (widget.onVoiceRecorded != null) {
        await widget.onVoiceRecorded!('', audioPath, durationSeconds);
      }

      // Get the entry ID that was just created
      final entryId = ref.read(journalScreenStateProvider).pendingTranscriptionEntryId;

      if (entryId != null) {
        // Enqueue post-hoc transcription — the provider handles everything:
        // tracking, transcription, updating entry, failure/retry
        ref.read(postHocTranscriptionProvider.notifier).enqueue(
          entryId: entryId,
          audioPath: audioPath,
          durationSeconds: durationSeconds,
        );
        debugPrint('[JournalInputBar] Enqueued post-hoc transcription for $entryId');
      } else {
        debugPrint('[JournalInputBar] Warning: no entry ID after creation, skipping transcription');
      }

    } catch (e) {
      debugPrint('[JournalInputBar] Failed to process Daily recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save recording: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Watch provider for recording state — single source of truth
    final recState = ref.watch(dailyRecordingProvider);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        border: Border(
          top: BorderSide(
            color: isDark ? BrandColors.charcoal : BrandColors.stone,
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: recState.isRecording
            ? _buildRecordingMode(isDark, theme, recState)
            : _buildInputMode(isDark, theme, recState),
      ),
    );
  }

  /// Build the inline recording mode — thin waveform + timer in the text field area
  Widget _buildRecordingMode(bool isDark, ThemeData theme, DailyRecordingState recState) {
    final dailyNotifier = ref.watch(dailyRecordingProvider.notifier);
    final isPaused = recState.isPaused;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Recording strip (replaces text field)
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            decoration: BoxDecoration(
              color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.cream,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: isPaused
                    ? (isDark ? BrandColors.charcoal : BrandColors.stone)
                    : BrandColors.forest.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // Recording indicator: breathing dot when active, static pause icon when paused
                if (isPaused)
                  Icon(Icons.pause, size: 14, color: BrandColors.driftwood)
                else
                  const _BreathingDot(),
                const SizedBox(width: 8),

                // Timer
                Text(
                  _formatDuration(recState.duration),
                  style: TextStyle(
                    color: isPaused ? BrandColors.driftwood : BrandColors.forest,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),

                // Compact waveform — only visible when actively recording
                if (!isPaused) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 80,
                    child: RecordingWaveform(
                      amplitudeStream: dailyNotifier.amplitudeStream,
                      height: 18,
                      barCount: 12,
                      color: BrandColors.forest,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),

        // Pause/Resume button
        _buildPauseResumeButton(isDark, isPaused),
        const SizedBox(width: 4),

        // Stop button
        _buildStopButton(isDark),
      ],
    );
  }

  /// Build the normal input mode UI
  Widget _buildInputMode(bool isDark, ThemeData theme, DailyRecordingState recState) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Processing indicator
        if (_isProcessing) ...[
          _buildRecordingIndicator(isDark),
          const SizedBox(height: 8),
        ],

        // Input row: [TextField] [mic] [expand] [send]
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Text input field — takes most of the width
            Expanded(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.cream,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _focusNode.hasFocus
                        ? BrandColors.forest
                        : (isDark ? BrandColors.charcoal : BrandColors.stone),
                    width: _focusNode.hasFocus ? 1.5 : 1,
                  ),
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  maxLines: null,
                  enabled: !_isProcessing,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.newline,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  ),
                  decoration: InputDecoration(
                    hintText: _isProcessing ? 'Transcribing...' : 'Capture a thought...',
                    hintStyle: TextStyle(
                      color: BrandColors.driftwood,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submitText(),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Voice record button
            _buildMicButton(isDark),
            const SizedBox(width: 4),

            // Expand to full-screen compose
            _buildExpandButton(isDark),
            const SizedBox(width: 4),

            // Send button
            _buildSendButton(isDark),
          ],
        ),
      ],
    );
  }

  Widget _buildRecordingIndicator(bool isDark) {
    final progressState = ref.watch(transcriptionProgressProvider);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: _isProcessing
            ? BrandColors.turquoise.withValues(alpha: 0.1)
            : BrandColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isProcessing) ...[
            // Show actual progress if available
            if (progressState.isActive) ...[
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  value: progressState.progress,
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                  backgroundColor: BrandColors.turquoise.withValues(alpha: 0.2),
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    progressState.status,
                    style: TextStyle(
                      color: BrandColors.turquoise,
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                  if (progressState.timeRemainingText.isNotEmpty)
                    Text(
                      progressState.timeRemainingText,
                      style: TextStyle(
                        color: BrandColors.turquoise.withValues(alpha: 0.7),
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ] else ...[
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Transcribing...',
                style: TextStyle(
                  color: BrandColors.turquoise,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ] else ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: BrandColors.error,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatDuration(ref.watch(dailyRecordingProvider.select((s) => s.duration))),
              style: TextStyle(
                color: BrandColors.error,
                fontWeight: FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMicButton(bool isDark) {
    final isDisabled = _isProcessing;

    return GestureDetector(
      onLongPress: isDisabled ? null : _showRecordingOptions,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isDisabled
              ? (isDark ? BrandColors.charcoal : BrandColors.stone)
              : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.forestMist),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          onPressed: isDisabled ? null : _startRecording,
          icon: _isProcessing
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isDark ? BrandColors.driftwood : BrandColors.charcoal,
                    ),
                  ),
                )
              : Icon(
                  Icons.mic,
                  color: isDisabled ? BrandColors.driftwood : BrandColors.forest,
                  size: 22,
                ),
        ),
      ),
    );
  }

  Widget _buildPauseResumeButton(bool isDark, bool isPaused) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: isPaused
            ? (isDark ? BrandColors.nightSurfaceElevated : BrandColors.forestMist)
            : (isDark ? BrandColors.charcoal.withValues(alpha: 0.6) : BrandColors.stone.withValues(alpha: 0.6)),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: isPaused ? _resumeRecording : _pauseRecording,
        icon: Icon(
          isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          color: isPaused ? BrandColors.forest : BrandColors.driftwood,
          size: 22,
        ),
      ),
    );
  }

  Widget _buildStopButton(bool isDark) {
    return AnimatedBuilder(
      animation: _breathingAnimation,
      child: IconButton(
        onPressed: _stopRecording,
        icon: const Icon(
          Icons.stop_rounded,
          color: BrandColors.softWhite,
          size: 24,
        ),
      ),
      builder: (context, child) {
        return Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: BrandColors.forest.withValues(alpha: _breathingAnimation.value),
            shape: BoxShape.circle,
          ),
          child: child,
        );
      },
    );
  }

  /// Show recording options bottom sheet (long press on mic)
  void _showRecordingOptions() {
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
            const SizedBox(height: 16),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Recording Options',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Settings option
            ListTile(
              leading: Icon(Icons.settings, color: BrandColors.driftwood),
              title: const Text('Recording Settings'),
              subtitle: const Text('Transcription, Omi device, and more'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const SettingsScreen(),
                  ),
                );
              },
            ),

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildExpandButton(bool isDark) {
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        onPressed: ref.watch(dailyRecordingProvider.select((s) => s.isRecording)) || _isProcessing ? null : _openComposeScreen,
        icon: Icon(
          Icons.open_in_full,
          color: isDark ? BrandColors.stone : BrandColors.charcoal,
          size: 20,
        ),
        tooltip: 'Expand to full editor',
      ),
    );
  }

  /// Open full-screen compose editor for new entries
  Future<void> _openComposeScreen() async {
    // Transfer any text from the quick-capture bar to the compose screen
    final currentText = _controller.text;
    _controller.clear();
    _focusNode.unfocus();

    final result = await Navigator.push<ComposeResult>(
      context,
      MaterialPageRoute(
        builder: (context) => EntryDetailScreen(
          entry: null,
          startInEditMode: true,
          allTags: const [],
          initialContent: currentText.isNotEmpty ? currentText : null,
        ),
      ),
    );

    if (result != null && mounted) {
      final title = result.title;
      final content = result.content;

      if (widget.onComposeSubmitted != null) {
        await widget.onComposeSubmitted!(title, content);
      } else {
        // Fallback: prepend title as heading if present
        final fullContent = title.isNotEmpty ? '# $title\n\n$content' : content;
        await widget.onTextSubmitted(fullContent);
      }
    }
  }

  Widget _buildSendButton(bool isDark) {
    final isRecording = ref.watch(dailyRecordingProvider.select((s) => s.isRecording));
    final canSend = _hasText && !_isSubmitting && !isRecording && !_isProcessing;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: canSend
            ? BrandColors.forest
            : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: canSend ? _submitText : null,
        icon: _isSubmitting
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    BrandColors.softWhite,
                  ),
                ),
              )
            : Icon(
                Icons.arrow_upward,
                color: canSend
                    ? BrandColors.softWhite
                    : BrandColors.driftwood,
                size: 22,
              ),
      ),
    );
  }
}

/// Small breathing dot indicating active recording
///
/// Forest green dot (8px) with opacity pulsing 0.4 → 1.0
/// on a 1-second cycle. Subtle, non-alarming.
class _BreathingDot extends StatefulWidget {
  const _BreathingDot();

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _animation = Tween(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: BrandColors.forest.withValues(alpha: _animation.value),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}
