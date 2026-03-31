import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/model_download_service.dart';

/// Provider for the ModelDownloadService singleton
final modelDownloadServiceProvider = Provider<ModelDownloadService>((ref) {
  final service = ModelDownloadService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Check if models are ready on disk (async check)
/// This provider caches the result and re-checks when stream updates
final modelsReadyOnDiskProvider = FutureProvider<bool>((ref) async {
  // Only relevant on Android
  if (!Platform.isAndroid) return true;

  final service = ref.watch(modelDownloadServiceProvider);
  return await service.areModelsReady();
});

/// Stream provider for model download state
final modelDownloadStateProvider = StreamProvider<ModelDownloadState>((ref) {
  final service = ref.watch(modelDownloadServiceProvider);
  return service.stateStream;
});

/// Provider for current model download state (synchronous access)
/// Returns the stream state if available, otherwise checks disk directly
final modelDownloadCurrentStateProvider = Provider<ModelDownloadState>((ref) {
  final streamState = ref.watch(modelDownloadStateProvider);
  final diskCheck = ref.watch(modelsReadyOnDiskProvider);

  return streamState.when(
    data: (state) => state,
    loading: () {
      // While stream is loading, check disk directly
      return diskCheck.when(
        data: (ready) => ready
            ? const ModelDownloadState(status: ModelDownloadStatus.ready, progress: 1.0)
            : const ModelDownloadState(status: ModelDownloadStatus.notStarted),
        loading: () => const ModelDownloadState(status: ModelDownloadStatus.notStarted), // Treat as not ready while checking
        error: (_, __) => const ModelDownloadState(status: ModelDownloadStatus.notStarted),
      );
    },
    error: (_, __) => const ModelDownloadState(status: ModelDownloadStatus.failed),
  );
});

/// Async function to check if models are ready (for use before recording starts)
///
/// This MUST be awaited before attempting to use transcription on Android.
/// It provides a definitive answer by checking the actual files on disk.
Future<bool> checkModelsReady() async {
  if (!Platform.isAndroid) return true;
  final service = ModelDownloadService();
  return await service.areModelsReady();
}

/// Whether transcription models are ready to use
final transcriptionModelsReadyProvider = Provider<bool>((ref) {
  final state = ref.watch(modelDownloadCurrentStateProvider);
  return state.isReady;
});

/// Whether model download is in progress
final isDownloadingModelsProvider = Provider<bool>((ref) {
  final state = ref.watch(modelDownloadCurrentStateProvider);
  return state.isDownloading;
});

/// Whether models need to be downloaded
final needsModelDownloadProvider = Provider<bool>((ref) {
  final state = ref.watch(modelDownloadCurrentStateProvider);
  return state.needsDownload;
});
