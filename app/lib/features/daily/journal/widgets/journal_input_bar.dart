import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/model_download_provider.dart';
import '../../capture/providers/capture_providers.dart';
import '../../capture/screens/handwriting_screen.dart';
import '../../recorder/providers/service_providers.dart';
import '../screens/compose_screen.dart';
import '../providers/compose_draft_provider.dart';
import '../providers/journal_screen_state_provider.dart';
import '../../recorder/providers/transcription_progress_provider.dart';
import '../../recorder/providers/daily_recording_provider.dart';
import '../../recorder/providers/post_hoc_transcription_provider.dart';
import '../../recorder/widgets/daily_recording_overlay.dart';
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
  /// Called when the full-screen compose screen saves an entry (title + content)
  final Future<void> Function(String title, String content)? onComposeSubmitted;

  const JournalInputBar({
    super.key,
    required this.onTextSubmitted,
    this.onVoiceRecorded,
    this.onTranscriptReady,
    this.onPhotoCaptured,
    this.onHandwritingCaptured,
    this.onComposeSubmitted,
  });

  @override
  ConsumerState<JournalInputBar> createState() => _JournalInputBarState();
}

class _JournalInputBarState extends ConsumerState<JournalInputBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isRecording = false;
  bool _isSubmitting = false;
  bool _isProcessing = false;
  bool _hasPendingDraft = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _durationTimer;
  @override
  void initState() {
    super.initState();
    // Trigger transcription model initialization in background
    // so it's ready when user wants to record
    _initializeTranscriptionModel();

    // Check for pending compose draft — show indicator if draft exists
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final draft = ref.read(composeDraftProvider);
      if (draft.isNotEmpty) {
        setState(() => _hasPendingDraft = true);
      }
    });
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

      setState(() {
        _isRecording = true;
        _recordingDuration = Duration.zero;
      });

      // Duration tracking is handled by DailyRecordingProvider,
      // but we keep local state for the minimum duration check
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted && _isRecording) {
          setState(() {
            _recordingDuration = _recordingDuration + const Duration(seconds: 1);
          });
        }
      });

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

  // Note: _startStreamingRecording, _startStandardRecording, _pauseRecording,
  // _resumeRecording removed — Daily now uses DailyRecordingProvider for
  // audio-only recording without live transcription. Chat voice input
  // (StreamingVoiceService) is separate and unaffected.

  Future<void> _discardRecording() async {
    if (!_isRecording) return;

    _durationTimer?.cancel();
    _durationTimer = null;

    debugPrint('[JournalInputBar] Discarding recording');

    // Cancel via Daily recording provider
    final dailyNotifier = ref.read(dailyRecordingProvider.notifier);
    await dailyNotifier.cancelRecording();

    HapticFeedback.lightImpact();

    setState(() {
      _isRecording = false;
      _recordingDuration = Duration.zero;
    });

    debugPrint('[JournalInputBar] Recording discarded');
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    _durationTimer?.cancel();
    _durationTimer = null;

    final durationSeconds = _recordingDuration.inSeconds;

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
    setState(() {
      _isRecording = false;
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
          _recordingDuration = Duration.zero;
        });
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

  /// Build the recording mode UI — calm waveform + timer, no live text
  Widget _buildRecordingMode(bool isDark, ThemeData theme) {
    final dailyNotifier = ref.read(dailyRecordingProvider.notifier);

    return DailyRecordingOverlay(
      amplitudeStream: dailyNotifier.amplitudeStream,
      onStop: _stopRecording,
      onCancel: _discardRecording,
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

  Widget _buildExpandButton(bool isDark) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        children: [
          IconButton(
            onPressed: _isRecording || _isProcessing ? null : _openComposeScreen,
            icon: Icon(
              Icons.open_in_full,
              color: isDark ? BrandColors.stone : BrandColors.charcoal,
              size: 20,
            ),
            tooltip: 'Expand to full editor',
          ),
          // Draft indicator dot
          if (_hasPendingDraft)
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: BrandColors.forest,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Open full-screen markdown compose editor
  Future<void> _openComposeScreen() async {
    // Transfer any text from the quick-capture bar to the compose screen
    final currentText = _controller.text;
    _controller.clear();
    _focusNode.unfocus();

    final result = await Navigator.push<ComposeResult>(
      context,
      MaterialPageRoute(
        builder: (context) => ComposeScreen(
          initialContent: currentText.isNotEmpty ? currentText : null,
        ),
      ),
    );

    if (result != null && mounted) {
      // Compose returned content — submit it
      final title = result.title;
      final content = result.content;

      if (widget.onComposeSubmitted != null) {
        await widget.onComposeSubmitted!(title, content);
      } else {
        // Fallback: prepend title as heading if present
        final fullContent = title.isNotEmpty ? '# $title\n\n$content' : content;
        await widget.onTextSubmitted(fullContent);
      }

      // Clear draft indicator
      setState(() => _hasPendingDraft = false);
    } else if (mounted) {
      // User discarded — check if draft was left behind
      final draft = ref.read(composeDraftProvider);
      setState(() => _hasPendingDraft = draft.isNotEmpty);
    }
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
