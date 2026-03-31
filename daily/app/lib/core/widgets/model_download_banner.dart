import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/model_download_provider.dart';
import '../services/model_download_service.dart';
import '../theme/design_tokens.dart';

/// Banner showing transcription model download progress
///
/// Only visible on Android when models are being downloaded.
/// Shows download progress and hides automatically when complete.
class ModelDownloadBanner extends ConsumerWidget {
  const ModelDownloadBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only show on Android
    if (!Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    final stateAsync = ref.watch(modelDownloadStateProvider);

    return stateAsync.when(
      data: (state) => _buildBanner(context, ref, state),
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildBanner(BuildContext context, WidgetRef ref, ModelDownloadState state) {
    // Don't show if ready or not started
    if (state.isReady || state.status == ModelDownloadStatus.notStarted) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Show error banner
    if (state.status == ModelDownloadStatus.failed) {
      return Material(
        color: isDark ? Colors.red.shade900 : Colors.red.shade50,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: isDark ? Colors.red.shade300 : Colors.red.shade700,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Voice model download failed',
                    style: TextStyle(
                      color: isDark ? Colors.red.shade300 : Colors.red.shade700,
                      fontSize: 14,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    ref.read(modelDownloadServiceProvider).startDownload();
                  },
                  child: Text(
                    'Retry',
                    style: TextStyle(
                      color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Show progress banner
    return Material(
      color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.turquoise.withValues(alpha: 0.1),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      state.statusMessage ?? 'Downloading voice model...',
                      style: TextStyle(
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Text(
                    state.progressText,
                    style: TextStyle(
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: state.progress,
                  backgroundColor: isDark
                      ? BrandColors.nightSurfaceElevated
                      : BrandColors.turquoise.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                  ),
                  minHeight: 4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
