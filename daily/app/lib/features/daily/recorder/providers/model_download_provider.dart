import 'package:flutter_riverpod/flutter_riverpod.dart';

/// State for model download progress
class ModelDownloadState {
  final bool isDownloading;
  final double progress;
  final String status;

  const ModelDownloadState({
    this.isDownloading = false,
    this.progress = 0.0,
    this.status = '',
  });

  ModelDownloadState copyWith({
    bool? isDownloading,
    double? progress,
    String? status,
  }) {
    return ModelDownloadState(
      isDownloading: isDownloading ?? this.isDownloading,
      progress: progress ?? this.progress,
      status: status ?? this.status,
    );
  }
}

/// Notifier for model download state
class ModelDownloadNotifier extends StateNotifier<ModelDownloadState> {
  ModelDownloadNotifier() : super(const ModelDownloadState());

  // Callback to notify when models are ready
  Function()? onModelsReady;

  void startDownload() {
    state = state.copyWith(isDownloading: true, progress: 0.0);
  }

  void updateProgress(double progress, String status) {
    state = state.copyWith(progress: progress, status: status);
  }

  void complete() {
    state = const ModelDownloadState();

    // Notify that models are ready
    if (onModelsReady != null) {
      onModelsReady!();
    }
  }
}

/// Provider for model download state
final modelDownloadProvider =
    StateNotifierProvider<ModelDownloadNotifier, ModelDownloadState>(
      (ref) => ModelDownloadNotifier(),
    );
