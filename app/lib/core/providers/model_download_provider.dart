import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/model_download_service.dart';

/// Provider for the ModelDownloadService singleton
final modelDownloadServiceProvider = Provider<ModelDownloadService>((ref) {
  final service = ModelDownloadService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Stream provider for model download state
final modelDownloadStateProvider = StreamProvider<ModelDownloadState>((ref) {
  final service = ref.watch(modelDownloadServiceProvider);
  return service.stateStream;
});

/// Provider for current model download state (synchronous access)
final modelDownloadCurrentStateProvider = Provider<ModelDownloadState>((ref) {
  return ref.watch(modelDownloadStateProvider).when(
    data: (state) => state,
    loading: () => const ModelDownloadState(),
    error: (_, __) => const ModelDownloadState(status: ModelDownloadStatus.failed),
  );
});

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
