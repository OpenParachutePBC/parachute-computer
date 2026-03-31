import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/transcription_init_provider.dart';

/// Dialog shown when user tries to transcribe before models are ready
class TranscriptionNotReadyDialog extends ConsumerStatefulWidget {
  const TranscriptionNotReadyDialog({super.key});

  /// Show the dialog and return true if user chose to download/wait
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const TranscriptionNotReadyDialog(),
    );
    return result ?? false;
  }

  @override
  ConsumerState<TranscriptionNotReadyDialog> createState() =>
      _TranscriptionNotReadyDialogState();
}

class _TranscriptionNotReadyDialogState
    extends ConsumerState<TranscriptionNotReadyDialog> {
  @override
  Widget build(BuildContext context) {
    final initState = ref.watch(transcriptionInitProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Auto-close when ready
    if (initState.isReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop(true);
      });
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            _getIcon(initState),
            color: _getColor(initState),
            size: 28,
          ),
          SizedBox(width: Spacing.md),
          Text(_getTitle(initState)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _getMessage(initState),
            style: TextStyle(
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),

          // Show progress when downloading
          if (initState.isInProgress) ...[
            SizedBox(height: Spacing.lg),
            _buildProgressIndicator(initState),
          ],

          // Show error message if failed
          if (initState.hasFailed && initState.errorMessage != null) ...[
            SizedBox(height: Spacing.md),
            Container(
              padding: EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(
                color: BrandColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                initState.errorMessage!,
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: BrandColors.error,
                ),
              ),
            ),
          ],
        ],
      ),
      actions: _buildActions(initState),
    );
  }

  IconData _getIcon(TranscriptionInitState state) {
    if (state.isInProgress) return Icons.downloading;
    if (state.hasFailed) return Icons.error_outline;
    return Icons.cloud_download;
  }

  Color _getColor(TranscriptionInitState state) {
    if (state.isInProgress) return BrandColors.turquoise;
    if (state.hasFailed) return BrandColors.error;
    return BrandColors.warning;
  }

  String _getTitle(TranscriptionInitState state) {
    if (state.isInProgress) return 'Downloading...';
    if (state.hasFailed) return 'Download Failed';
    return 'Models Required';
  }

  String _getMessage(TranscriptionInitState state) {
    if (state.isInProgress) {
      return 'Please wait while the transcription models are being downloaded. '
          'This only needs to happen once.';
    }
    if (state.hasFailed) {
      return 'The model download failed. Please check your internet connection and try again.';
    }
    return 'Transcription requires downloading the Parakeet speech recognition models (~500MB). '
        'Would you like to download them now?';
  }

  List<Widget> _buildActions(TranscriptionInitState state) {
    if (state.isInProgress) {
      return [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ];
    }

    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Not Now'),
      ),
      FilledButton(
        onPressed: _startDownload,
        style: FilledButton.styleFrom(
          backgroundColor: BrandColors.turquoise,
        ),
        child: Text(state.hasFailed ? 'Retry' : 'Download Now'),
      ),
    ];
  }

  void _startDownload() {
    ref.read(transcriptionInitProvider.notifier).downloadAndInitialize();
  }

  Widget _buildProgressIndicator(TranscriptionInitState state) {
    final isIndeterminate = state.progress < 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isIndeterminate)
          const LinearProgressIndicator(
            backgroundColor: BrandColors.stone,
            valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
          )
        else
          LinearProgressIndicator(
            value: state.progress,
            backgroundColor: BrandColors.stone,
            valueColor: const AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
          ),
        SizedBox(height: Spacing.sm),
        Text(
          state.statusMessage.isNotEmpty
              ? state.statusMessage
              : state.userFriendlyStatus,
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: BrandColors.turquoise,
          ),
        ),
        if (!isIndeterminate) ...[
          SizedBox(height: Spacing.xs),
          Text(
            '${(state.progress * 100).toStringAsFixed(0)}% complete',
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: BrandColors.driftwood,
            ),
          ),
        ],
      ],
    );
  }
}
