import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/services/transcription/parakeet_service.dart';
import 'package:parachute/core/services/transcription/sherpa_onnx_service.dart';
import 'package:parachute/core/services/transcription/sherpa_onnx_isolate.dart';
import 'package:parachute/core/providers/core_service_providers.dart';

/// Initialization phase for transcription models
enum TranscriptionInitPhase {
  /// Initial state, not yet checked
  unknown,

  /// Checking if models are downloaded
  checking,

  /// Models not downloaded, waiting for user action
  notDownloaded,

  /// Currently downloading models
  downloading,

  /// Extracting downloaded archive (Android only)
  extracting,

  /// Initializing the recognizer
  initializing,

  /// Ready to transcribe
  ready,

  /// Initialization failed
  failed,
}

/// State for transcription initialization
class TranscriptionInitState {
  final TranscriptionInitPhase phase;
  final double progress; // 0.0 to 1.0
  final String statusMessage;
  final String? errorMessage;
  final String? engineName;
  final DateTime? lastChecked;

  const TranscriptionInitState({
    this.phase = TranscriptionInitPhase.unknown,
    this.progress = 0.0,
    this.statusMessage = '',
    this.errorMessage,
    this.engineName,
    this.lastChecked,
  });

  TranscriptionInitState copyWith({
    TranscriptionInitPhase? phase,
    double? progress,
    String? statusMessage,
    String? errorMessage,
    String? engineName,
    DateTime? lastChecked,
  }) {
    return TranscriptionInitState(
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      statusMessage: statusMessage ?? this.statusMessage,
      errorMessage: errorMessage,
      engineName: engineName ?? this.engineName,
      lastChecked: lastChecked ?? this.lastChecked,
    );
  }

  /// Whether transcription is ready to use
  bool get isReady => phase == TranscriptionInitPhase.ready;

  /// Whether we're currently downloading or initializing
  bool get isInProgress =>
      phase == TranscriptionInitPhase.downloading ||
      phase == TranscriptionInitPhase.extracting ||
      phase == TranscriptionInitPhase.initializing ||
      phase == TranscriptionInitPhase.checking;

  /// Whether download/init failed
  bool get hasFailed => phase == TranscriptionInitPhase.failed;

  /// Whether models need to be downloaded
  bool get needsDownload => phase == TranscriptionInitPhase.notDownloaded;

  /// User-friendly status text
  String get userFriendlyStatus {
    switch (phase) {
      case TranscriptionInitPhase.unknown:
        return 'Checking transcription models...';
      case TranscriptionInitPhase.checking:
        return 'Checking transcription models...';
      case TranscriptionInitPhase.notDownloaded:
        return 'Transcription models not downloaded';
      case TranscriptionInitPhase.downloading:
        final percent = (progress * 100).toInt();
        return 'Downloading models ($percent%)...';
      case TranscriptionInitPhase.extracting:
        return 'Extracting models...';
      case TranscriptionInitPhase.initializing:
        return 'Initializing transcription engine...';
      case TranscriptionInitPhase.ready:
        return 'Ready';
      case TranscriptionInitPhase.failed:
        return errorMessage ?? 'Initialization failed';
    }
  }
}

/// Notifier for transcription initialization state
///
/// This is the single source of truth for transcription readiness.
/// It persists across navigation and handles all platforms.
class TranscriptionInitNotifier extends StateNotifier<TranscriptionInitState> {
  final ParakeetService _parakeetService = ParakeetService();
  final SherpaOnnxService _sherpaService = SherpaOnnxService();
  final SherpaOnnxIsolate _sherpaIsolate;

  TranscriptionInitNotifier(this._sherpaIsolate) : super(const TranscriptionInitState()) {
    // Check status on creation
    checkStatus();
  }

