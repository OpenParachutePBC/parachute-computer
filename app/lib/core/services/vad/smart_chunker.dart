import 'package:flutter/foundation.dart';
import 'simple_vad.dart';

/// Configuration for VAD-based audio chunking
/// Ported from RichardTate: server/internal/transcription/chunker.go
class SmartChunkerConfig {
  /// Audio sample rate (default: 16kHz)
  final int sampleRate;

  /// Duration of silence to trigger chunk (default: 1s)
  final Duration silenceThreshold;

  /// Minimum chunk duration to avoid tiny chunks (default: 500ms)
  final Duration minChunkDuration;

  /// Maximum chunk duration as safety limit (default: 30s)
  final Duration maxChunkDuration;

  /// Energy threshold for VAD (default: 100.0)
  final double vadEnergyThreshold;

  /// Callback called when chunk is ready for transcription
  final void Function(List<int> chunk) onChunkReady;

  const SmartChunkerConfig({
    this.sampleRate = 16000,
    this.silenceThreshold = const Duration(seconds: 1),
    this.minChunkDuration = const Duration(milliseconds: 500),
    this.maxChunkDuration = const Duration(seconds: 30),
    this.vadEnergyThreshold = 100.0,
    required this.onChunkReady,
  });
}

/// Smart audio chunker that accumulates audio and chunks based on VAD silence detection
///
/// This is a direct port of RichardTate's SmartChunker implementation.
/// Source: https://github.com/lucianHymer/richardtate
/// File: server/internal/transcription/chunker.go
///
/// Monitors Voice Activity Detection (VAD) to automatically segment audio when
/// the user stops speaking (1 second of silence by default). Prevents sending
/// mostly-silent chunks to Whisper which reduces hallucinations.
class SmartChunker {
  final SmartChunkerConfig config;
  final SimpleVAD _vad;
  final List<int> _buffer = [];
  DateTime _lastChunk = DateTime.now();
  Duration _totalSpeech = Duration.zero;

  SmartChunker({required this.config})
    : _vad = SimpleVAD(
        config: VADConfig(
          sampleRate: config.sampleRate,
          frameDurationMs: 10, // 10ms frames (160 samples at 16kHz)
          energyThreshold: config.vadEnergyThreshold,
          silenceThresholdMs: config.silenceThreshold.inMilliseconds,
        ),
      );

  /// Process incoming audio samples
  ///
  /// This should be called with denoised samples from RNNoise.
  /// Matches RichardTate's ProcessSamples exactly.
  void processSamples(List<int> samples) {
    if (samples.isEmpty) {
      return;
    }

    // Add samples to buffer
    _buffer.addAll(samples);

    // Process through VAD in 10ms frames (160 samples at 16kHz)
    final frameSize = config.sampleRate ~/ 100; // 10ms = 160 samples at 16kHz
    int offset = 0;

    while (offset + frameSize <= samples.length) {
      final frame = samples.sublist(offset, offset + frameSize);

      // Run VAD on frame
      _vad.processFrame(frame);

      offset += frameSize;
    }

    // Check if we should chunk
    _checkAndChunk();
  }

  /// Determine if we should trigger a chunk
  ///
  /// This is the core logic that decides when to segment audio.
  void _checkAndChunk() {
    final bufferDuration = _getBufferDuration();
    final shouldChunk = _vad.shouldChunk();
    final vadStats = _vad.stats;

    // Safety: Always chunk if we hit max duration
    if (bufferDuration >= config.maxChunkDuration) {
      debugPrint('[SmartChunker] Max duration reached, flushing chunk');
      _flushChunk();
      return;
    }

    // Check if VAD detected sufficient silence AND we have enough audio AND enough actual speech
    // This prevents sending chunks that are mostly silence/noise to Whisper (reduces hallucinations)
    const minSpeechDuration = Duration(
      seconds: 1,
    ); // Require at least 1 second of actual speech

    if (shouldChunk &&
        bufferDuration >= config.minChunkDuration &&
        vadStats.speechDuration >= minSpeechDuration) {
      debugPrint(
        '[SmartChunker] Auto-chunking: ${bufferDuration.inSeconds}s buffer, '
        '${vadStats.speechDuration.inSeconds}s speech, '
        '${vadStats.silenceDuration.inMilliseconds}ms silence',
      );
      _flushChunk();
      return;
    }
  }

