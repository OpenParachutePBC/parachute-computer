import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/voice_input_providers.dart';
import 'package:parachute/core/providers/streaming_voice_providers.dart';
import 'package:parachute/core/providers/model_download_provider.dart';
import 'package:parachute/core/services/voice_input_service.dart';
import 'package:parachute/core/services/streaming_voice_service.dart';
import '../models/attachment.dart';

/// Text input field for chat messages with voice input and attachment support
class ChatInput extends ConsumerStatefulWidget {
  final Function(String, List<ChatAttachment>) onSend;
  final VoidCallback? onStop;
  final bool enabled;
  final bool isStreaming;
  final String? initialText;
  final String hintText;

  const ChatInput({
    super.key,
    required this.onSend,
    this.onStop,
    this.enabled = true,
    this.isStreaming = false,
    this.initialText,
    this.hintText = 'Message your vault...',
  });

  @override
  ConsumerState<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends ConsumerState<ChatInput>
    with SingleTickerProviderStateMixin {
  late TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _hasText = false;

  // Animation for recording pulse
  late AnimationController _pulseController;

  // Pending attachments
  final List<ChatAttachment> _attachments = [];
  bool _isLoadingAttachment = false;

  // Streaming transcription
  final bool _useStreamingTranscription = true; // Enable streaming by default
  bool _isStreamingRecording = false;
  bool _isProcessingStreamingStop = false; // Processing state for smooth transitions

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _hasText = _controller.text.isNotEmpty;
    _controller.addListener(_onTextChanged);

    // Pulse animation for recording state
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) {
      setState(() {
        _hasText = hasText;
      });
    }
  }

  void _handleSend() {
    final text = _controller.text.trim();
    // Can send if there's text OR attachments
    if ((text.isEmpty && _attachments.isEmpty) || !widget.enabled) return;

    widget.onSend(text, List.from(_attachments));
    _controller.clear();
    setState(() {
      _attachments.clear();
    });
    _focusNode.requestFocus();
  }

  Future<void> _handleAttachment() async {
    if (_isLoadingAttachment) return;

    setState(() {
      _isLoadingAttachment = true;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any, // Allow any file type - agent can figure out how to handle it
        allowMultiple: true,
        withData: true, // Get bytes directly on mobile
      );

      if (result != null) {
        for (final file in result.files) {
          ChatAttachment? attachment;

          if (file.bytes != null) {
            // Mobile: use bytes directly
            attachment = ChatAttachment.fromBytes(
              bytes: file.bytes!,
              fileName: file.name,
              mimeType: getMimeType(file.name),
            );
          } else if (file.path != null) {
            // Desktop: read from file path
            attachment = await ChatAttachment.fromFile(File(file.path!));
          }

          if (attachment != null) {
            setState(() {
              _attachments.add(attachment!);
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to attach file: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingAttachment = false;
        });
      }
    }
  }

  void _removeAttachment(int index) {
    setState(() {
      _attachments.removeAt(index);
    });
  }

  Future<void> _handleVoiceInput() async {
    if (_useStreamingTranscription) {
      await _handleStreamingVoiceInput();
    } else {
      await _handleStandardVoiceInput();
    }
  }

  /// Standard voice input (record all → transcribe once)
  Future<void> _handleStandardVoiceInput() async {
    final voiceService = ref.read(voiceInputServiceProvider);

    if (voiceService.isRecording) {
      // Stop and transcribe
      _pulseController.stop();
      final text = await voiceService.stopAndTranscribe();
      if (text != null && text.isNotEmpty) {
        // Append to existing text (with space if needed)
        final currentText = _controller.text;
        if (currentText.isNotEmpty && !currentText.endsWith(' ')) {
          _controller.text = '$currentText $text';
        } else {
          _controller.text = currentText + text;
        }
        // Move cursor to end
        _controller.selection = TextSelection.collapsed(
          offset: _controller.text.length,
        );
      }
    } else {
      // Start recording
      await voiceService.initialize();
      final started = await voiceService.startRecording();
      if (started) {
        _pulseController.repeat(reverse: true);
      }
    }
  }

  /// Streaming voice input (real-time transcription feedback)
  Future<void> _handleStreamingVoiceInput() async {
    // On Android, check if transcription models are downloaded
    if (Platform.isAndroid && !_isStreamingRecording) {
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

      if (downloadState.needsDownload) {
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

    final streamingService = ref.read(streamingVoiceServiceProvider);

    if (_isStreamingRecording) {
      // Stop streaming recording - show processing state while finalizing
      _pulseController.stop();
      setState(() {
        _isProcessingStreamingStop = true;
      });

      try {
        // Stop recording first - this flushes final audio and may add more text
        final audioPath = await streamingService.stopRecording();

        // Get the transcript AFTER stopping - includes any text from final flush
        final transcript = streamingService.getStreamingTranscript();

        // Now update UI state
        setState(() {
          _isStreamingRecording = false;
          _isProcessingStreamingStop = false;
        });

        if (audioPath != null && transcript.isNotEmpty) {
          // Append to existing text
          final currentText = _controller.text;
          if (currentText.isNotEmpty && !currentText.endsWith(' ')) {
            _controller.text = '$currentText $transcript';
          } else {
            _controller.text = currentText + transcript;
          }
          // Move cursor to end
          _controller.selection = TextSelection.collapsed(
            offset: _controller.text.length,
          );
        }
      } catch (e) {
        debugPrint('[ChatInput] Error stopping streaming recording: $e');
        setState(() {
          _isStreamingRecording = false;
          _isProcessingStreamingStop = false;
        });
      }
    } else {
      // Start streaming recording
      final started = await streamingService.startRecording();
      if (started) {
        setState(() {
          _isStreamingRecording = true;
        });
        _pulseController.repeat(reverse: true);
      }
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Watch voice input state (standard mode)
    final voiceState = ref.watch(voiceInputCurrentStateProvider);
    final isStandardRecording = voiceState == VoiceInputState.recording;
    final isTranscribing = voiceState == VoiceInputState.transcribing;

    // Watch streaming transcription state
    final streamingState = ref.watch(streamingVoiceCurrentStateProvider);
    final isRecording = _useStreamingTranscription
        ? _isStreamingRecording
        : isStandardRecording;

    // Get duration from appropriate source
    final durationAsync = ref.watch(voiceInputDurationProvider);
    final duration = _useStreamingTranscription
        ? streamingState.recordingDuration
        : (durationAsync.valueOrNull ?? Duration.zero);

    // Listen for errors (standard mode)
    ref.listen(voiceInputErrorProvider, (previous, next) {
      next.whenData((error) {
        if (error.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      });
    });

    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        border: Border(
          top: BorderSide(
            color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Attachment previews (shown when files are attached)
            if (_attachments.isNotEmpty)
              _buildAttachmentPreviews(isDark),

            // Processing indicator (shown while finalizing recording)
            if (_isProcessingStreamingStop && _useStreamingTranscription)
              _buildFinalizingIndicator(isDark, streamingState),

            // Streaming transcript display (shown when streaming recording)
            if (_isStreamingRecording && !_isProcessingStreamingStop && _useStreamingTranscription)
              _buildStreamingTranscriptDisplay(isDark, streamingState),

            // Recording indicator (shown when recording without streaming UI)
            if (isRecording && !_useStreamingTranscription)
              _buildRecordingIndicator(isDark, duration),

            // Transcribing indicator (standard mode only)
            if (isTranscribing && !_useStreamingTranscription)
              _buildTranscribingIndicator(isDark),

            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Attachment button (left side)
                _buildAttachmentButton(isDark, isRecording, isTranscribing),

                const SizedBox(width: Spacing.xs),

                // Microphone button
                _buildVoiceButton(isDark, isRecording, isTranscribing),

                const SizedBox(width: Spacing.sm),

                // Text field
                Expanded(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 150),
                    decoration: BoxDecoration(
                      color: isDark
                          ? BrandColors.nightSurfaceElevated
                          : BrandColors.cream,
                      borderRadius: Radii.button,
                      border: Border.all(
                        color: _focusNode.hasFocus
                            ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                            : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone),
                        width: _focusNode.hasFocus ? 1.5 : 1,
                      ),
                    ),
                    child: KeyboardListener(
                      focusNode: FocusNode(),
                      onKeyEvent: (event) {
                        // Send on Enter (without Shift)
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          _handleSend();
                        }
                      },
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        enabled: widget.enabled && !isRecording && !isTranscribing,
                        maxLines: null,
                        textInputAction: TextInputAction.newline,
                        style: TextStyle(
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                          fontSize: TypographyTokens.bodyMedium,
                        ),
                        decoration: InputDecoration(
                          hintText: isRecording
                              ? 'Recording...'
                              : isTranscribing
                                  ? 'Transcribing...'
                                  : widget.hintText,
                          hintStyle: TextStyle(
                            color: isDark
                                ? BrandColors.nightTextSecondary
                                : BrandColors.driftwood,
                            fontSize: TypographyTokens.bodyMedium,
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: Spacing.md,
                            vertical: Spacing.sm,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: Spacing.sm),

                // Send or Stop button
                AnimatedContainer(
                  duration: Motion.quick,
                  curve: Motion.settling,
                  child: widget.isStreaming
                      ? IconButton(
                          onPressed: widget.onStop,
                          style: IconButton.styleFrom(
                            backgroundColor: isDark
                                ? BrandColors.nightForest
                                : BrandColors.forest,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: Radii.button,
                            ),
                          ),
                          icon: const Icon(Icons.stop_rounded, size: 20),
                          tooltip: 'Stop generating',
                        )
                      : IconButton(
                          onPressed: ((_hasText || _attachments.isNotEmpty) && widget.enabled && !isRecording && !isTranscribing)
                              ? _handleSend
                              : null,
                          style: IconButton.styleFrom(
                            backgroundColor: ((_hasText || _attachments.isNotEmpty) && widget.enabled && !isRecording && !isTranscribing)
                                ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                                : (isDark
                                    ? BrandColors.nightSurfaceElevated
                                    : BrandColors.stone),
                            foregroundColor: ((_hasText || _attachments.isNotEmpty) && widget.enabled && !isRecording && !isTranscribing)
                                ? Colors.white
                                : (isDark
                                    ? BrandColors.nightTextSecondary
                                    : BrandColors.driftwood),
                            shape: RoundedRectangleBorder(
                              borderRadius: Radii.button,
                            ),
                          ),
                          icon: const Icon(Icons.send_rounded, size: 20),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceButton(bool isDark, bool isRecording, bool isTranscribing) {
    // Show loading spinner when transcribing
    if (isTranscribing) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
          borderRadius: Radii.button,
        ),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
          ),
        ),
      );
    }

    // Pulsing mic button when recording
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        final scale = isRecording ? 1.0 + (_pulseController.value * 0.1) : 1.0;
        return Transform.scale(
          scale: scale,
          child: IconButton(
            onPressed: widget.enabled ? _handleVoiceInput : null,
            style: IconButton.styleFrom(
              backgroundColor: isRecording
                  ? BrandColors.error
                  : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone),
              foregroundColor: isRecording
                  ? Colors.white
                  : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
              shape: RoundedRectangleBorder(
                borderRadius: Radii.button,
              ),
            ),
            icon: Icon(
              isRecording ? Icons.stop_rounded : Icons.mic_rounded,
              size: 20,
            ),
            tooltip: isRecording ? 'Stop recording' : 'Voice input',
          ),
        );
      },
    );
  }

  Widget _buildRecordingIndicator(bool isDark, Duration duration) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Pulsing red dot
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final opacity = 0.5 + (_pulseController.value * 0.5);
              return Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: BrandColors.error.withValues(alpha: opacity),
                  shape: BoxShape.circle,
                ),
              );
            },
          ),
          const SizedBox(width: Spacing.sm),
          Text(
            'Recording ${_formatDuration(duration)}',
            style: TextStyle(
              color: BrandColors.error,
              fontSize: TypographyTokens.labelMedium,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTranscribingIndicator(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Text(
            'Transcribing...',
            style: TextStyle(
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              fontSize: TypographyTokens.labelMedium,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// Build streaming transcript display with real-time feedback
  Widget _buildStreamingTranscriptDisplay(bool isDark, StreamingTranscriptionState state) {
    final hasConfirmed = state.confirmedSegments.isNotEmpty;
    final hasInterim = state.interimText != null && state.interimText!.isNotEmpty;
    final hasText = hasConfirmed || hasInterim;

    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated.withValues(alpha: 0.5)
            : BrandColors.cream.withValues(alpha: 0.5),
        borderRadius: Radii.card,
        border: Border.all(
          color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with recording status and duration
          Row(
            children: [
              // Pulsing red dot
              AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  final opacity = 0.5 + (_pulseController.value * 0.5);
                  return Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: BrandColors.error.withValues(alpha: opacity),
                      shape: BoxShape.circle,
                    ),
                  );
                },
              ),
              const SizedBox(width: Spacing.xs),
              Text(
                _formatDuration(state.recordingDuration),
                style: TextStyle(
                  color: BrandColors.error,
                  fontSize: TypographyTokens.labelSmall,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              // Model status indicator
              _buildModelStatusIndicator(isDark, state.modelStatus),
            ],
          ),

          // Transcript content
          if (hasText) ...[
            const SizedBox(height: Spacing.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 120),
              child: SingleChildScrollView(
                reverse: true, // Auto-scroll to bottom
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      fontSize: TypographyTokens.bodyMedium,
                      height: 1.4,
                    ),
                    children: [
                      // Confirmed segments (solid text)
                      if (hasConfirmed)
                        TextSpan(text: state.confirmedSegments.join(' ')),

                      // Interim text (gray, italic)
                      if (hasInterim) ...[
                        if (hasConfirmed) const TextSpan(text: ' '),
                        TextSpan(
                          text: state.interimText!,
                          style: TextStyle(
                            color: isDark
                                ? BrandColors.nightTextSecondary
                                : BrandColors.driftwood,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ] else ...[
            const SizedBox(height: Spacing.xs),
            Text(
              state.modelStatus == TranscriptionModelStatus.initializing
                  ? 'Initializing transcription...'
                  : 'Listening...',
              style: TextStyle(
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
                fontSize: TypographyTokens.bodySmall,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Build model status indicator
  Widget _buildModelStatusIndicator(bool isDark, TranscriptionModelStatus status) {
    String text;
    Color color;
    bool showSpinner = false;

    switch (status) {
      case TranscriptionModelStatus.notInitialized:
      case TranscriptionModelStatus.initializing:
        text = 'Initializing...';
        color = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
        showSpinner = true;
        break;
      case TranscriptionModelStatus.ready:
        text = 'Listening';
        color = isDark ? BrandColors.nightForest : BrandColors.forest;
        break;
      case TranscriptionModelStatus.error:
        text = 'Error';
        color = BrandColors.error;
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSpinner) ...[
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: color,
            ),
          ),
          const SizedBox(width: Spacing.xs),
        ],
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: TypographyTokens.labelSmall,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// Build finalizing indicator (shown while processing stop)
  Widget _buildFinalizingIndicator(bool isDark, StreamingTranscriptionState state) {
    final hasText = state.confirmedSegments.isNotEmpty ||
        (state.interimText != null && state.interimText!.isNotEmpty);

    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated.withValues(alpha: 0.5)
            : BrandColors.cream.withValues(alpha: 0.5),
        borderRadius: Radii.card,
        border: Border.all(
          color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with finalizing status
          Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                'Finalizing...',
                style: TextStyle(
                  color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                  fontSize: TypographyTokens.labelSmall,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),

          // Show the transcript captured so far
          if (hasText) ...[
            const SizedBox(height: Spacing.xs),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 80),
              child: SingleChildScrollView(
                reverse: true,
                child: Text(
                  state.displayText,
                  style: TextStyle(
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    fontSize: TypographyTokens.bodyMedium,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAttachmentButton(bool isDark, bool isRecording, bool isTranscribing) {
    if (_isLoadingAttachment) {
      return Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
          borderRadius: Radii.button,
        ),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
          ),
        ),
      );
    }

    return IconButton(
      onPressed: (widget.enabled && !isRecording && !isTranscribing)
          ? _handleAttachment
          : null,
      style: IconButton.styleFrom(
        backgroundColor: _attachments.isNotEmpty
            ? (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
            : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone),
        foregroundColor: _attachments.isNotEmpty
            ? Colors.white
            : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
        shape: RoundedRectangleBorder(
          borderRadius: Radii.button,
        ),
      ),
      icon: Badge(
        isLabelVisible: _attachments.isNotEmpty,
        label: Text('${_attachments.length}'),
        child: const Icon(Icons.attach_file_rounded, size: 20),
      ),
      tooltip: 'Attach files',
    );
  }

  Widget _buildAttachmentPreviews(bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.sm),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: _attachments.asMap().entries.map((entry) {
            final index = entry.key;
            final attachment = entry.value;
            return _buildAttachmentChip(isDark, attachment, index);
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildAttachmentChip(bool isDark, ChatAttachment attachment, int index) {
    final isImage = attachment.type == AttachmentType.image;

    return Container(
      margin: const EdgeInsets.only(right: Spacing.sm),
      child: Material(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.cream,
        borderRadius: Radii.badge,
        child: InkWell(
          borderRadius: Radii.badge,
          onTap: () {
            // Could show preview dialog in the future
          },
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.sm,
              vertical: Spacing.xs,
            ),
            decoration: BoxDecoration(
              border: Border.all(
                color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
              ),
              borderRadius: Radii.badge,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Thumbnail or icon
                if (isImage && attachment.base64Data != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(
                      attachment.bytes!,
                      width: 32,
                      height: 32,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildFileIcon(attachment, isDark),
                    ),
                  )
                else
                  _buildFileIcon(attachment, isDark),

                const SizedBox(width: Spacing.xs),

                // File name and size
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        attachment.fileName,
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        attachment.formattedSize,
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall - 2,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: Spacing.xs),

                // Remove button
                InkWell(
                  onTap: () => _removeAttachment(index),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileIcon(ChatAttachment attachment, bool isDark) {
    IconData icon;
    Color color;

    switch (attachment.type) {
      case AttachmentType.image:
        icon = Icons.image_rounded;
        color = BrandColors.turquoise;
        break;
      case AttachmentType.pdf:
        icon = Icons.picture_as_pdf_rounded;
        color = BrandColors.error;
        break;
      case AttachmentType.text:
        icon = Icons.article_rounded;
        color = BrandColors.forest;
        break;
      case AttachmentType.code:
        icon = Icons.code_rounded;
        color = BrandColors.warning;
        break;
      case AttachmentType.archive:
        icon = Icons.folder_zip_rounded;
        color = BrandColors.turquoise;
        break;
      case AttachmentType.audio:
        icon = Icons.audio_file_rounded;
        color = BrandColors.forest;
        break;
      case AttachmentType.video:
        icon = Icons.video_file_rounded;
        color = BrandColors.warning;
        break;
      case AttachmentType.unknown:
        icon = Icons.insert_drive_file_rounded;
        color = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
        break;
    }

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}