  /// Check current initialization status
  Future<void> checkStatus() async {
    if (state.isInProgress) {
      debugPrint('[TranscriptionInit] Check skipped - operation in progress');
      return;
    }

    state = state.copyWith(
      phase: TranscriptionInitPhase.checking,
      statusMessage: 'Checking models...',
    );

    try {
      // Check if already initialized
      if (_sherpaIsolate.isInitialized) {
        state = TranscriptionInitState(
          phase: TranscriptionInitPhase.ready,
          progress: 1.0,
          statusMessage: 'Ready',
          engineName: 'Parakeet v3 (Sherpa-ONNX)',
          lastChecked: DateTime.now(),
        );
        return;
      }

      if (_parakeetService.isInitialized) {
        state = TranscriptionInitState(
          phase: TranscriptionInitPhase.ready,
          progress: 1.0,
          statusMessage: 'Ready',
          engineName: 'Parakeet v3 (FluidAudio)',
          lastChecked: DateTime.now(),
        );
        return;
      }

      // Check if models are downloaded
      bool modelsDownloaded = false;

      if (Platform.isIOS || Platform.isMacOS) {
        modelsDownloaded = await _parakeetService.areModelsDownloaded();
      } else {
        modelsDownloaded = await _sherpaService.hasModelsDownloaded;
      }

      if (modelsDownloaded) {
        // Models exist but not initialized
        // Don't auto-initialize here to avoid crashes on startup with corrupted models
        // User can trigger initialization explicitly when they start recording
        state = TranscriptionInitState(
          phase: TranscriptionInitPhase.notDownloaded, // Treat as needing init
          progress: 0.0,
          statusMessage: 'Models downloaded, tap to initialize',
          lastChecked: DateTime.now(),
        );
      } else {
        state = TranscriptionInitState(
          phase: TranscriptionInitPhase.notDownloaded,
          progress: 0.0,
          statusMessage: 'Models not downloaded',
          lastChecked: DateTime.now(),
        );
      }
    } catch (e) {
      debugPrint('[TranscriptionInit] Check failed: $e');
      state = TranscriptionInitState(
        phase: TranscriptionInitPhase.failed,
        errorMessage: 'Failed to check status: $e',
        lastChecked: DateTime.now(),
      );
    }
  }

  /// Download and initialize transcription models
  Future<bool> downloadAndInitialize() async {
    if (state.isInProgress) {
      debugPrint('[TranscriptionInit] Download skipped - already in progress');
      return false;
    }

    if (state.isReady) {
      debugPrint('[TranscriptionInit] Already ready');
      return true;
    }

    state = state.copyWith(
      phase: TranscriptionInitPhase.downloading,
      progress: 0.0,
      statusMessage: 'Starting download...',
      errorMessage: null,
    );

    try {
      if (Platform.isIOS || Platform.isMacOS) {
        await _initializeParakeet();
      } else {
        await _initializeSherpaOnnx();
      }
      return true;
    } catch (e) {
      debugPrint('[TranscriptionInit] Download/init failed: $e');
      state = TranscriptionInitState(
        phase: TranscriptionInitPhase.failed,
        errorMessage: _friendlyErrorMessage(e),
        lastChecked: DateTime.now(),
      );
      return false;
    }
  }

  /// Initialize engine only (models already downloaded)
  Future<void> _initializeEngine() async {
    state = state.copyWith(
      phase: TranscriptionInitPhase.initializing,
      progress: 0.9,
      statusMessage: 'Initializing engine...',
    );

    try {
      if (Platform.isIOS || Platform.isMacOS) {
        await _parakeetService.initialize(version: 'v3');
        state = TranscriptionInitState(
          phase: TranscriptionInitPhase.ready,
          progress: 1.0,
          statusMessage: 'Ready',
          engineName: 'Parakeet v3 (FluidAudio)',
          lastChecked: DateTime.now(),
        );
      } else {
        await _sherpaIsolate.initialize(
          onProgress: (p) => state = state.copyWith(progress: 0.9 + p * 0.1),
          onStatus: (s) => state = state.copyWith(statusMessage: s),
        );
        state = TranscriptionInitState(
          phase: TranscriptionInitPhase.ready,
          progress: 1.0,
          statusMessage: 'Ready',
          engineName: 'Parakeet v3 (Sherpa-ONNX)',
          lastChecked: DateTime.now(),
        );
      }
    } catch (e) {
      debugPrint('[TranscriptionInit] Engine init failed: $e');
      state = TranscriptionInitState(
        phase: TranscriptionInitPhase.failed,
        errorMessage: _friendlyErrorMessage(e),
        lastChecked: DateTime.now(),
      );
    }
  }