  /// Send accumulated audio for transcription
  ///
  /// Makes a copy of the buffer and calls the callback asynchronously.
  void _flushChunk() {
    if (_buffer.isEmpty) {
      return;
    }

    // Make a copy for the callback
    final chunk = List<int>.from(_buffer);

    final vadStats = _vad.stats;

    // Clear buffer
    _buffer.clear();
    _lastChunk = DateTime.now();
    _totalSpeech += vadStats.speechDuration;

    // Reset VAD state
    _vad.reset();

    // Call callback asynchronously (using Future.microtask for similar behavior to Go's goroutine)
    Future.microtask(() {
      config.onChunkReady(chunk);
    });
  }

  /// Force flush of current buffer (called on stop)
  ///
  /// Only flushes if there's sufficient speech content to avoid hallucinations.
  /// Matches RichardTate's Flush exactly.
  void flush() {
    // Check if we have sufficient speech content to transcribe
    final vadStats = _vad.stats;
    const minSpeechDuration = Duration(
      seconds: 1,
    ); // Same threshold as regular chunks
    final bufferDuration = _getBufferDuration();

    if (_buffer.isEmpty) {
      debugPrint('[SmartChunker] Flush called but buffer is empty');
      return;
    }

    // Only flush if we have enough actual speech
    // This prevents hallucinations on trailing silence/noise
    if (vadStats.speechDuration >= minSpeechDuration) {
      debugPrint(
        '[SmartChunker] Flushing final chunk with '
        '${vadStats.speechDuration.inSeconds}s of speech',
      );
      _flushChunk();
    } else {
      debugPrint(
        '[SmartChunker] Discarding final chunk: insufficient speech '
        '(${vadStats.speechDuration.inSeconds}s speech in '
        '${bufferDuration.inSeconds}s buffer)',
      );
      // Clear buffer without transcribing
      _buffer.clear();
      _vad.reset();
    }
  }

  /// Get current buffer duration
  Duration _getBufferDuration() {
    final numSamples = _buffer.length;
    final seconds = numSamples / config.sampleRate;
    return Duration(microseconds: (seconds * 1000000).round());
  }

  /// Get current chunker statistics
  ChunkerStats get stats {
    return ChunkerStats(
      bufferDuration: _getBufferDuration(),
      bufferSamples: _buffer.length,
      totalSpeech: _totalSpeech,
      timeSinceChunk: DateTime.now().difference(_lastChunk),
      vadStats: _vad.stats,
    );
  }

  /// Reset clears the chunker state
  void reset() {
    _buffer.clear();
    _vad.reset();
    _lastChunk = DateTime.now();
    _totalSpeech = Duration.zero;
  }
}

/// Statistics about the chunker state
class ChunkerStats {
  final Duration bufferDuration;
  final int bufferSamples;
  final Duration totalSpeech;
  final Duration timeSinceChunk;
  final VADStats vadStats;

  const ChunkerStats({
    required this.bufferDuration,
    required this.bufferSamples,
    required this.totalSpeech,
    required this.timeSinceChunk,
    required this.vadStats,
  });

  @override
  String toString() {
    return 'ChunkerStats('
        'buffer: ${bufferDuration.inSeconds}s ($bufferSamples samples), '
        'totalSpeech: ${totalSpeech.inSeconds}s, '
        'timeSinceChunk: ${timeSinceChunk.inSeconds}s, '
        'vad: $vadStats)';
  }
}
