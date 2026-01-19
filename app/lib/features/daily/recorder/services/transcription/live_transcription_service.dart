import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'package:parachute/core/services/transcription/transcription_service_adapter.dart';
import 'package:parachute/core/services/vad/smart_chunker.dart';
import 'package:parachute/core/services/audio_processing/simple_noise_filter.dart';
import 'package:parachute/core/services/file_system_service.dart';
import 'package:parachute/features/daily/recorder/services/background_recording_service.dart';

import 'models/models.dart';
import 'segment_persistence.dart';
import 'transcription_queue.dart';
import 'streaming_audio_recorder.dart';
import 'local_agreement.dart';

/// Live transcription service with VAD-based auto-pause detection
///
/// **Streaming Transcription Architecture**:
/// 1. User starts recording → Continuous audio capture
/// 2. Audio → Noise filter → VAD → Rolling buffer (30s)
/// 3. Every 3s during speech → Re-transcribe last 15s → Stream interim text
/// 4. On 1s silence → Finalize chunk → Confirmed text
/// 5. On stop → Flush with 2s silence → Capture final words
///
/// **Background Recovery**:
/// - Segments persisted to JSON before transcription
/// - On app restart, pending segments recovered from disk
/// - Audio file retained for 7 days for crash recovery
///
/// Platform-adaptive transcription:
/// - iOS/macOS: Uses Parakeet v3 (fast, high-quality)
/// - Android: Uses Sherpa-ONNX with Parakeet
class LiveTranscriptionService {
  final TranscriptionServiceAdapter _transcriptionService;
  final BackgroundRecordingService _backgroundService = BackgroundRecordingService();

  // Extracted components (nullable until initialized)
  StreamingAudioRecorder? _recorder;
  SegmentPersistence? _persistence;
  TranscriptionQueue? _queue;
  bool _isInitialized = false;
  final LocalAgreementState _localAgreement = LocalAgreementState();
  final RollingAudioBuffer _rollingBuffer = RollingAudioBuffer();

  // Noise filtering & VAD
  SimpleNoiseFilter? _noiseFilter;
  SmartChunker? _chunker;
  final List<List<int>> _allAudioSamples = [];

  // Timers
  Timer? _reTranscriptionTimer;

  // State
  bool _isRecording = false;
  DateTime? _recordingStartTime;
  String? _tempDirectory;
  int _segmentStartOffset = 0;
  final List<String> _confirmedSegments = [];
  TranscriptionModelStatus _modelStatus = TranscriptionModelStatus.notInitialized;

  // Stream controllers
  final _vadActivityController = StreamController<bool>.broadcast();
  final _debugMetricsController = StreamController<AudioDebugMetrics>.broadcast();
  final _streamingStateController = StreamController<StreamingTranscriptionState>.broadcast();
  final _interimTextController = StreamController<String>.broadcast();

  // Public streams (safe to access before initialization)
  Stream<bool> get vadActivityStream => _vadActivityController.stream;
  Stream<AudioDebugMetrics> get debugMetricsStream => _debugMetricsController.stream;
  Stream<StreamingTranscriptionState> get streamingStateStream => _streamingStateController.stream;
  Stream<String> get interimTextStream => _interimTextController.stream;
  Stream<TranscriptionSegment> get segmentStream =>
      _queue?.segmentStream ?? const Stream.empty();
  Stream<bool> get isProcessingStream =>
      _queue?.isProcessingStream ?? Stream.value(false);
  Stream<bool> get streamHealthStream =>
      _recorder?.streamHealthStream ?? Stream.value(true);

  // Public getters (safe to access before initialization)
  bool get isRecording => _isRecording;
  bool get isProcessing => _queue?.isProcessing ?? false;
  List<TranscriptionSegment> get segments => _queue?.segments ?? [];
  List<String> get confirmedSegments => List.unmodifiable(_confirmedSegments);
  String get interimText => _localAgreement.interimText;

  StreamingTranscriptionState get currentStreamingState => StreamingTranscriptionState(
    confirmedText: _localAgreement.confirmedText,
    tentativeText: _localAgreement.tentativeText,
    interimText: _localAgreement.interimText,
    confirmedSegments: List.unmodifiable(_confirmedSegments),
    isRecording: _isRecording,
    isProcessing: _queue?.isProcessing ?? false,
    recordingDuration: _recordingStartTime != null
        ? DateTime.now().difference(_recordingStartTime!)
        : Duration.zero,
    vadLevel: _chunker?.stats.vadStats.isSpeaking == true ? 1.0 : 0.0,
    modelStatus: _modelStatus,
  );

