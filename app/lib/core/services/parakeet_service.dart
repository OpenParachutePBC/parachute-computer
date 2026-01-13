import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Flutter service for Parakeet ASR via native FluidAudio bridge
///
/// Supports iOS/macOS only. For Android, use SherpaOnnxService.
class ParakeetService {
  static const _channel = MethodChannel('com.parachute.app/parakeet');

  // Static flags shared across all instances to prevent concurrent initialization
  static bool _isInitialized = false;
  static bool _isInitializing = false;
  static String _version = 'v3';
  // Track if native bridge is available (set false on MissingPluginException)
  static bool _bridgeAvailable = true;

  bool get isInitialized => _isInitialized;
  // Only supported if platform is iOS/macOS AND native bridge is available
  bool get isSupported => _bridgeAvailable && (Platform.isIOS || Platform.isMacOS);
  String get version => _version;

  /// Initialize Parakeet models
  ///
  /// [version] - 'v3' (multilingual, 25 languages) or 'v2' (English only)
  ///
  /// Downloads models from HuggingFace if not already cached.
  /// First run may take time to download (~500MB for v3).
  Future<void> initialize({String version = 'v3'}) async {
    if (!isSupported) {
      throw UnsupportedError(
        'Parakeet is only supported on iOS/macOS. Current platform: ${Platform.operatingSystem}',
      );
    }

    if (_isInitialized) {
      debugPrint('[ParakeetService] Already initialized');
      return;
    }

    if (_isInitializing) {
      debugPrint('[ParakeetService] Already initializing, waiting...');
      // Wait for the existing initialization to complete
      while (_isInitializing) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      if (_isInitialized) {
        debugPrint('[ParakeetService] Initialization completed by another caller');
        return;
      }
      // If we get here, the other initialization failed, so we'll try again
    }

    _isInitializing = true;
    try {
      debugPrint('[ParakeetService] Initializing Parakeet $version...');
      final result = await _channel.invokeMethod<Map>('initialize', {
        'version': version,
      });

      if (result != null && result['status'] == 'success') {
        _isInitialized = true;
        _version = result['version'] as String? ?? version;
        debugPrint('[ParakeetService] ✅ Initialized successfully: $_version');
      } else {
        throw Exception('Initialization failed: $result');
      }
    } on MissingPluginException {
      debugPrint('[ParakeetService] Native bridge not available, disabling service');
      _bridgeAvailable = false;
      rethrow;
    } on PlatformException catch (e) {
      debugPrint('[ParakeetService] ❌ Initialization failed: ${e.message}');
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }

  /// Transcribe audio file
  ///
  /// [audioPath] - Absolute path to audio file (WAV or Opus)
  /// Opus files are automatically converted to WAV in the native layer
  ///
  /// Returns transcribed text and detected language.
  Future<TranscriptionResult> transcribeAudio(String audioPath) async {
    if (!isSupported) {
      throw UnsupportedError(
        'Parakeet is only supported on iOS/macOS. Current platform: ${Platform.operatingSystem}',
      );
    }

    if (!_isInitialized) {
      throw StateError('Parakeet not initialized. Call initialize() first.');
    }

    // Validate file exists
    final file = File(audioPath);
    if (!await file.exists()) {
      throw ArgumentError('Audio file not found: $audioPath');
    }

    try {
      debugPrint('[ParakeetService] Transcribing: $audioPath');
      final startTime = DateTime.now();

      // Native layer handles Opus→WAV conversion automatically
      final result = await _channel.invokeMethod<Map>('transcribe', {
        'audioPath': audioPath,
      });

      final duration = DateTime.now().difference(startTime);

      if (result == null) {
        throw Exception('Transcription returned null');
      }

      final text = result['text'] as String? ?? '';
      final language = result['language'] as String? ?? 'unknown';

      debugPrint(
        '[ParakeetService] ✅ Transcribed in ${duration.inMilliseconds}ms: "$text"',
      );

      return TranscriptionResult(
        text: text,
        language: language,
        duration: duration,
      );
    } on PlatformException catch (e) {
      debugPrint('[ParakeetService] ❌ Transcription failed: ${e.message}');
      rethrow;
    }
  }

  /// Check if Parakeet is ready
  Future<bool> isReady() async {
    if (!isSupported) return false;

    try {
      final result = await _channel.invokeMethod<Map>('isReady');
      return result?['ready'] as bool? ?? false;
    } catch (e) {
      debugPrint('[ParakeetService] isReady check failed: $e');
      return false;
    }
  }

  /// Check if models are already downloaded (without initializing)
  Future<bool> areModelsDownloaded() async {
    if (!isSupported) return false;

    try {
      final result = await _channel.invokeMethod<Map>('areModelsDownloaded');
      return result?['downloaded'] as bool? ?? false;
    } on MissingPluginException {
      // Native bridge not implemented - disable service
      debugPrint('[ParakeetService] Native bridge not available, disabling service');
      _bridgeAvailable = false;
      return false;
    } catch (e) {
      debugPrint('[ParakeetService] areModelsDownloaded failed: $e');
      return false;
    }
  }
}

/// Transcription result from Parakeet
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
