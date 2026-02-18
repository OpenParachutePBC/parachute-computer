import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/streaming_transcription_provider.dart';
import '../services/live_transcription_service_v3.dart';

/// Displays streaming transcription during recording
///
/// Shows confirmed text (finalized) and interim text (being transcribed)
/// with visual distinction between the two states.
class StreamingTranscriptionDisplay extends ConsumerWidget {
  final double maxHeight;
  final EdgeInsets padding;

  const StreamingTranscriptionDisplay({
    super.key,
    this.maxHeight = 200,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streamingState = ref.watch(streamingTranscriptionProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return streamingState.when(
      data: (state) => _buildContent(context, state, isDark),
      loading: () => const SizedBox.shrink(),
      error: (e, st) => Padding(
        padding: padding,
        child: Text(
          'Live transcription unavailable',
          style: TextStyle(
            color: BrandColors.error,
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    StreamingTranscriptionState state,
    bool isDark,
  ) {
    // Don't show if not recording and no text
    if (!state.isRecording &&
        state.confirmedSegments.isEmpty &&
        (state.interimText == null || state.interimText!.isEmpty)) {
      return const SizedBox.shrink();
    }

    final hasConfirmed = state.confirmedSegments.isNotEmpty;
    final hasInterim = state.interimText != null && state.interimText!.isNotEmpty;

    if (!hasConfirmed && !hasInterim) {
      // Show placeholder during recording
      if (state.isRecording) {
        return _buildPlaceholder(context, isDark);
      }
      return const SizedBox.shrink();
    }

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      padding: padding,
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightSurfaceElevated.withValues(alpha: 0.5)
            : BrandColors.cream.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: SingleChildScrollView(
        reverse: true, // Keep newest content visible
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Confirmed segments
            if (hasConfirmed)
              Text(
                state.confirmedSegments.join('\n\n'),
                style: TextStyle(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontSize: 16,
                  height: 1.5,
                ),
              ),

            // Interim text (grayed, italic)
            if (hasInterim) ...[
              if (hasConfirmed) const SizedBox(height: 8),
              Text(
                state.interimText!,
                style: TextStyle(
                  color: isDark
                      ? BrandColors.driftwood
                      : BrandColors.charcoal.withValues(alpha: 0.7),
                  fontSize: 16,
                  height: 1.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context, bool isDark) {
    return Container(
      padding: padding,
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(BrandColors.driftwood),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Listening...',
            style: TextStyle(
              color: BrandColors.driftwood,
              fontSize: 14,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact VAD indicator showing speech detection level
class VadIndicator extends ConsumerWidget {
  final double size;

  const VadIndicator({super.key, this.size = 24});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vadActivity = ref.watch(vadActivityProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return vadActivity.when(
      data: (isSpeaking) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: size,
        height: size,
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
            width: isSpeaking ? size * 0.6 : size * 0.4,
            height: isSpeaking ? size * 0.6 : size * 0.4,
            decoration: BoxDecoration(
              color: isSpeaking ? BrandColors.forest : BrandColors.driftwood,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
      loading: () => SizedBox(width: size, height: size),
      error: (e, st) => SizedBox(width: size, height: size),
    );
  }
}

/// Recording header with duration and VAD indicator
class StreamingRecordingHeader extends ConsumerWidget {
  const StreamingRecordingHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordingState = ref.watch(streamingRecordingProvider);

    if (!recordingState.isRecording) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: BrandColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          // Recording indicator
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
            recordingState.durationText,
            style: TextStyle(
              color: BrandColors.error,
              fontSize: 18,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),

          const Spacer(),

          // VAD indicator
          const VadIndicator(size: 28),
        ],
      ),
    );
  }
}

/// Full streaming recording UI that takes over during recording
///
/// Combines header, transcription display, and controls into a cohesive
/// recording experience with real-time transcription feedback.
class StreamingRecordingOverlay extends ConsumerWidget {
  final VoidCallback onStop;
  final VoidCallback onCancel;

  const StreamingRecordingOverlay({
    super.key,
    required this.onStop,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordingState = ref.watch(streamingRecordingProvider);
    final theme = Theme.of(context);
    final isDarkTheme = theme.brightness == Brightness.dark;

    if (!recordingState.isRecording) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDarkTheme ? BrandColors.nightSurface : BrandColors.softWhite,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with duration and VAD
            const StreamingRecordingHeader(),
            const SizedBox(height: 16),

            // Transcription display
            const StreamingTranscriptionDisplay(
              maxHeight: 200,
              padding: EdgeInsets.all(12),
            ),
            const SizedBox(height: 16),

            // Controls
            Row(
              children: [
                // Cancel button
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: onCancel,
                      icon: Icon(Icons.close, size: 20, color: BrandColors.driftwood),
                      label: Text(
                        'Cancel',
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
                const SizedBox(width: 16),

                // Stop/Save button
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: onStop,
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
        ),
      ),
    );
  }
}
