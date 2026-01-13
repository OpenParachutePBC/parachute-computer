import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:parachute/core/services/transcription/parakeet_service.dart';
import 'package:parachute/core/services/transcription/sherpa_onnx_service.dart';
import 'package:parachute/core/services/transcription/sherpa_onnx_isolate.dart';

/// Platform-adaptive transcription service using Parakeet v3
///
/// Uses Parakeet via different implementations:
/// - iOS/macOS: FluidAudio (CoreML-based, Apple Neural Engine)
/// - Android: Sherpa-ONNX (ONNX Runtime-based)
///
/// This provides fast, offline transcription with 25-language support.
class TranscriptionServiceAdapter {
  final ParakeetService _parakeetService = ParakeetService();
  // Use isolate-based service for Sherpa-ONNX to prevent UI blocking
  final SherpaOnnxIsolate _sherpaIsolate = SherpaOnnxIsolate.instance;
  // Keep direct service reference for compatibility checks
  final SherpaOnnxService _sherpaService = SherpaOnnxService();

  // Global progress callbacks (set by main.dart)
  static Function(double)? _globalOnProgress;
  static Function(String)? _globalOnStatus;

  // Progress tracking
  final _transcriptionProgressController =
      StreamController<TranscriptionProgress>.broadcast();

  Stream<TranscriptionProgress> get transcriptionProgressStream =>
      _transcriptionProgressController.stream;

  /// Set global progress callbacks for initialization
  static void setGlobalProgressCallbacks({
    Function(double)? onProgress,
    Function(String)? onStatus,
  }) {
    _globalOnProgress = onProgress;
    _globalOnStatus = onStatus;
  }

  bool get isUsingParakeet =>
      _sherpaService.isSupported || _parakeetService.isSupported;

  String get engineName {
    if (_sherpaIsolate.isInitialized) {
      return 'Parakeet v3 (Sherpa-ONNX)';
    } else if (_parakeetService.isSupported && _parakeetService.isInitialized) {
      return 'Parakeet v3 (FluidAudio)';
    } else {
      return 'Parakeet v3';
    }
  }

