import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';

import 'parakeet_service.dart' as parakeet;
import 'sherpa_onnx_isolate.dart' as isolate;

/// Platform-adaptive transcription service using Parakeet v3
///
/// Uses Parakeet via different implementations:
/// - iOS/macOS: FluidAudio (CoreML-based, Apple Neural Engine) via ParakeetService
/// - Android: Sherpa-ONNX (ONNX Runtime-based) via background isolate
///
/// The Android implementation uses a background isolate to prevent UI blocking
/// during long transcriptions (fixes "not responding" issue).
///
/// This provides fast, offline transcription with 25-language support.
class TranscriptionService {
  static final TranscriptionService _instance = TranscriptionService._internal();
  factory TranscriptionService() => _instance;
  TranscriptionService._internal();

  final parakeet.ParakeetService _parakeetService = parakeet.ParakeetService();

  // Sherpa-ONNX via background isolate (Android) - prevents UI blocking
  final isolate.SherpaOnnxIsolate _sherpaIsolate = isolate.SherpaOnnxIsolate.instance;

  // Initialization state
  bool _isInitializing = false;

  bool get isInitialized {
    if (Platform.isIOS || Platform.isMacOS) {
      return _parakeetService.isInitialized;
    }
    // Use isolate-based initialization on Android
    return _sherpaIsolate.isInitialized;
  }

  bool get isSupported {
    if (Platform.isIOS || Platform.isMacOS) {
      return _parakeetService.isSupported;
    }
    return true; // Sherpa-ONNX supports all platforms
  }

  String get engineName {
    if (Platform.isIOS || Platform.isMacOS) {
      return 'Parakeet v3 (FluidAudio)';
    }
    return 'Parakeet v3 (Sherpa-ONNX)';
  }

