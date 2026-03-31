import 'dart:math';

/// Configuration for Voice Activity Detection
/// Ported from RichardTate: server/internal/transcription/vad.go
class VADConfig {
  /// Audio sample rate (default: 16kHz)
  final int sampleRate;

  /// Frame duration in milliseconds (default: 10ms)
  final int frameDurationMs;

  /// Energy threshold for speech detection (default: 100.0 for RichardTate)
  /// This threshold determines what RMS energy level is considered speech.
  /// Note: Real-world usage may require 400-800+ to account for background noise
  final double energyThreshold;

  /// Silence duration to trigger chunk boundary in milliseconds (default: 1000ms)
  final int silenceThresholdMs;

  const VADConfig({
    this.sampleRate = 16000,
    this.frameDurationMs = 10,
    this.energyThreshold = 100.0,
    this.silenceThresholdMs = 1000,
  });
}

/// Voice Activity Detector - detects speech vs silence in audio
///
/// This is a direct port of RichardTate's VAD implementation.
/// Source: https://github.com/lucianHymer/richardtate
/// File: server/internal/transcription/vad.go
///
/// Uses RMS (Root Mean Square) energy calculation to distinguish
/// speech from silence. Tracks consecutive frames of each type
/// and accumulates time durations for chunk boundary detection.
class SimpleVAD {
  final VADConfig config;
  late final int samplesPerFrame;

  Duration _silenceDuration = Duration.zero;
  Duration _speechDuration = Duration.zero;
  bool _lastFrameWasSpeech = false;
  int _consecutiveSilence = 0;
  int _consecutiveSpeech = 0;

  SimpleVAD({VADConfig? config}) : config = config ?? const VADConfig() {
    samplesPerFrame =
        this.config.sampleRate * this.config.frameDurationMs ~/ 1000;
  }

  /// Process a single audio frame
  ///
  /// [samples] should be int16 PCM samples
  /// Returns true if speech is detected, false if silence
  ///
  /// This matches RichardTate's ProcessFrame exactly.
  bool processFrame(List<int> samples) {
    if (samples.isEmpty) {
      return false;
    }

    // Calculate RMS energy
    final energy = _calculateEnergy(samples);

    // Determine if speech or silence
    final isSpeech = energy > config.energyThreshold;

    // Update counters
    final frameDuration = Duration(milliseconds: config.frameDurationMs);

    if (isSpeech) {
      _consecutiveSpeech++;
      _consecutiveSilence = 0;
      _speechDuration += frameDuration;
      _silenceDuration = Duration.zero; // Reset silence counter
      _lastFrameWasSpeech = true;
    } else {
      _consecutiveSilence++;
      _consecutiveSpeech = 0;
      _silenceDuration += frameDuration;
      _lastFrameWasSpeech = false;
    }

    return isSpeech;
  }

  /// Calculate RMS energy of audio samples
  ///
  /// This is the core algorithm that determines speech vs silence.
  /// Port of RichardTate's calculateEnergy function.
  double _calculateEnergy(List<int> samples) {
    if (samples.isEmpty) {
      return 0.0;
    }

    double sumSquares = 0.0;
    for (final sample in samples) {
      final val = sample.toDouble();
      sumSquares += val * val;
    }

    final rms = sqrt(sumSquares / samples.length);

    return rms;
  }

  /// Returns true if we've detected enough silence to trigger a chunk boundary
  ///
  /// This is called by SmartChunker to determine when to segment audio.
  bool shouldChunk() {
    final thresholdDuration = Duration(milliseconds: config.silenceThresholdMs);
    return _silenceDuration >= thresholdDuration;
  }

  /// Get current silence duration
  Duration get silenceDuration => _silenceDuration;

  /// Get accumulated speech duration since last reset
  Duration get speechDuration => _speechDuration;

  /// Returns true if we're currently in a speech region
  bool get isSpeaking => _lastFrameWasSpeech;

  /// Get consecutive silence frame count
  int get consecutiveSilence => _consecutiveSilence;

  /// Get consecutive speech frame count
  int get consecutiveSpeech => _consecutiveSpeech;

  /// Reset clears the VAD state (useful after chunking)
  void reset() {
    _silenceDuration = Duration.zero;
    _speechDuration = Duration.zero;
    _consecutiveSilence = 0;
    _consecutiveSpeech = 0;
    _lastFrameWasSpeech = false;
  }

  /// Get current VAD statistics
  VADStats get stats => VADStats(
    silenceDuration: _silenceDuration,
    speechDuration: _speechDuration,
    consecutiveSilence: _consecutiveSilence,
    consecutiveSpeech: _consecutiveSpeech,
    isSpeaking: _lastFrameWasSpeech,
  );
}

/// Statistics about the VAD state
class VADStats {
  final Duration silenceDuration;
  final Duration speechDuration;
  final int consecutiveSilence;
  final int consecutiveSpeech;
  final bool isSpeaking;

  const VADStats({
    required this.silenceDuration,
    required this.speechDuration,
    required this.consecutiveSilence,
    required this.consecutiveSpeech,
    required this.isSpeaking,
  });

  @override
  String toString() {
    return 'VADStats('
        'silence: ${silenceDuration.inMilliseconds}ms, '
        'speech: ${speechDuration.inMilliseconds}ms, '
        'consecutiveSilence: $consecutiveSilence, '
        'consecutiveSpeech: $consecutiveSpeech, '
        'isSpeaking: $isSpeaking)';
  }
}