  /// Initialize the transcription service
  ///
  /// Platform-specific strategy:
  /// - iOS/macOS: Prefer FluidAudio (faster, CoreML-optimized)
  /// - Android: Use Sherpa-ONNX (cross-platform ONNX)
  ///
  /// [onProgress] - Optional callback for initialization progress (0.0-1.0)
  /// [onStatus] - Optional callback for status messages
  Future<void> initialize({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    // iOS/macOS: Prefer FluidAudio for faster initialization
    if (_parakeetService.isSupported) {
      debugPrint(
        '[TranscriptionAdapter] Initializing Parakeet (FluidAudio)...',
      );
      onStatus?.call('Initializing Parakeet (FluidAudio)...');
      try {
        await _parakeetService.initialize(version: 'v3');
        debugPrint('[TranscriptionAdapter] ✅ Parakeet (FluidAudio) ready');
        onProgress?.call(1.0);
        onStatus?.call('Ready');
        return;
      } catch (e) {
        debugPrint('[TranscriptionAdapter] ⚠️ FluidAudio init failed: $e');
        // Continue to Sherpa-ONNX fallback if available
      }
    }

    // Android (or fallback): Use Sherpa-ONNX via background isolate
    if (_sherpaService.isSupported) {
      debugPrint(
        '[TranscriptionAdapter] Initializing Parakeet (Sherpa-ONNX) in background isolate...',
      );
      onStatus?.call('Initializing Parakeet (Sherpa-ONNX)...');
      try {
        await _sherpaIsolate.initialize(
          onProgress: onProgress,
          onStatus: onStatus,
        );
        debugPrint('[TranscriptionAdapter] ✅ Parakeet (Sherpa-ONNX) ready');
        return;
      } catch (e) {
        debugPrint('[TranscriptionAdapter] ⚠️ Sherpa-ONNX init failed: $e');
        onStatus?.call('Initialization failed: $e');
        throw TranscriptionException(
          'Failed to initialize Parakeet: ${e.toString()}',
        );
      }
    }

    throw TranscriptionException('No transcription service available');
  }

  /// Transcribe audio file
  ///
  /// [audioPath] - Absolute path to audio file (WAV, 16kHz mono)
  /// [language] - Optional language hint (auto-detected by default)
  /// [onProgress] - Progress callback
  ///
  /// Returns transcription result with optional word-level timestamps
  Future<AdapterTranscriptionResult> transcribeAudio(
    String audioPath, {
    String? language,
    Function(TranscriptionProgress)? onProgress,
  }) async {
    // Lazy initialization - initialize on first use if not already done
    final needsInit =
        !_sherpaIsolate.isInitialized && !_parakeetService.isInitialized;

    if (needsInit) {
      debugPrint('[TranscriptionAdapter] Lazy-initializing...');
      // Use global callbacks if available (set by main.dart for UI updates)
      await initialize(
        onProgress: _globalOnProgress,
        onStatus: _globalOnStatus,
      );
    }

    // iOS/macOS: Prefer FluidAudio (faster, CoreML-optimized)
    if (_parakeetService.isInitialized) {
      return await _transcribeWithParakeet(audioPath, onProgress: onProgress);
    }

    // Android (or fallback): Use Sherpa-ONNX via background isolate
    if (_sherpaIsolate.isInitialized) {
      return await _transcribeWithSherpa(audioPath, onProgress: onProgress);
    }

    throw TranscriptionException('No transcription service available');
  }

  /// Transcribe using Parakeet via FluidAudio (iOS/macOS)
  Future<AdapterTranscriptionResult> _transcribeWithParakeet(
    String audioPath, {
    Function(TranscriptionProgress)? onProgress,
  }) async {
    try {
      // Start progress
      _updateProgress(0.1, 'Transcribing with Parakeet...', onProgress);

      // Transcribe
      final result = await _parakeetService.transcribeAudio(audioPath);

      // Complete
      _updateProgress(
        1.0,
        'Transcription complete!',
        onProgress,
        isComplete: true,
      );

      debugPrint(
        '[TranscriptionAdapter] ✅ Parakeet (FluidAudio) transcribed in ${result.duration.inMilliseconds}ms',
      );

      // Parakeet (FluidAudio) doesn't provide timestamps currently
      return AdapterTranscriptionResult(text: result.text);
    } on PlatformException catch (e) {
      throw TranscriptionException('Parakeet failed: ${e.message}');
    } catch (e) {
      throw TranscriptionException('Parakeet failed: ${e.toString()}');
    }
  }

  /// Transcribe using Parakeet via Sherpa-ONNX in background isolate (Android)
  Future<AdapterTranscriptionResult> _transcribeWithSherpa(
    String audioPath, {
    Function(TranscriptionProgress)? onProgress,
  }) async {
    try {
      // Start progress
      _updateProgress(0.05, 'Transcribing with Parakeet...', onProgress);

      // Transcribe in background isolate (non-blocking) with progress tracking
      final result = await _sherpaIsolate.transcribeAudio(
        audioPath,
        onProgress: (progress) {
          // Map chunk progress (0-1) to overall progress (0.05-0.95)
          final overallProgress = 0.05 + (progress * 0.9);
          _updateProgress(
            overallProgress,
            'Transcribing... ${(overallProgress * 100).toInt()}%',
            onProgress,
          );
        },
      );

      // Complete
      _updateProgress(
        1.0,
        'Transcription complete!',
        onProgress,
        isComplete: true,
      );

      debugPrint(
        '[TranscriptionAdapter] ✅ Parakeet (Sherpa-ONNX) transcribed in ${result.duration.inMilliseconds}ms',
      );

      if (result.timestamps != null && result.timestamps!.isNotEmpty) {
        debugPrint(
          '[TranscriptionAdapter] ✅ Got ${result.timestamps!.length} word timestamps!',
        );
      }

      return AdapterTranscriptionResult(
        text: result.text,
        tokens: result.tokens,
        timestamps: result.timestamps,
      );
    } catch (e) {
      throw TranscriptionException(
        'Parakeet (Sherpa-ONNX) failed: ${e.toString()}',
      );
    }
  }

  /// Update and broadcast progress
  void _updateProgress(
    double progress,
    String status,
    Function(TranscriptionProgress)? onProgress, {
    bool isComplete = false,
  }) {
    final progressData = TranscriptionProgress(
      progress: progress.clamp(0.0, 1.0),
      status: status,
      isComplete: isComplete,
    );

    _transcriptionProgressController.add(progressData);
    onProgress?.call(progressData);
  }

  /// Check if transcription service is ready
  Future<bool> isReady() async {
    // Check isolate-based Sherpa-ONNX first
    if (_sherpaIsolate.isInitialized) {
      return true;
    }

    // Fallback to FluidAudio (iOS/macOS)
    if (_parakeetService.isSupported) {
      return await _parakeetService.isReady();
    }

    return false;
  }

  void dispose() {
    _transcriptionProgressController.close();
    // Note: Don't dispose _sherpaIsolate here as it's a singleton
    // that may be reused by other instances
  }
}

/// Transcription result with optional word-level timestamps
class AdapterTranscriptionResult {
  final String text;
  final List<String>? tokens;
  final List<double>? timestamps;

  AdapterTranscriptionResult({
    required this.text,
    this.tokens,
    this.timestamps,
  });

  bool get hasWordTimestamps =>
      tokens != null &&
      timestamps != null &&
      tokens!.length == timestamps!.length;
}

/// Transcription progress data
class TranscriptionProgress {
  final double progress;
  final String status;
  final bool isComplete;

  TranscriptionProgress({
    required this.progress,
    required this.status,
    this.isComplete = false,
  });
}

/// Generic transcription exception
class TranscriptionException implements Exception {
  final String message;

  TranscriptionException(this.message);

  @override
  String toString() => message;
}