  /// Initialize the transcription service
  Future<void> initialize({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    if (isInitialized) {
      debugPrint('[TranscriptionService] Already initialized');
      return;
    }

    if (_isInitializing) {
      debugPrint('[TranscriptionService] Already initializing, waiting...');
      while (_isInitializing) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      return;
    }

    _isInitializing = true;

    try {
      if (Platform.isIOS || Platform.isMacOS) {
        await _initializeParakeet(onProgress: onProgress, onStatus: onStatus);
      } else {
        await _initializeSherpa(onProgress: onProgress, onStatus: onStatus);
      }
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _initializeParakeet({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    debugPrint('[TranscriptionService] Initializing Parakeet (FluidAudio)...');
    onStatus?.call('Initializing Parakeet...');

    await _parakeetService.initialize(version: 'v3');

    debugPrint('[TranscriptionService] ✅ Parakeet ready');
    onProgress?.call(1.0);
    onStatus?.call('Ready');
  }

  Future<void> _initializeSherpa({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    debugPrint('[TranscriptionService] Initializing Sherpa-ONNX via background isolate...');
    onStatus?.call('Initializing Sherpa-ONNX...');

    // Check if models need to be downloaded first (done on main thread)
    final modelsAvailable = await _sherpaIsolate.checkModelsAvailable();
    if (!modelsAvailable) {
      // Download models on main thread (with progress updates)
      await _ensureModelsDownloaded(
        onProgress: onProgress,
        onStatus: onStatus,
      );
    }

    // Initialize the isolate (loads models in background thread)
    await _sherpaIsolate.initialize(
      onProgress: onProgress,
      onStatus: onStatus,
    );

    debugPrint('[TranscriptionService] ✅ Sherpa-ONNX ready (via isolate)');
  }

  /// Transcribe audio file
  Future<TranscriptionResult> transcribeAudio(
    String audioPath, {
    Function(double progress)? onProgress,
  }) async {
    // Lazy initialization
    if (!isInitialized) {
      await initialize();
    }

    if (Platform.isIOS || Platform.isMacOS) {
      return await _transcribeWithParakeet(audioPath, onProgress: onProgress);
    } else {
      return await _transcribeWithSherpa(audioPath, onProgress: onProgress);
    }
  }

  Future<TranscriptionResult> _transcribeWithParakeet(
    String audioPath, {
    Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.1);

    final result = await _parakeetService.transcribeAudio(audioPath);

    onProgress?.call(1.0);

    return TranscriptionResult(
      text: result.text,
      language: result.language,
      duration: result.duration,
    );
  }

  Future<TranscriptionResult> _transcribeWithSherpa(
    String audioPath, {
    Function(double progress)? onProgress,
  }) async {
    if (!_sherpaIsolate.isInitialized) {
      throw StateError('Sherpa-ONNX isolate not initialized');
    }

    final file = File(audioPath);
    if (!await file.exists()) {
      throw ArgumentError('Audio file not found: $audioPath');
    }

    debugPrint('[TranscriptionService] Transcribing in background isolate: $audioPath');

    // Transcribe in background isolate - UI stays responsive!
    final result = await _sherpaIsolate.transcribeAudio(
      audioPath,
      onProgress: onProgress,
    );

    debugPrint('[TranscriptionService] ✅ Transcribed in ${result.duration.inMilliseconds}ms');

    return TranscriptionResult(
      text: result.text,
      language: result.language,
      duration: result.duration,
    );
  }

  Future<String> _ensureModelsDownloaded({
    Function(double progress)? onProgress,
    Function(String status)? onStatus,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelDir = path.join(appDir.path, 'models', 'parakeet-v3');
    final modelDirFile = Directory(modelDir);

    // Check if models already exist
    final encoderFile = File(path.join(modelDir, 'encoder.int8.onnx'));
    final tokensFile = File(path.join(modelDir, 'tokens.txt'));

    if (await encoderFile.exists() && await tokensFile.exists()) {
      final encoderSize = await encoderFile.length();
      final tokensSize = await tokensFile.length();

      if (encoderSize > 100 * 1024 * 1024 && tokensSize > 1000) {
        debugPrint('[TranscriptionService] Models already downloaded');
        return modelDir;
      }
    }

    // Download models
    debugPrint('[TranscriptionService] Downloading Parakeet v3 models...');
    onStatus?.call('Downloading Parakeet v3 models...');
    await modelDirFile.create(recursive: true);

    const archiveUrl =
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2';
    final archivePath = path.join(appDir.path, 'models', 'parakeet-v3-int8.tar.bz2');

    try {
      // Download
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(archiveUrl));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength ?? 465 * 1024 * 1024;
      int receivedBytes = 0;

      final archiveFile = File(archivePath);
      final sink = archiveFile.openWrite();

      await for (final chunk in response.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        final downloadProgress = receivedBytes / totalBytes * 0.7;
        onProgress?.call(downloadProgress);
      }

      await sink.flush();
      await sink.close();
      client.close();

      // Extract
      onStatus?.call('Extracting models...');
      onProgress?.call(0.75);

      await compute(_extractArchive, {
        'archivePath': archivePath,
        'modelDir': modelDir,
      });

      await File(archivePath).delete();

      return modelDir;
    } catch (e) {
      if (await File(archivePath).exists()) {
        await File(archivePath).delete();
      }
      rethrow;
    }
  }

  static Future<void> _extractArchive(Map<String, String> params) async {
    final archivePath = params['archivePath']!;
    final modelDir = params['modelDir']!;

    final archiveBytes = await File(archivePath).readAsBytes();
    final decompressed = BZip2Decoder().decodeBytes(archiveBytes);
    final archive = TarDecoder().decodeBytes(decompressed);

    const targetFiles = ['encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt'];

    for (final file in archive) {
      if (file.isFile) {
        final basename = path.basename(file.name);
        if (targetFiles.contains(basename)) {
          final outputPath = path.join(modelDir, basename);
          final outputFile = File(outputPath);
          await outputFile.create(recursive: true);
          await outputFile.writeAsBytes(file.content as List<int>);
        }
      }
    }
  }

  Future<bool> isReady() async {
    if (Platform.isIOS || Platform.isMacOS) {
      return await _parakeetService.isReady();
    }
    return _sherpaIsolate.isInitialized;
  }

  void dispose() {
    // Dispose isolate on Android
    _sherpaIsolate.dispose();
  }
}

/// Transcription result
class TranscriptionResult {
  final String text;
  final String language;
  final Duration duration;

  TranscriptionResult({
    required this.text,
    required this.language,
    required this.duration,
  });

  @override
  String toString() =>
      'TranscriptionResult(text: "$text", language: $language, duration: ${duration.inMilliseconds}ms)';
}