  LiveTranscriptionService(this._transcriptionService);

  /// Initialize service
  Future<void> initialize() async {
    if (_isInitialized) return;

    final fileSystem = FileSystemService.daily();
    _tempDirectory = await fileSystem.getTempAudioPath();

    _recorder = StreamingAudioRecorder();
    _persistence = SegmentPersistence(_tempDirectory!);
    _queue = TranscriptionQueue(
      transcriptionService: _transcriptionService,
      persistence: _persistence!,
      onConfirmedSegment: (text) {
        _confirmedSegments.add(text);
        _emitStreamingState();
      },
    );

    _isInitialized = true;
    debugPrint('[LiveTranscription] Initialized with temp dir: $_tempDirectory');

    // Recover pending segments
    await _recoverPendingSegments();
  }

  /// Recover pending segments from previous session
  Future<void> _recoverPendingSegments() async {
    final pendingSegments = await _persistence!.recoverPendingSegments();

    for (final segment in pendingSegments) {
      final audioFile = File(segment.audioFilePath);
      if (!await audioFile.exists()) {
        debugPrint('[LiveTranscription] ⚠️ Audio file missing for segment ${segment.index}');
        await _persistence!.updateSegmentStatus(
          segment.index,
          TranscriptionSegmentStatus.failed,
          text: '[Audio file missing]',
        );
        continue;
      }

      try {
        final audioBytes = await audioFile.readAsBytes();
        const wavHeaderSize = 44;
        final startOffset = segment.startOffsetBytes + wavHeaderSize;
        final endOffset = startOffset + (segment.durationSamples * 2);

        if (endOffset > audioBytes.length) {
          debugPrint('[LiveTranscription] ⚠️ Segment ${segment.index} exceeds audio file length');
          await _persistence!.updateSegmentStatus(
            segment.index,
            TranscriptionSegmentStatus.failed,
            text: '[Invalid audio range]',
          );
          continue;
        }

        final segmentBytes = audioBytes.sublist(startOffset, endOffset);
        final samples = _bytesToInt16(Uint8List.fromList(segmentBytes));

        debugPrint('[LiveTranscription] 🔄 Queueing recovered segment ${segment.index}');
        _queue!.queueSegment(samples, index: segment.index);
      } catch (e) {
        debugPrint('[LiveTranscription] ❌ Failed to recover segment ${segment.index}: $e');
        await _persistence!.updateSegmentStatus(
          segment.index,
          TranscriptionSegmentStatus.failed,
          text: '[Recovery failed: $e]',
        );
      }
    }
  }

  /// Start recording with VAD-based auto-pause
  Future<bool> startRecording({
    double vadEnergyThreshold = 200.0,
    Duration silenceThreshold = const Duration(seconds: 1),
    Duration minChunkDuration = const Duration(milliseconds: 500),
    Duration maxChunkDuration = const Duration(seconds: 30),
  }) async {
    if (_isRecording) {
      debugPrint('[LiveTranscription] Already recording');
      return false;
    }

    if (_tempDirectory == null) {
      await initialize();
    }

    // Initialize noise filter
    _noiseFilter = SimpleNoiseFilter(
      cutoffFreq: 80.0,
      sampleRate: 16000,
    );

    // Initialize SmartChunker
    _chunker = SmartChunker(
      config: SmartChunkerConfig(
        sampleRate: 16000,
        silenceThreshold: silenceThreshold,
        minChunkDuration: minChunkDuration,
        maxChunkDuration: maxChunkDuration,
        vadEnergyThreshold: vadEnergyThreshold,
        onChunkReady: _handleChunk,
      ),
    );

    // Start audio recording
    final success = await _recorder!.startRecording(
      onAudioChunk: _processAudioChunk,
    );

    if (!success) {
      return false;
    }

    _isRecording = true;
    _recordingStartTime = DateTime.now();
    _allAudioSamples.clear();
    _queue!.clear();

    // Reset streaming state
    _localAgreement.reset();
    _rollingBuffer.clear();
    _confirmedSegments.clear();
    _segmentStartOffset = 0;

    // Check model status
    final isModelReady = await _transcriptionService.isReady();
    _modelStatus = isModelReady
        ? TranscriptionModelStatus.ready
        : TranscriptionModelStatus.initializing;

    // Notify background service
    await _backgroundService.onRecordingStarted(_recorder!.audioFilePath);

    // Emit initial state
    _emitStreamingState();

    debugPrint('[LiveTranscription] ✅ Recording started with VAD');
    return true;
  }

