import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/model_download_provider.dart';
import 'package:parachute/core/services/model_download_service.dart';
import '../../capture/providers/capture_providers.dart';
import '../../capture/screens/handwriting_screen.dart';
import '../../recorder/providers/service_providers.dart';
import '../../recorder/providers/transcription_progress_provider.dart';
import '../../recorder/providers/streaming_transcription_provider.dart';
import '../../recorder/services/live_transcription_service_v3.dart';
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
  /// Called when a photo is captured from camera or gallery
  final Future<void> Function(String imagePath)? onPhotoCaptured;
  /// Called when handwriting canvas is saved
  final Future<void> Function(String imagePath, bool linedBackground)? onHandwritingCaptured;

  const JournalInputBar({
    super.key,
    required this.onTextSubmitted,
    this.onVoiceRecorded,
    this.onTranscriptReady,
    this.onPhotoCaptured,
    this.onHandwritingCaptured,
  });

  @override
  ConsumerState<JournalInputBar> createState() => _JournalInputBarState();
}

class _JournalInputBarState extends ConsumerState<JournalInputBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isRecording = false;
  bool _isPaused = false;
  bool _isSubmitting = false;
  bool _isProcessing = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _durationTimer;

  // Streaming transcription state
  final bool _useStreamingTranscription = true; // Enable by default
  bool _isUsingStreamingMode = false; // Track which mode was actually started
  StreamSubscription<StreamingTranscriptionState>? _streamingSubscription;

  @override
  void initState() {
    super.initState();
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
    _durationTimer?.cancel();
    _streamingSubscription?.cancel();
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
    if (_isRecording || widget.onVoiceRecorded == null) return;

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

    debugPrint('[JournalInputBar] Starting recording - streaming mode: $_useStreamingTranscription (model ready: $isModelReady)');

    if (_useStreamingTranscription) {
      // Use streaming transcription service (handles model init gracefully)
      _isUsingStreamingMode = true;
      await _startStreamingRecording();
    } else {
      // Only use standard recording if streaming is explicitly disabled
      _isUsingStreamingMode = false;
      await _startStandardRecording();
    }
  }

  /// Start recording with streaming transcription (real-time feedback)
  Future<void> _startStreamingRecording() async {
    try {
      final streamingNotifier = ref.read(streamingRecordingProvider.notifier);
      final started = await streamingNotifier.startRecording();

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

      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
      });

      // Start duration timer
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted && _isRecording && !_isPaused) {
          setState(() {
            _recordingDuration = _recordingDuration + const Duration(seconds: 1);
          });
        }
      });

      debugPrint('[JournalInputBar] Streaming recording started');
    } catch (e) {
      debugPrint('[JournalInputBar] Failed to start streaming recording: $e');
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

  /// Start standard recording (transcribe after recording ends)
  Future<void> _startStandardRecording() async {
    final audioService = ref.read(audioServiceProvider);

    try {
      await audioService.ensureInitialized();
      final started = await audioService.startRecording();

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

      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
      });

      // Start duration timer
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted && _isRecording && !_isPaused) {
          setState(() {
            _recordingDuration = _recordingDuration + const Duration(seconds: 1);
          });
        }
      });

      debugPrint('[JournalInputBar] Standard recording started');
    } catch (e) {
      debugPrint('[JournalInputBar] Failed to start recording: $e');
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
    if (!_isRecording || _isPaused) return;

    try {
      if (_isUsingStreamingMode) {
        // Pause streaming recording
        final service = await ref.read(autoPauseTranscriptionServiceProvider.future);
        await service.pauseRecording();
      } else {
        // Pause standard recording
        final audioService = ref.read(audioServiceProvider);
        await audioService.pauseRecording();
      }
      setState(() {
        _isPaused = true;
      });
      debugPrint('[JournalInputBar] Recording paused');
    } catch (e) {
      debugPrint('[JournalInputBar] Failed to pause recording: $e');
    }
  }

  Future<void> _resumeRecording() async {
    if (!_isRecording || !_isPaused) return;

    try {
      if (_isUsingStreamingMode) {
        // Resume streaming recording
        final service = await ref.read(autoPauseTranscriptionServiceProvider.future);
        await service.resumeRecording();
      } else {
        // Resume standard recording
        final audioService = ref.read(audioServiceProvider);
        await audioService.resumeRecording();
      }
      setState(() {
        _isPaused = false;
      });
      debugPrint('[JournalInputBar] Recording resumed');
    } catch (e) {
      debugPrint('[JournalInputBar] Failed to resume recording: $e');
    }
  }

  Future<void> _discardRecording() async {
    if (!_isRecording) return;

    _durationTimer?.cancel();
    _durationTimer = null;

    debugPrint('[JournalInputBar] Discarding recording - streaming mode: $_isUsingStreamingMode');

    // Use the mode we tracked when starting, not current init state
    if (_isUsingStreamingMode) {
      final streamingNotifier = ref.read(streamingRecordingProvider.notifier);
      await streamingNotifier.cancelRecording();
    } else {
      final audioService = ref.read(audioServiceProvider);
      await audioService.stopRecording();
    }

    setState(() {
      _isRecording = false;
      _isPaused = false;
      _recordingDuration = Duration.zero;
      _isUsingStreamingMode = false;
    });

    debugPrint('[JournalInputBar] Recording discarded');
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    _durationTimer?.cancel();
    _durationTimer = null;

    debugPrint('[JournalInputBar] Stopping recording - streaming mode: $_isUsingStreamingMode');

    // Use the mode we tracked when starting, not current init state
    if (_isUsingStreamingMode) {
      await _stopStreamingRecording();
    } else {
      await _stopStandardRecording();
    }
  }

  /// Stop streaming recording and get the transcript that was built up during recording
  Future<void> _stopStreamingRecording() async {
    final durationSeconds = _recordingDuration.inSeconds;

    setState(() {
      _isRecording = false;
      _isPaused = false;
      _isProcessing = true;
    });

    try {
      final streamingNotifier = ref.read(streamingRecordingProvider.notifier);

      // Stop recording first - this flushes final audio and may add more text
      final audioPath = await streamingNotifier.stopRecording();

      // Get the transcript AFTER stopping - includes any text from final flush
      final transcript = streamingNotifier.getStreamingTranscript();

      if (audioPath == null) {
        throw Exception('No audio file saved');
      }

      debugPrint('[JournalInputBar] Streaming recording stopped with transcript: ${transcript.length} chars');

      // Create entry with the streaming transcript we already have
      if (widget.onVoiceRecorded != null) {
        await widget.onVoiceRecorded!(transcript, audioPath, durationSeconds);
      }

      // If we got a transcript, we're done - otherwise fall back to background transcription
      if (transcript.isEmpty) {
        debugPrint('[JournalInputBar] No streaming transcript - falling back to background transcription');
        _transcribeInBackground(audioPath, durationSeconds);
      } else {
        // Clean up temp file since we have the transcript
        try {
          final tempFile = File(audioPath);
          if (await tempFile.exists()) {
            await tempFile.delete();
            debugPrint('[JournalInputBar] Deleted temp audio file');
          }
        } catch (e) {
          debugPrint('[JournalInputBar] Could not delete temp file: $e');
        }
      }
    } catch (e) {
      debugPrint('[JournalInputBar] Failed to process streaming recording: $e');
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
          _recordingDuration = Duration.zero;
          _isUsingStreamingMode = false;
        });
      }
    }
  }

  /// Stop standard recording and transcribe in background
  Future<void> _stopStandardRecording() async {
    final audioService = ref.read(audioServiceProvider);
    final durationSeconds = _recordingDuration.inSeconds;

    setState(() {
      _isRecording = false;
      _isPaused = false;
      _isProcessing = true;
    });

    try {
      final audioPath = await audioService.stopRecording();

      if (audioPath == null) {
        throw Exception('No audio file saved');
      }

      debugPrint('[JournalInputBar] Recording stopped, creating entry immediately...');

      // Create entry immediately with placeholder (streaming approach)
      // This gives instant feedback while transcription runs in background
      if (widget.onVoiceRecorded != null) {
        // Create with empty transcript - UI will show "Transcribing..."
        await widget.onVoiceRecorded!('', audioPath, durationSeconds);
      }

      // Now transcribe in background and update
      debugPrint('[JournalInputBar] Starting background transcription...');
      _transcribeInBackground(audioPath, durationSeconds);

    } catch (e) {
      debugPrint('[JournalInputBar] Failed to process recording: $e');
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
          _recordingDuration = Duration.zero;
        });
      }
    }
  }

  /// Transcribe audio in background and update the entry
  ///
  /// If Parakeet is not ready, transcription is skipped silently.
  /// The recording is saved with audio only - user can transcribe later.
  Future<void> _transcribeInBackground(String audioPath, int durationSeconds) async {
    // Check if transcription is available using the actual adapter
    // (transcriptionInitProvider may not reflect the true state if initialized elsewhere)
    final transcriptionAdapter = ref.read(transcriptionServiceAdapterProvider);
    final isReady = await transcriptionAdapter.isReady();

    if (!isReady) {
      debugPrint('[JournalInputBar] Transcription service not ready - skipping background transcription');
      // Don't delete the audio file - keep it for later transcription
      // The entry is already saved with the audio path
      return;
    }

    // Start progress tracking (uses historical data for estimates)
    await ref.read(transcriptionProgressProvider.notifier).startTranscription(
      audioDurationSeconds: durationSeconds,
    );

    try {
      final postProcessingService = ref.read(recordingPostProcessingProvider);
      final result = await postProcessingService.process(audioPath: audioPath);
      final transcript = result.transcript;

      // Mark progress complete and record timing for future estimates
      await ref.read(transcriptionProgressProvider.notifier).complete();

      debugPrint('[JournalInputBar] Background transcription complete: ${transcript.length} chars');

      // Clean up temp file now that transcription is done
      try {
        final tempFile = File(audioPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
          debugPrint('[JournalInputBar] Deleted temp audio file');
        }
      } catch (e) {
        debugPrint('[JournalInputBar] Could not delete temp file: $e');
      }

      if (transcript.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No speech detected in recording.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      // Update the entry with the transcript
      if (widget.onTranscriptReady != null) {
        await widget.onTranscriptReady!(transcript);
      }
    } catch (e) {
      // Mark progress as failed
      ref.read(transcriptionProgressProvider.notifier).fail(e.toString());

      debugPrint('[JournalInputBar] Background transcription failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Transcription failed: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _toggleRecording() {
    if (_isRecording) {
      _stopRecording();
    } else {
      _startRecording();
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
        child: _isRecording
            ? _buildRecordingMode(isDark, theme)
            : _buildInputMode(isDark, theme),
      ),
    );
  }

  /// Build the recording mode UI with timer, streaming transcript, and controls
  Widget _buildRecordingMode(bool isDark, ThemeData theme) {
    // Watch streaming state for real-time updates
    final streamingState = ref.watch(streamingTranscriptionProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Recording header with status and timer
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _isPaused
                ? BrandColors.warning.withValues(alpha: 0.1)
                : BrandColors.error.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              // Recording indicator (pulsing dot or pause icon)
              if (_isPaused)
                Icon(Icons.pause, color: BrandColors.warning, size: 20)
              else
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: BrandColors.error,
                    shape: BoxShape.circle,
                  ),
                ),
              const SizedBox(width: 12),

              // Duration
              Text(
                _formatDuration(_recordingDuration),
                style: TextStyle(
                  color: _isPaused ? BrandColors.warning : BrandColors.error,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),

              const Spacer(),

              // VAD indicator - shows when speech is detected
              streamingState.when(
                data: (state) => _buildVadIndicator(state.vadLevel > 0.5, isDark),
                loading: () => const SizedBox(width: 24, height: 24),
                error: (e, st) => const SizedBox(width: 24, height: 24),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Streaming transcription display
        streamingState.when(
          data: (state) => _buildStreamingTranscript(state, isDark, theme),
          loading: () => _buildTranscriptPlaceholder(isDark, TranscriptionModelStatus.initializing),
          error: (e, st) => _buildTranscriptPlaceholder(isDark, TranscriptionModelStatus.error),
        ),
        const SizedBox(height: 12),

        // Control buttons
        Row(
          children: [
            // Discard button
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _discardRecording,
                  icon: Icon(Icons.close, size: 20, color: BrandColors.driftwood),
                  label: Text(
                    'Discard',
                    style: TextStyle(color: BrandColors.driftwood),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: BrandColors.driftwood.withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Pause/Resume button
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                onPressed: _isPaused ? _resumeRecording : _pauseRecording,
                style: IconButton.styleFrom(
                  backgroundColor: _isPaused
                      ? BrandColors.forest.withValues(alpha: 0.1)
                      : BrandColors.warning.withValues(alpha: 0.1),
                  shape: const CircleBorder(),
                ),
                icon: Icon(
                  _isPaused ? Icons.play_arrow : Icons.pause,
                  color: _isPaused ? BrandColors.forest : BrandColors.warning,
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Save button
            Expanded(
              child: SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _stopRecording,
                  icon: const Icon(Icons.check, size: 20),
                  label: const Text('Done'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: BrandColors.forest,
                    foregroundColor: BrandColors.softWhite,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Build VAD (Voice Activity Detection) indicator
  Widget _buildVadIndicator(bool isSpeaking, bool isDark) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: isSpeaking
            ? BrandColors.forest.withValues(alpha: 0.2)
            : (isDark
                ? BrandColors.charcoal.withValues(alpha: 0.5)
                : BrandColors.stone.withValues(alpha: 0.5)),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: isSpeaking ? 14 : 10,
          height: isSpeaking ? 14 : 10,
          decoration: BoxDecoration(
            color: isSpeaking ? BrandColors.forest : BrandColors.driftwood,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  /// Build the streaming transcript display
  Widget _buildStreamingTranscript(
    StreamingTranscriptionState state,
    bool isDark,
    ThemeData theme,
  ) {
    final hasConfirmed = state.confirmedSegments.isNotEmpty;
    final hasInterim = state.interimText != null && state.interimText!.isNotEmpty;

    if (!hasConfirmed && !hasInterim) {
      return _buildTranscriptPlaceholder(isDark, state.modelStatus);
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated.withValues(alpha: 0.5)
            : BrandColors.cream.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        reverse: true, // Keep newest content visible
        child: RichText(
          text: TextSpan(
            style: TextStyle(
              color: isDark ? BrandColors.softWhite : BrandColors.ink,
              fontSize: 15,
              height: 1.5,
            ),
            children: [
              // Confirmed segments (finalized text) - joined with spaces
              if (hasConfirmed)
                TextSpan(text: state.confirmedSegments.join(' ')),

              // Interim text (currently being transcribed - shown in gray/italic)
              if (hasInterim) ...[
                if (hasConfirmed) const TextSpan(text: ' '),
                TextSpan(
                  text: state.interimText!,
                  style: TextStyle(
                    color: isDark
                        ? BrandColors.driftwood
                        : BrandColors.charcoal.withValues(alpha: 0.7),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Build placeholder when no transcript is available yet
  Widget _buildTranscriptPlaceholder(bool isDark, [TranscriptionModelStatus? modelStatus]) {
    // Determine message based on model status
    String message;
    bool showProgress = true;
    Color? iconColor;

    switch (modelStatus) {
      case TranscriptionModelStatus.initializing:
        message = 'Initializing transcription model...';
        iconColor = BrandColors.forest;
        break;
      case TranscriptionModelStatus.error:
        message = 'Transcription unavailable';
        showProgress = false;
        iconColor = BrandColors.warning;
        break;
      case TranscriptionModelStatus.ready:
      case TranscriptionModelStatus.notInitialized:
      case null:
        message = 'Listening...';
        iconColor = BrandColors.driftwood;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated.withValues(alpha: 0.3)
            : BrandColors.cream.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          if (showProgress)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(iconColor ?? BrandColors.driftwood),
              ),
            )
          else
            Icon(
              Icons.warning_amber_rounded,
              size: 16,
              color: iconColor,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: BrandColors.driftwood,
                fontSize: 14,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build the normal input mode UI
  Widget _buildInputMode(bool isDark, ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Processing indicator
        if (_isProcessing) ...[
          _buildRecordingIndicator(isDark),
          const SizedBox(height: 8),
        ],

        // Input row
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Voice record button
            _buildVoiceButton(isDark),
            const SizedBox(width: 4),

            // Photo button
            if (widget.onPhotoCaptured != null)
              _buildPhotoButton(isDark),
            if (widget.onPhotoCaptured != null)
              const SizedBox(width: 4),

            // Handwriting button
            if (widget.onHandwritingCaptured != null)
              _buildHandwritingButton(isDark),
            if (widget.onHandwritingCaptured != null)
              const SizedBox(width: 8),

            // Text input field
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
              _formatDuration(_recordingDuration),
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

  Widget _buildVoiceButton(bool isDark) {
    final isDisabled = _isProcessing;
    final isActive = _isRecording;

    return GestureDetector(
      onLongPress: isDisabled || isActive ? null : _showRecordingOptions,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isActive
              ? BrandColors.error
              : (isDisabled
                  ? (isDark ? BrandColors.charcoal : BrandColors.stone)
                  : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.forestMist)),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          onPressed: isDisabled ? null : _toggleRecording,
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
                  isActive ? Icons.stop : Icons.mic,
                  color: isActive
                      ? BrandColors.softWhite
                      : (isDisabled ? BrandColors.driftwood : BrandColors.forest),
                  size: 22,
                ),
        ),
      ),
    );
  }

  Widget _buildPhotoButton(bool isDark) {
    final isDisabled = _isRecording || _isProcessing;

    return AnimatedContainer(
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
        onPressed: isDisabled ? null : _showPhotoOptions,
        tooltip: 'Add photo',
        icon: Icon(
          Icons.camera_alt,
          color: isDisabled ? BrandColors.driftwood : BrandColors.forest,
          size: 22,
        ),
      ),
    );
  }

  Widget _buildHandwritingButton(bool isDark) {
    final isDisabled = _isRecording || _isProcessing;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: isDisabled
            ? (isDark ? BrandColors.charcoal : BrandColors.stone)
            : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.turquoise.withValues(alpha: 0.15)),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        onPressed: isDisabled ? null : _openHandwritingCanvas,
        tooltip: 'Handwriting',
        icon: Icon(
          Icons.edit,
          color: isDisabled ? BrandColors.driftwood : BrandColors.turquoise,
          size: 22,
        ),
      ),
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

  /// Show photo options bottom sheet (camera / gallery)
  void _showPhotoOptions() {
    if (widget.onPhotoCaptured == null) return;

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
                'Add Photo',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Take photo option
            ListTile(
              leading: Icon(Icons.camera_alt, color: BrandColors.forest),
              title: const Text('Take Photo'),
              subtitle: const Text('Use your camera'),
              onTap: () {
                Navigator.pop(context);
                _captureFromCamera();
              },
            ),

            // Choose from gallery option
            ListTile(
              leading: Icon(Icons.photo_library, color: BrandColors.turquoise),
              title: const Text('Choose from Gallery'),
              subtitle: const Text('Select an existing photo'),
              onTap: () {
                Navigator.pop(context);
                _selectFromGallery();
              },
            ),

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Capture photo from camera (with optional cropping)
  Future<void> _captureFromCamera() async {
    if (widget.onPhotoCaptured == null) return;

    try {
      final captureService = ref.read(photoCaptureServiceProvider);
      final result = await captureService.captureFromCameraWithCrop();

      if (result != null && mounted) {
        await widget.onPhotoCaptured!(result.relativePath);
      }
    } catch (e) {
      debugPrint('[JournalInputBar] Camera capture failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to capture photo: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// Select photo from gallery (with cropping)
  Future<void> _selectFromGallery() async {
    if (widget.onPhotoCaptured == null) return;

    try {
      final captureService = ref.read(photoCaptureServiceProvider);
      // Use cropping - great for screenshots where you want to crop to relevant content
      final result = await captureService.selectFromGalleryWithCrop();

      if (result != null && mounted) {
        await widget.onPhotoCaptured!(result.relativePath);
      }
    } catch (e) {
      debugPrint('[JournalInputBar] Gallery selection failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to select photo: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// Open handwriting canvas
  Future<void> _openHandwritingCanvas() async {
    if (widget.onHandwritingCaptured == null) return;

    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => HandwritingScreen(
          onSaved: (imagePath, linedBackground) {
            widget.onHandwritingCaptured!(imagePath, linedBackground);
          },
        ),
      ),
    );

    debugPrint('[JournalInputBar] Handwriting result: $result');
  }

  Widget _buildSendButton(bool isDark) {
    final canSend = _hasText && !_isSubmitting && !_isRecording && !_isProcessing;

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