  /// Initialize Parakeet via FluidAudio (iOS/macOS)
  Future<void> _initializeParakeet() async {
    // FluidAudio doesn't provide progress, use indeterminate
    state = state.copyWith(
      phase: TranscriptionInitPhase.downloading,
      progress: -1.0, // -1 indicates indeterminate
      statusMessage: 'Downloading models...',
    );

    await _parakeetService.initialize(version: 'v3');

    state = TranscriptionInitState(
      phase: TranscriptionInitPhase.ready,
      progress: 1.0,
      statusMessage: 'Ready',
      engineName: 'Parakeet v3 (FluidAudio)',
      lastChecked: DateTime.now(),
    );
  }

  /// Initialize Sherpa-ONNX (Android/cross-platform)
  Future<void> _initializeSherpaOnnx() async {
    await _sherpaIsolate.initialize(
      onProgress: (progress) {
        // Map progress to phases
        TranscriptionInitPhase phase;
        if (progress < 0.7) {
          phase = TranscriptionInitPhase.downloading;
        } else if (progress < 0.85) {
          phase = TranscriptionInitPhase.extracting;
        } else {
          phase = TranscriptionInitPhase.initializing;
        }

        state = state.copyWith(
          phase: phase,
          progress: progress,
        );
      },
      onStatus: (status) {
        state = state.copyWith(statusMessage: status);
      },
    );

    state = TranscriptionInitState(
      phase: TranscriptionInitPhase.ready,
      progress: 1.0,
      statusMessage: 'Ready',
      engineName: 'Parakeet v3 (Sherpa-ONNX)',
      lastChecked: DateTime.now(),
    );
  }

  /// Reset to allow retry after failure
  void reset() {
    state = const TranscriptionInitState(
      phase: TranscriptionInitPhase.notDownloaded,
    );
  }

  /// Convert exception to user-friendly message
  String _friendlyErrorMessage(dynamic error) {
    final message = error.toString();

    if (message.contains('SocketException') ||
        message.contains('Connection refused') ||
        message.contains('Network is unreachable')) {
      return 'Network error. Please check your internet connection and try again.';
    }

    if (message.contains('No space left') ||
        message.contains('not enough space')) {
      return 'Not enough storage space. Please free up at least 700MB and try again.';
    }

    if (message.contains('Permission denied')) {
      return 'Permission denied. Please check app permissions.';
    }

    if (message.contains('timeout') || message.contains('Timeout')) {
      return 'Download timed out. Please try again.';
    }

    // Generic fallback
    return 'Failed to initialize: ${message.length > 100 ? '${message.substring(0, 100)}...' : message}';
  }
}

/// Provider for transcription initialization state
///
/// Uses keepAlive to persist across navigation.
final transcriptionInitProvider =
    StateNotifierProvider<TranscriptionInitNotifier, TranscriptionInitState>(
  (ref) {
    final sherpaIsolate = ref.watch(sherpaOnnxIsolateProvider);
    final notifier = TranscriptionInitNotifier(sherpaIsolate);
    // Keep alive to persist across navigation
    ref.keepAlive();
    return notifier;
  },
);

/// Convenience provider to check if transcription is ready
final isTranscriptionReadyProvider = Provider<bool>((ref) {
  return ref.watch(transcriptionInitProvider).isReady;
});

/// Convenience provider to check if download is in progress
final isTranscriptionDownloadingProvider = Provider<bool>((ref) {
  return ref.watch(transcriptionInitProvider).isInProgress;
});