  /// Process incoming audio chunk
  void _processAudioChunk(Uint8List audioBytes) {
    if (!_isRecording || _chunker == null || _noiseFilter == null) return;

    // Convert bytes to int16 samples
    final rawSamples = _bytesToInt16(audioBytes);
    if (rawSamples.isEmpty) return;

    // Apply noise filter
    final cleanSamples = _noiseFilter!.process(rawSamples);

    // Emit debug metrics
    final rawEnergy = _calculateRMS(rawSamples);
    final cleanEnergy = _calculateRMS(cleanSamples);
    final reduction = rawEnergy > 0 ? ((1 - cleanEnergy / rawEnergy) * 100) : 0.0;

    if (!_debugMetricsController.isClosed) {
      _debugMetricsController.add(AudioDebugMetrics(
        rawEnergy: rawEnergy,
        cleanEnergy: cleanEnergy,
        filterReduction: reduction,
        vadThreshold: _chunker!.stats.vadStats.isSpeaking ? cleanEnergy : 0,
        isSpeech: cleanEnergy > 200.0,
        timestamp: DateTime.now(),
      ));
    }

    // Buffer for transcription
    _allAudioSamples.add(cleanSamples);
    _rollingBuffer.addSamples(cleanSamples);

    // Stream to disk
    _recorder!.writeSamples(cleanSamples);

    // Process through VAD chunker
    _chunker!.processSamples(cleanSamples);

    // Emit VAD activity
    final isSpeaking = _chunker!.stats.vadStats.isSpeaking;
    if (!_vadActivityController.isClosed) {
      _vadActivityController.add(isSpeaking);
    }
  }

  /// Handle chunk ready from VAD (pause detected)
  void _handleChunk(List<int> samples) {
    final duration = Duration(milliseconds: (samples.length / 16).round());
    debugPrint('[LiveTranscription] VAD pause detected! Duration: ${duration.inSeconds}s');

    // Queue for transcription
    _queue!.queueSegment(
      samples,
      audioFilePath: _recorder!.audioFilePath,
      startOffset: _segmentStartOffset,
    );

    // Clear rolling buffer - we're done with this audio
    _rollingBuffer.clear();
    _localAgreement.reset();

    // Update offset for next segment
    _segmentStartOffset = _recorder!.totalSamplesWritten * 2;
  }

  /// Stop recording
  Future<String?> stopRecording() async {
    if (!_isRecording) return null;

    try {
      debugPrint('[LiveTranscription] 🛑 Stopping recording...');

      _stopReTranscriptionLoop();

      // Flush chunker for final audio
      if (_chunker != null) {
        debugPrint('[LiveTranscription] Flushing chunker for final audio...');
        _chunker!.flush();
        _chunker = null;
      }

      // Wait for queue to finish
      while (_queue?.isProcessing ?? false) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Transcribe remaining buffer
      if (_rollingBuffer.length > 8000) {
        debugPrint('[LiveTranscription] Transcribing remaining buffer: ${_rollingBuffer.length} samples');
        await _doFinalTranscription();
      }

      // Reset noise filter
      _noiseFilter?.reset();
      _noiseFilter = null;

      _isRecording = false;
      _emitStreamingState();

      // Stop recorder and finalize WAV
      final audioPath = await _recorder!.stopRecording();

      // Clear memory buffers
      _allAudioSamples.clear();
      _rollingBuffer.clear();
      _recordingStartTime = null;

      // Notify background service
      await _backgroundService.onRecordingStopped();

      debugPrint('[LiveTranscription] Recording stopped: $audioPath');
      return audioPath;
    } catch (e) {
      debugPrint('[LiveTranscription] Failed to stop: $e');
      return null;
    }
  }

  /// Cancel recording without saving
  Future<void> cancelRecording() async {
    if (!_isRecording) return;

    try {
      debugPrint('[LiveTranscription] ❌ Cancelling recording...');

      _stopReTranscriptionLoop();

      _chunker = null;

      _isRecording = false;
      _recordingStartTime = null;

      await _recorder?.cancelRecording();

      // Clear state
      _queue?.clear();
      _allAudioSamples.clear();
      _rollingBuffer.clear();
      _localAgreement.reset();
      _confirmedSegments.clear();

      _emitStreamingState();

      await _backgroundService.onRecordingStopped();

      debugPrint('[LiveTranscription] Recording cancelled');
    } catch (e) {
      debugPrint('[LiveTranscription] Failed to cancel: $e');
    }
  }

  /// Pause recording
  Future<void> pauseRecording() async {
    if (!_isRecording) return;
    await _recorder?.pauseRecording();
  }

  /// Resume recording
  Future<void> resumeRecording() async {
    if (!_isRecording) return;
    await _recorder?.resumeRecording();
  }

  /// Final transcription for remaining audio
  Future<void> _doFinalTranscription() async {
    if (_rollingBuffer.isEmpty) return;

    try {
      debugPrint('[LiveTranscription] Final transcription: ${_rollingBuffer.length} samples');

      final samplesToTranscribe = _rollingBuffer.getBufferCopy();

      final fileSystem = FileSystemService.daily();
      final tempPath = await fileSystem.getTranscriptionSegmentPath(-999);

      await _saveSamplesToWav(samplesToTranscribe, tempPath);

      final result = await _transcriptionService.transcribeAudio(tempPath);

      try {
        await File(tempPath).delete();
      } catch (_) {}

      final transcribedText = result.text.trim();
      if (transcribedText.isNotEmpty) {
        _confirmedSegments.add(transcribedText);
        debugPrint('[LiveTranscription] Final segment: "$transcribedText"');
      }

      _emitStreamingState();
    } catch (e) {
      debugPrint('[LiveTranscription] Final transcription failed: $e');
    }
  }

  void _stopReTranscriptionLoop() {
    _reTranscriptionTimer?.cancel();
    _reTranscriptionTimer = null;
  }

  void _emitStreamingState() {
    if (_streamingStateController.isClosed) return;
    _streamingStateController.add(currentStreamingState);
  }

  /// Get complete transcript
  String getCompleteTranscript() => _queue?.getCompleteTranscript() ?? '';

  /// Get streaming transcript
  String getStreamingTranscript() => _confirmedSegments.join('\n');

  /// Alias for compatibility
  String getCombinedText() => getCompleteTranscript();

  // Utility methods
  List<int> _bytesToInt16(Uint8List bytes) {
    final samples = <int>[];
    for (var i = 0; i < bytes.length; i += 2) {
      if (i + 1 < bytes.length) {
        final sample = bytes[i] | (bytes[i + 1] << 8);
        final signed = sample > 32767 ? sample - 65536 : sample;
        samples.add(signed);
      }
    }
    return samples;
  }

  double _calculateRMS(List<int> samples) {
    if (samples.isEmpty) return 0.0;
    double sumSquares = 0.0;
    for (final sample in samples) {
      sumSquares += sample * sample;
    }
    return sqrt(sumSquares / samples.length);
  }

  Future<void> _saveSamplesToWav(List<int> samples, String filePath) async {
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;

    final dataSize = samples.length * 2;
    final fileSize = 36 + dataSize;

    final bytes = BytesBuilder();

    bytes.add('RIFF'.codeUnits);
    bytes.add(_int32ToBytes(fileSize));
    bytes.add('WAVE'.codeUnits);
    bytes.add('fmt '.codeUnits);
    bytes.add(_int32ToBytes(16));
    bytes.add(_int16ToBytes(1));
    bytes.add(_int16ToBytes(numChannels));
    bytes.add(_int32ToBytes(sampleRate));
    bytes.add(_int32ToBytes(sampleRate * numChannels * bitsPerSample ~/ 8));
    bytes.add(_int16ToBytes(numChannels * bitsPerSample ~/ 8));
    bytes.add(_int16ToBytes(bitsPerSample));
    bytes.add('data'.codeUnits);
    bytes.add(_int32ToBytes(dataSize));

    for (final sample in samples) {
      bytes.add(_int16ToBytes(sample));
    }

    final file = File(filePath);
    await file.writeAsBytes(bytes.toBytes());
  }

  Uint8List _int32ToBytes(int value) {
    return Uint8List(4)
      ..[0] = value & 0xFF
      ..[1] = (value >> 8) & 0xFF
      ..[2] = (value >> 16) & 0xFF
      ..[3] = (value >> 24) & 0xFF;
  }

  Uint8List _int16ToBytes(int value) {
    final clamped = value.clamp(-32768, 32767);
    final unsigned = clamped < 0 ? clamped + 65536 : clamped;
    return Uint8List(2)
      ..[0] = unsigned & 0xFF
      ..[1] = (unsigned >> 8) & 0xFF;
  }

  /// Dispose all resources
  Future<void> dispose() async {
    debugPrint('[LiveTranscription] 🧹 Disposing service...');

    _stopReTranscriptionLoop();

    await _recorder?.dispose();
    await _queue?.dispose();

    await _vadActivityController.close();
    await _debugMetricsController.close();
    await _streamingStateController.close();
    await _interimTextController.close();

    debugPrint('[LiveTranscription] ✅ Service disposed');
  }
}
