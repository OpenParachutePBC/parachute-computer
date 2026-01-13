import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:parachute/core/services/transcription/transcription_service_adapter.dart';
import 'package:parachute/core/services/vad/smart_chunker.dart';
import 'package:parachute/core/services/audio_processing/simple_noise_filter.dart';
import 'package:parachute/features/daily/recorder/services/background_recording_service.dart';
import 'package:parachute/core/services/file_system_service.dart';
import 'package:path/path.dart' as path;

/// Audio debug metrics for visualization
class AudioDebugMetrics {
  final double rawEnergy;
  final double cleanEnergy;
  final double filterReduction; // Percentage
  final double vadThreshold;
  final bool isSpeech;
  final DateTime timestamp;

  AudioDebugMetrics({
    required this.rawEnergy,
    required this.cleanEnergy,
    required this.filterReduction,
    required this.vadThreshold,
    required this.isSpeech,
    required this.timestamp,
  });
}

/// Represents a transcribed segment (auto-detected via VAD)
class TranscriptionSegment {
  final int index; // Segment number (1, 2, 3, ...)
  final String text;
  final TranscriptionSegmentStatus status;
  final DateTime timestamp;
  final Duration duration; // Audio duration of this segment

  TranscriptionSegment({
    required this.index,
    required this.text,
    required this.status,
    required this.timestamp,
    required this.duration,
  });

  TranscriptionSegment copyWith({
    int? index,
    String? text,
    TranscriptionSegmentStatus? status,
    DateTime? timestamp,
    Duration? duration,
  }) {
    return TranscriptionSegment(
      index: index ?? this.index,
      text: text ?? this.text,
      status: status ?? this.status,
      timestamp: timestamp ?? this.timestamp,
      duration: duration ?? this.duration,
    );
  }
}

enum TranscriptionSegmentStatus {
  pending, // Waiting to be transcribed
  processing, // Currently being transcribed
  completed, // Transcription done
  failed, // Transcription error
  interrupted, // Was processing when app closed (for recovery)
}

/// Persisted segment for background recovery
/// Stored in JSON file to survive app restarts
class PersistedSegment {
  final int index;
  final String audioFilePath;
  final int startOffsetBytes; // Byte offset in audio file (after WAV header)
  final int durationSamples; // Number of samples
  final TranscriptionSegmentStatus status;
  final String? transcribedText;
  final DateTime createdAt;
  final DateTime? completedAt;

  PersistedSegment({
    required this.index,
    required this.audioFilePath,
    required this.startOffsetBytes,
    required this.durationSamples,
    required this.status,
    this.transcribedText,
    required this.createdAt,
    this.completedAt,
  });

  Map<String, dynamic> toJson() => {
    'index': index,
    'audioFilePath': audioFilePath,
    'startOffsetBytes': startOffsetBytes,
    'durationSamples': durationSamples,
    'status': status.name,
    'transcribedText': transcribedText,
    'createdAt': createdAt.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
  };

  factory PersistedSegment.fromJson(Map<String, dynamic> json) {
    return PersistedSegment(
      index: json['index'] as int,
      audioFilePath: json['audioFilePath'] as String,
      startOffsetBytes: json['startOffsetBytes'] as int,
      durationSamples: json['durationSamples'] as int,
      status: TranscriptionSegmentStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => TranscriptionSegmentStatus.pending,
      ),
      transcribedText: json['transcribedText'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      completedAt: json['completedAt'] != null
          ? DateTime.parse(json['completedAt'] as String)
          : null,
    );
  }

  PersistedSegment copyWith({
    int? index,
    String? audioFilePath,
    int? startOffsetBytes,
    int? durationSamples,
    TranscriptionSegmentStatus? status,
    String? transcribedText,
    DateTime? createdAt,
    DateTime? completedAt,
  }) {
    return PersistedSegment(
      index: index ?? this.index,
      audioFilePath: audioFilePath ?? this.audioFilePath,
      startOffsetBytes: startOffsetBytes ?? this.startOffsetBytes,
      durationSamples: durationSamples ?? this.durationSamples,
      status: status ?? this.status,
      transcribedText: transcribedText ?? this.transcribedText,
      createdAt: createdAt ?? this.createdAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }
}

/// Streaming transcription state for UI
/// Transcription model status
enum TranscriptionModelStatus {
  notInitialized, // Model not yet initialized
  initializing, // Model is loading
  ready, // Model ready for transcription
  error, // Initialization failed
}

class StreamingTranscriptionState {
  final String confirmedText;   // Stable across 2+ iterations (locked, won't change)
  final String tentativeText;   // Stable for 1 iteration (likely stable)
  final String interimText;     // Current transcription suffix (may change)
  final List<String> confirmedSegments; // For final transcript assembly
  final bool isRecording;
  final bool isProcessing;
  final Duration recordingDuration;
  final double vadLevel; // 0.0 to 1.0 speech energy level
  final TranscriptionModelStatus modelStatus; // Track model initialization

  const StreamingTranscriptionState({
    this.confirmedText = '',
    this.tentativeText = '',
    this.interimText = '',
    this.confirmedSegments = const [],
    this.isRecording = false,
    this.isProcessing = false,
    this.recordingDuration = Duration.zero,
    this.vadLevel = 0.0,
    this.modelStatus = TranscriptionModelStatus.notInitialized,
  });

  StreamingTranscriptionState copyWith({
    String? confirmedText,
    String? tentativeText,
    String? interimText,
    List<String>? confirmedSegments,
    bool? isRecording,
    bool? isProcessing,
    Duration? recordingDuration,
    double? vadLevel,
    TranscriptionModelStatus? modelStatus,
  }) {
    return StreamingTranscriptionState(
      confirmedText: confirmedText ?? this.confirmedText,
      tentativeText: tentativeText ?? this.tentativeText,
      interimText: interimText ?? this.interimText,
      confirmedSegments: confirmedSegments ?? this.confirmedSegments,
      isRecording: isRecording ?? this.isRecording,
      isProcessing: isProcessing ?? this.isProcessing,
      recordingDuration: recordingDuration ?? this.recordingDuration,
      vadLevel: vadLevel ?? this.vadLevel,
      modelStatus: modelStatus ?? this.modelStatus,
    );
  }

  /// Get all text for display
  /// Shows only confirmed/final text from VAD-detected segments.
  /// No interim text during speech - simpler, no duplicates.
  String get displayText {
    return confirmedSegments.join(' ').trim();
  }
}

/// Auto-pause transcription service using VAD-based chunking
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
class AutoPauseTranscriptionService {
  final TranscriptionServiceAdapter _transcriptionService;
  final BackgroundRecordingService _backgroundService = BackgroundRecordingService();

  // Recording state
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  DateTime? _recordingStartTime;

  // Stream health monitoring
  DateTime? _lastAudioChunkTime;
  int _audioChunkCount = 0;
  Timer? _streamHealthCheckTimer;
  StreamSubscription<Uint8List>? _audioStreamSubscription;

  // Noise filtering & VAD
  SimpleNoiseFilter? _noiseFilter;
  SmartChunker? _chunker;
  final List<List<int>> _allAudioSamples = []; // Buffer for pending samples

  // === STREAMING TRANSCRIPTION WITH LOCAL AGREEMENT ===
  //
  // Architecture based on whisper_streaming's LocalAgreement-2 algorithm:
  // 1. Maintain a rolling audio buffer (15-30 seconds)
  // 2. Periodically transcribe the buffer (every 2 seconds)
  // 3. Compare consecutive transcriptions to find stable text
  // 4. Only "confirm" text that has been stable across 2 iterations
  // 5. Display: [confirmed stable text] + [current interim]
  //
  // This avoids phrase-matching heuristics and instead relies on
  // transcription stability as the signal for what's "real".

  List<int> _rollingAudioBuffer = [];
  static const int _rollingBufferMaxSamples = 16000 * 30; // 30 seconds max
  static const Duration _reTranscriptionInterval = Duration(seconds: 2); // Faster updates

  Timer? _reTranscriptionTimer;
  Timer? _recordingDurationTimer;
  bool _isReTranscribing = false;

  // === LocalAgreement-2 State ===
  // Track consecutive transcriptions to find stable prefixes
  String? _previousTranscription; // Last transcription result
  String _confirmedText = '';      // Text stable across 2+ iterations (locked)
  String _tentativeText = '';      // Text stable for 1 iteration (likely stable)
  String _interimText = '';        // Current transcription suffix (may change)

  // Track when we last had a VAD pause to avoid re-transcribing stale audio
  DateTime? _lastVadPauseTime;

  // For final transcript assembly
  final List<String> _confirmedSegments = [];

  // Map from queued segment index to confirmed segment index
  // This ensures official transcriptions update the correct confirmed segment
  final Map<int, int> _segmentToConfirmedIndex = {};

  // Track sample offset for segment persistence
  int _segmentStartOffset = 0; // Byte offset where current segment starts

  // === PERSISTENCE (Phase 2) ===
  static const String _pendingSegmentsFileName = 'pending_segments.json';
  String? _pendingSegmentsPath;

  // Streaming to disk - write audio incrementally to avoid memory buildup
  IOSink? _audioFileSink;
  int _totalSamplesWritten = 0;
  static const int _flushThreshold = 16000 * 10; // Flush every ~10 seconds of audio

  // File management
  String? _audioFilePath;
  String? _tempDirectory;

  // Queue size limit to prevent unbounded growth
  static const int _maxQueueSize = 20;

  // Segments (auto-detected paragraphs)
  final List<TranscriptionSegment> _segments = [];
  int _nextSegmentIndex = 1;

  // Processing queue
  final List<_QueuedSegment> _processingQueue = [];
  bool _isProcessingQueue = false;
  int _activeTranscriptions = 0; // Track number of transcriptions in progress

  // Progress streaming
  final _segmentStreamController =
      StreamController<TranscriptionSegment>.broadcast();
  final _processingStreamController = StreamController<bool>.broadcast();
  final _vadActivityController = StreamController<bool>.broadcast();
  final _debugMetricsController =
      StreamController<AudioDebugMetrics>.broadcast();
  final _streamHealthController =
      StreamController<bool>.broadcast(); // true = healthy, false = broken

  // === NEW: Streaming state for UI ===
  final _streamingStateController =
      StreamController<StreamingTranscriptionState>.broadcast();
  final _interimTextController = StreamController<String>.broadcast();

  // Track transcription model status
  TranscriptionModelStatus _modelStatus = TranscriptionModelStatus.notInitialized;

  Stream<TranscriptionSegment> get segmentStream =>
      _segmentStreamController.stream;
  Stream<bool> get isProcessingStream => _processingStreamController.stream;
  Stream<bool> get vadActivityStream =>
      _vadActivityController.stream; // true = speech, false = silence
  Stream<AudioDebugMetrics> get debugMetricsStream =>
      _debugMetricsController.stream;
  Stream<bool> get streamHealthStream => _streamHealthController.stream;

  /// Stream of interim text updates (re-transcribed every 3s during speech)
  Stream<String> get interimTextStream => _interimTextController.stream;

  /// Stream of complete streaming state for UI
  Stream<StreamingTranscriptionState> get streamingStateStream =>
      _streamingStateController.stream;

  /// Current streaming state snapshot
  StreamingTranscriptionState get currentStreamingState => StreamingTranscriptionState(
    confirmedText: _confirmedText,
    tentativeText: _tentativeText,
    interimText: _interimText,
    confirmedSegments: List.unmodifiable(_confirmedSegments),
    isRecording: _isRecording,
    isProcessing: _isProcessingQueue,
    recordingDuration: _recordingStartTime != null
        ? DateTime.now().difference(_recordingStartTime!)
        : Duration.zero,
    vadLevel: _chunker?.stats.vadStats.isSpeaking == true ? 1.0 : 0.0,
  );

  bool get isRecording => _isRecording;
  bool get isProcessing => _isProcessingQueue;
  List<TranscriptionSegment> get segments => List.unmodifiable(_segments);
  List<String> get confirmedSegments => List.unmodifiable(_confirmedSegments);
  String get interimText => _interimText;

  AutoPauseTranscriptionService(this._transcriptionService);

  /// Initialize service using centralized temp directory
  Future<void> initialize() async {
    if (_tempDirectory != null) return;

    // Use centralized temp audio folder from FileSystemService
    final fileSystem = FileSystemService.daily();
    _tempDirectory = await fileSystem.getTempAudioPath();

    // Set up persistence path
    _pendingSegmentsPath = path.join(_tempDirectory!, _pendingSegmentsFileName);

    debugPrint('[AutoPauseTranscription] Initialized with temp dir: $_tempDirectory');

    // Check for and recover pending segments from previous session
    await _recoverPendingSegments();
  }

  // ============================================================
  // PHASE 2: PERSISTENCE - Save and recover segments across restarts
  // ============================================================

  /// Recover pending segments from a previous interrupted session
  Future<void> _recoverPendingSegments() async {
    if (_pendingSegmentsPath == null) return;

    final file = File(_pendingSegmentsPath!);
    if (!await file.exists()) {
      debugPrint('[AutoPauseTranscription] No pending segments to recover');
      return;
    }

    try {
      final jsonString = await file.readAsString();
      final List<dynamic> jsonList = jsonDecode(jsonString) as List<dynamic>;

      final pendingSegments = jsonList
          .map((json) => PersistedSegment.fromJson(json as Map<String, dynamic>))
          .where((s) =>
              s.status == TranscriptionSegmentStatus.pending ||
              s.status == TranscriptionSegmentStatus.processing ||
              s.status == TranscriptionSegmentStatus.interrupted)
          .toList();

      if (pendingSegments.isEmpty) {
        debugPrint('[AutoPauseTranscription] No pending segments to recover');
        await file.delete();
        return;
      }

      debugPrint('[AutoPauseTranscription] 🔄 Recovering ${pendingSegments.length} pending segments');

      for (final segment in pendingSegments) {
        // Check if audio file still exists
        final audioFile = File(segment.audioFilePath);
        if (!await audioFile.exists()) {
          debugPrint('[AutoPauseTranscription] ⚠️ Audio file missing for segment ${segment.index}');
          await _updatePersistedSegmentStatus(
            segment.index,
            TranscriptionSegmentStatus.failed,
            text: '[Audio file missing]',
          );
          continue;
        }

        // Extract segment audio from the file
        try {
          final audioBytes = await audioFile.readAsBytes();
          final wavHeaderSize = 44; // Standard WAV header
          final startOffset = segment.startOffsetBytes + wavHeaderSize;
          final endOffset = startOffset + (segment.durationSamples * 2);

          if (endOffset > audioBytes.length) {
            debugPrint('[AutoPauseTranscription] ⚠️ Segment ${segment.index} exceeds audio file length');
            await _updatePersistedSegmentStatus(
              segment.index,
              TranscriptionSegmentStatus.failed,
              text: '[Invalid audio range]',
            );
            continue;
          }

          // Convert bytes to samples
          final segmentBytes = audioBytes.sublist(startOffset, endOffset);
          final samples = _bytesToInt16(Uint8List.fromList(segmentBytes));

          debugPrint('[AutoPauseTranscription] 🔄 Queueing recovered segment ${segment.index} (${samples.length} samples)');

          // Queue for transcription
          _queueSegmentForProcessing(samples, recoveredIndex: segment.index);
        } catch (e) {
          debugPrint('[AutoPauseTranscription] ❌ Failed to recover segment ${segment.index}: $e');
          await _updatePersistedSegmentStatus(
            segment.index,
            TranscriptionSegmentStatus.failed,
            text: '[Recovery failed: $e]',
          );
        }
      }
    } catch (e) {
      debugPrint('[AutoPauseTranscription] ❌ Failed to parse pending segments: $e');
      // Delete corrupted file
      await file.delete();
    }
  }

  /// Save a segment to persistent storage before transcription
  Future<void> _persistSegment(PersistedSegment segment) async {
    if (_pendingSegmentsPath == null) return;

    try {
      final file = File(_pendingSegmentsPath!);
      List<PersistedSegment> segments = [];

      // Load existing segments
      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(jsonString) as List<dynamic>;
        segments = jsonList
            .map((json) => PersistedSegment.fromJson(json as Map<String, dynamic>))
            .toList();
      }

      // Add or update segment
      final existingIndex = segments.indexWhere((s) => s.index == segment.index);
      if (existingIndex != -1) {
        segments[existingIndex] = segment;
      } else {
        segments.add(segment);
      }

      // Write back
      await file.writeAsString(jsonEncode(segments.map((s) => s.toJson()).toList()));
      debugPrint('[AutoPauseTranscription] 💾 Persisted segment ${segment.index}');
    } catch (e) {
      debugPrint('[AutoPauseTranscription] ⚠️ Failed to persist segment: $e');
    }
  }

  /// Update a persisted segment's status
  Future<void> _updatePersistedSegmentStatus(
    int index,
    TranscriptionSegmentStatus status, {
    String? text,
  }) async {
    if (_pendingSegmentsPath == null) return;

    try {
      final file = File(_pendingSegmentsPath!);
      if (!await file.exists()) return;

      final jsonString = await file.readAsString();
      final List<dynamic> jsonList = jsonDecode(jsonString) as List<dynamic>;
      final segments = jsonList
          .map((json) => PersistedSegment.fromJson(json as Map<String, dynamic>))
          .toList();

      final segmentIdx = segments.indexWhere((s) => s.index == index);
      if (segmentIdx == -1) return;

      segments[segmentIdx] = segments[segmentIdx].copyWith(
        status: status,
        transcribedText: text,
        completedAt: status == TranscriptionSegmentStatus.completed ||
                status == TranscriptionSegmentStatus.failed
            ? DateTime.now()
            : null,
      );

      await file.writeAsString(jsonEncode(segments.map((s) => s.toJson()).toList()));
    } catch (e) {
      debugPrint('[AutoPauseTranscription] ⚠️ Failed to update persisted segment: $e');
    }
  }

  /// Clean up completed segments from persistence
  Future<void> _cleanupCompletedSegments() async {
    if (_pendingSegmentsPath == null) return;

    try {
      final file = File(_pendingSegmentsPath!);
      if (!await file.exists()) return;

      final jsonString = await file.readAsString();
      final List<dynamic> jsonList = jsonDecode(jsonString) as List<dynamic>;
      final segments = jsonList
          .map((json) => PersistedSegment.fromJson(json as Map<String, dynamic>))
          .where((s) =>
              s.status != TranscriptionSegmentStatus.completed &&
              s.status != TranscriptionSegmentStatus.failed)
          .toList();

      if (segments.isEmpty) {
        await file.delete();
        debugPrint('[AutoPauseTranscription] 🧹 Cleaned up all completed segments');
      } else {
        await file.writeAsString(jsonEncode(segments.map((s) => s.toJson()).toList()));
      }
    } catch (e) {
      debugPrint('[AutoPauseTranscription] ⚠️ Failed to cleanup segments: $e');
    }
  }

  /// Start auto-pause recording
  Future<bool> startRecording({
    double vadEnergyThreshold =
        200.0, // With noise filtering, can use lower threshold
    Duration silenceThreshold = const Duration(seconds: 1),
    Duration minChunkDuration = const Duration(milliseconds: 500),
    Duration maxChunkDuration = const Duration(seconds: 30),
  }) async {
    if (_isRecording) {
      debugPrint('[AutoPauseTranscription] Already recording');
      return false;
    }

    try {
      // On Android/iOS, try to request permission if not already granted
      // But don't fail here - let the actual recording attempt be the authority
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          final status = await Permission.microphone.status;
          debugPrint('[AutoPauseTranscription] Mic permission status: $status');
          if (!status.isGranted && !status.isLimited) {
            debugPrint('[AutoPauseTranscription] Requesting microphone permission...');
            final requestResult = await Permission.microphone.request();
            debugPrint('[AutoPauseTranscription] Permission request result: $requestResult');
            // Don't return false here - the actual startStream call will fail
            // if permission is truly denied, and we'll handle it there
          }
        } catch (e) {
          debugPrint('[AutoPauseTranscription] Permission check failed: $e - proceeding anyway');
        }
      }

      // Ensure temp directory exists
      if (_tempDirectory == null) {
        await initialize();
      }

      // Initialize noise filter (removes low-frequency background noise)
      _noiseFilter = SimpleNoiseFilter(
        cutoffFreq:
            80.0, // Remove frequencies below 80Hz (fans, AC hum, rumble)
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

      // Set final audio file path using recordings subfolder (7-day retention for crash recovery)
      final fileSystem = FileSystemService.daily();
      _audioFilePath = await fileSystem.getRecordingTempPath();

      // Initialize streaming WAV file with placeholder header
      // Header will be updated with correct size when recording stops
      await _initializeStreamingWavFile(_audioFilePath!);

      // Start recording with stream
      // Note: Keeping minimal OS processing to reduce CoreAudio instability
      debugPrint('[AutoPauseTranscription] 🎙️ Starting audio stream...');
      Stream<Uint8List> stream;
      try {
        stream = await _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
            // Minimal OS processing to reduce CoreAudio issues
            echoCancel: false, // Not needed for voice notes
            autoGain: true, // Keep for consistent volume
            noiseSuppress: false, // We handle filtering ourselves
          ),
        );
        debugPrint('[AutoPauseTranscription] ✅ Audio stream started successfully');
      } catch (e) {
        debugPrint('[AutoPauseTranscription] ❌ Failed to start audio stream: $e');
        // This is where we actually fail if permission is denied
        return false;
      }

      debugPrint(
        '[AutoPauseTranscription] Audio config: autoGain=true, echoCancel=false, noiseSuppress=false',
      );

      _isRecording = true;
      _recordingStartTime = DateTime.now();
      _segments.clear();
      _nextSegmentIndex = 1;
      _allAudioSamples.clear();
      _processingQueue.clear();
      _totalSamplesWritten = 0;

      // Reset streaming state
      _rollingAudioBuffer = [];
      _previousTranscription = null;
      _confirmedText = '';
      _tentativeText = '';
      _interimText = '';
      _confirmedSegments.clear();
      _segmentToConfirmedIndex.clear();
      _segmentStartOffset = 0;
      _lastVadPauseTime = null;

      // Set initial model status - check if already ready
      final isModelReady = await _transcriptionService.isReady();
      _modelStatus = isModelReady
          ? TranscriptionModelStatus.ready
          : TranscriptionModelStatus.initializing;
      debugPrint('[AutoPauseTranscription] Initial model status: $_modelStatus (isReady=$isModelReady)');

      // Notify background service that recording started
      // This starts the foreground service on Android
      await _backgroundService.onRecordingStarted(_audioFilePath);

      // Reset stream health monitoring
      _lastAudioChunkTime = DateTime.now();
      _audioChunkCount = 0;

      // NOTE: Re-transcription loop disabled - using richardtate VAD-only approach
      // No interim text during speech, only final text after VAD pauses
      // _startReTranscriptionLoop();

      // Start recording duration timer for UI updates
      _startRecordingDurationTimer();

      // Emit initial streaming state
      _emitStreamingState();

      // Process audio stream through VAD chunker (store subscription for cleanup)
      debugPrint('[AutoPauseTranscription] 🎧 Setting up stream listener...');
      _audioStreamSubscription = stream.listen(
        _processAudioChunk,
        onError: (error, stackTrace) {
          debugPrint('[AutoPauseTranscription] ❌ STREAM ERROR: $error');
          debugPrint('[AutoPauseTranscription] Stack trace: $stackTrace');
          debugPrint(
            '[AutoPauseTranscription] Chunks received before error: $_audioChunkCount',
          );
          debugPrint(
            '[AutoPauseTranscription] Time since last chunk: ${DateTime.now().difference(_lastAudioChunkTime ?? DateTime.now())}',
          );
        },
        onDone: () {
          debugPrint('[AutoPauseTranscription] ⚠️ STREAM COMPLETED/CLOSED');
          debugPrint(
            '[AutoPauseTranscription] Total chunks received: $_audioChunkCount',
          );
          debugPrint('[AutoPauseTranscription] Recording state: $_isRecording');
        },
        cancelOnError: false, // Keep stream alive on errors
      );

      // Start health check timer (warns if no audio chunks received)
      _startStreamHealthCheck();

      debugPrint('[AutoPauseTranscription] ✅ Recording started with VAD');
      return true;
    } catch (e) {
      debugPrint('[AutoPauseTranscription] Failed to start: $e');
      return false;
    }
  }

  /// Process incoming audio chunk from stream
  void _processAudioChunk(Uint8List audioBytes) {
    // Update stream health tracking
    _lastAudioChunkTime = DateTime.now();
    _audioChunkCount++;

    // Log first chunk to confirm streaming is working
    if (_audioChunkCount == 1) {
      debugPrint(
        '[AutoPauseTranscription] ✅ First audio chunk received! (${audioBytes.length} bytes)',
      );
    }

    if (!_isRecording || _chunker == null || _noiseFilter == null) {
      debugPrint(
        '[AutoPauseTranscription] ⚠️ Received audio chunk but not ready: isRecording=$_isRecording, chunker=${_chunker != null}, filter=${_noiseFilter != null}',
      );
      return;
    }

    // Convert bytes to int16 samples
    final rawSamples = _bytesToInt16(audioBytes);

    // Validate we got samples
    if (rawSamples.isEmpty) {
      debugPrint(
        '[AutoPauseTranscription] ⚠️ Received empty sample array from ${audioBytes.length} bytes',
      );
      return;
    }

    // Apply noise filter BEFORE VAD (removes low-frequency background noise)
    final cleanSamples = _noiseFilter!.process(rawSamples);

    // Emit debug metrics for visualization (every 10ms frame)
    final rawEnergy = _calculateRMS(rawSamples);
    final cleanEnergy = _calculateRMS(cleanSamples);
    final reduction = rawEnergy > 0
        ? ((1 - cleanEnergy / rawEnergy) * 100)
        : 0.0;

    // Log audio levels periodically to help diagnose low volume issues
    if (_audioChunkCount % 100 == 1) {
      debugPrint(
        '[AutoPauseTranscription] Audio levels - Raw: ${rawEnergy.toStringAsFixed(1)}, Clean: ${cleanEnergy.toStringAsFixed(1)}, Samples: ${rawSamples.length}',
      );
    }

    if (!_debugMetricsController.isClosed) {
      _debugMetricsController.add(
        AudioDebugMetrics(
          rawEnergy: rawEnergy,
          cleanEnergy: cleanEnergy,
          filterReduction: reduction,
          vadThreshold: _chunker!.stats.vadStats.isSpeaking ? cleanEnergy : 0,
          isSpeech: cleanEnergy > 200.0, // Using current threshold
          timestamp: DateTime.now(),
        ),
      );
    }

    // Save clean audio to buffer (for transcription segments)
    _allAudioSamples.add(cleanSamples);

    // Add to rolling buffer for streaming re-transcription
    _rollingAudioBuffer.addAll(cleanSamples);
    // Trim to max size (keep last 30s)
    if (_rollingAudioBuffer.length > _rollingBufferMaxSamples) {
      _rollingAudioBuffer = _rollingAudioBuffer.sublist(
        _rollingAudioBuffer.length - _rollingBufferMaxSamples,
      );
    }

    // Stream audio to disk incrementally to avoid memory buildup
    _streamAudioToDisk(cleanSamples);

    // Process clean audio through SmartChunker (VAD + auto-chunking)
    _chunker!.processSamples(cleanSamples);

    // Emit VAD activity for UI
    final isSpeaking = _chunker!.stats.vadStats.isSpeaking;
    if (!_vadActivityController.isClosed) {
      _vadActivityController.add(isSpeaking);
    }

    // Debug: Show VAD stats periodically
    if (_audioChunkCount % 100 == 0) {
      // Every ~1 second (100 chunks)
      final stats = _chunker!.stats;
      final memoryMB = (_allAudioSamples.fold<int>(0, (sum, s) => sum + s.length) * 2) / (1024 * 1024);
      debugPrint(
        '[AutoPauseTranscription] VAD Stats: '
        'Speech: ${stats.vadStats.speechDuration.inMilliseconds}ms, '
        'Silence: ${stats.vadStats.silenceDuration.inMilliseconds}ms, '
        'Buffer: ${stats.bufferDuration.inSeconds}s, '
        'Disk: ${(_totalSamplesWritten / 16000).toStringAsFixed(1)}s, '
        'Memory: ${memoryMB.toStringAsFixed(1)}MB',
      );
    }
  }

  /// Initialize WAV file for streaming audio data
  Future<void> _initializeStreamingWavFile(String path) async {
    final file = File(path);
    _audioFileSink = file.openWrite();

    // Write WAV header with placeholder size (will update on close)
    // RIFF header
    _audioFileSink!.add([0x52, 0x49, 0x46, 0x46]); // "RIFF"
    _audioFileSink!.add([0x00, 0x00, 0x00, 0x00]); // Placeholder file size - 8
    _audioFileSink!.add([0x57, 0x41, 0x56, 0x45]); // "WAVE"

    // fmt chunk
    _audioFileSink!.add([0x66, 0x6D, 0x74, 0x20]); // "fmt "
    _audioFileSink!.add([0x10, 0x00, 0x00, 0x00]); // Chunk size (16)
    _audioFileSink!.add([0x01, 0x00]); // Audio format (1 = PCM)
    _audioFileSink!.add([0x01, 0x00]); // Num channels (1 = mono)
    _audioFileSink!.add([0x80, 0x3E, 0x00, 0x00]); // Sample rate (16000)
    _audioFileSink!.add([0x00, 0x7D, 0x00, 0x00]); // Byte rate (32000)
    _audioFileSink!.add([0x02, 0x00]); // Block align (2)
    _audioFileSink!.add([0x10, 0x00]); // Bits per sample (16)

    // data chunk header
    _audioFileSink!.add([0x64, 0x61, 0x74, 0x61]); // "data"
    _audioFileSink!.add([0x00, 0x00, 0x00, 0x00]); // Placeholder data size

    await _audioFileSink!.flush();
    _totalSamplesWritten = 0;

    debugPrint('[AutoPauseTranscription] Initialized streaming WAV: $path');
  }

  /// Stream audio samples to disk
  void _streamAudioToDisk(List<int> samples) {
    if (_audioFileSink == null) return;

    // Convert samples to bytes and write
    final bytes = Uint8List(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      final sample = samples[i];
      bytes[i * 2] = sample & 0xFF;
      bytes[i * 2 + 1] = (sample >> 8) & 0xFF;
    }
    _audioFileSink!.add(bytes);
    _totalSamplesWritten += samples.length;

    // Periodically flush to ensure data is persisted
    if (_totalSamplesWritten % _flushThreshold < samples.length) {
      _audioFileSink!.flush();
      debugPrint('[AutoPauseTranscription] Flushed ${_totalSamplesWritten ~/ 16000}s of audio to disk');
    }
  }

  /// Finalize WAV file by updating header with correct sizes
  Future<void> _finalizeStreamingWavFile() async {
    if (_audioFileSink == null || _audioFilePath == null) return;

    await _audioFileSink!.flush();
    await _audioFileSink!.close();
    _audioFileSink = null;

    // Update WAV header with correct sizes
    final file = File(_audioFilePath!);
    final raf = await file.open(mode: FileMode.writeOnlyAppend);

    final dataSize = _totalSamplesWritten * 2; // 2 bytes per sample
    final fileSize = dataSize + 36; // WAV header is 44 bytes, so file size - 8 = 36 + dataSize

    // Update RIFF chunk size at offset 4
    await raf.setPosition(4);
    await raf.writeFrom([
      fileSize & 0xFF,
      (fileSize >> 8) & 0xFF,
      (fileSize >> 16) & 0xFF,
      (fileSize >> 24) & 0xFF,
    ]);

    // Update data chunk size at offset 40
    await raf.setPosition(40);
    await raf.writeFrom([
      dataSize & 0xFF,
      (dataSize >> 8) & 0xFF,
      (dataSize >> 16) & 0xFF,
      (dataSize >> 24) & 0xFF,
    ]);

    await raf.close();

    debugPrint('[AutoPauseTranscription] Finalized WAV: ${dataSize ~/ 1024}KB, ${_totalSamplesWritten ~/ 16000}s');
  }

  /// Start periodic health check for audio stream
  void _startStreamHealthCheck() {
    _streamHealthCheckTimer?.cancel();

    // Initially healthy
    if (!_streamHealthController.isClosed) {
      _streamHealthController.add(true);
    }

    _streamHealthCheckTimer = Timer.periodic(const Duration(seconds: 2), (
      timer,
    ) {
      if (!_isRecording) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      final timeSinceLastChunk = _lastAudioChunkTime != null
          ? now.difference(_lastAudioChunkTime!)
          : null;

      if (timeSinceLastChunk != null &&
          timeSinceLastChunk > const Duration(seconds: 5)) {
        // Stream is broken - notify UI
        if (!_streamHealthController.isClosed) {
          _streamHealthController.add(false);
        }
        debugPrint(
          '[AutoPauseTranscription] ⚠️ Audio stream broken (${timeSinceLastChunk.inSeconds}s since last chunk, $_audioChunkCount total chunks)',
        );

        // Log diagnostic info once when stream breaks
        if (timeSinceLastChunk.inSeconds == 5 ||
            timeSinceLastChunk.inSeconds == 6) {
          debugPrint('[AutoPauseTranscription] Possible causes:');
          debugPrint(
            '[AutoPauseTranscription]   - System audio service issue (try: sudo killall coreaudiod)',
          );
          debugPrint(
            '[AutoPauseTranscription]   - Microphone permission revoked',
          );
          debugPrint(
            '[AutoPauseTranscription]   - Another app captured audio input',
          );
          debugPrint(
            '[AutoPauseTranscription]   - macOS audio driver issue (reboot may help)',
          );
        }
      } else {
        // Stream is healthy
        if (!_streamHealthController.isClosed) {
          _streamHealthController.add(true);
        }
      }
    });
  }

  /// Stop stream health check
  void _stopStreamHealthCheck() {
    _streamHealthCheckTimer?.cancel();
    _streamHealthCheckTimer = null;
    debugPrint('[AutoPauseTranscription] 🔍 Stream health monitoring stopped');
  }

  // ============================================================
  // PHASE 1: STREAMING TRANSCRIPTION - Real-time feedback
  // ============================================================

  /// Start the re-transcription loop for streaming feedback
  void _startReTranscriptionLoop() {
    _reTranscriptionTimer?.cancel();

    debugPrint('[AutoPauseTranscription] 🔄 Starting re-transcription loop (every ${_reTranscriptionInterval.inSeconds}s)');

    _reTranscriptionTimer = Timer.periodic(_reTranscriptionInterval, (_) async {
      // Only re-transcribe if we're recording and VAD detects speech
      if (!_isRecording) return;
      if (_chunker == null) return;

      final isSpeaking = _chunker!.stats.vadStats.isSpeaking;
      final hasSpeech = _chunker!.stats.vadStats.speechDuration > const Duration(milliseconds: 500);
      final bufferSeconds = _rollingAudioBuffer.length / 16000;

      // Check if model became ready while we were waiting
      // This updates UI immediately when init completes mid-recording
      if (_modelStatus == TranscriptionModelStatus.initializing) {
        final isReady = await _transcriptionService.isReady();
        if (isReady) {
          debugPrint('[AutoPauseTranscription] ✅ Model became ready during recording!');
          _updateModelStatus(TranscriptionModelStatus.ready);
        }
      }

      debugPrint('[AutoPauseTranscription] 🔄 Re-transcription check: isSpeaking=$isSpeaking, hasSpeech=$hasSpeech, buffer=${bufferSeconds.toStringAsFixed(1)}s, modelStatus=$_modelStatus');

      // Re-transcribe when there's active speech, recent speech, OR we have a decent buffer
      // The buffer check ensures we transcribe even if VAD misses initial speech
      if (isSpeaking || hasSpeech || bufferSeconds >= 3.0) {
        _transcribeRollingBuffer();
      }
    });
  }

  /// Stop the re-transcription loop
  void _stopReTranscriptionLoop() {
    _reTranscriptionTimer?.cancel();
    _reTranscriptionTimer = null;
    debugPrint('[AutoPauseTranscription] 🔄 Re-transcription loop stopped');
  }

  /// Start recording duration timer for UI updates
  void _startRecordingDurationTimer() {
    _recordingDurationTimer?.cancel();

    _recordingDurationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isRecording) return;
      _emitStreamingState();
    });
  }

  /// Stop recording duration timer
  void _stopRecordingDurationTimer() {
    _recordingDurationTimer?.cancel();
    _recordingDurationTimer = null;
  }

  /// Transcribe the rolling buffer and apply LocalAgreement-2
  ///
  /// LocalAgreement-2 algorithm:
  /// 1. Transcribe current buffer
  /// 2. Find longest common prefix with previous transcription
  /// 3. If common prefix extends beyond tentative → promote to confirmed
  /// 4. Current common prefix becomes tentative
  /// 5. Everything after common prefix is interim (may change)
  Future<void> _transcribeRollingBuffer() async {
    if (_isReTranscribing) {
      return; // Already processing
    }
    if (_rollingAudioBuffer.isEmpty || _rollingAudioBuffer.length < 16000) {
      return; // Not enough audio (need at least 1 second)
    }

    _isReTranscribing = true;

    try {
      // Check model status
      final isReady = await _transcriptionService.isReady();
      if (!isReady) {
        if (_modelStatus != TranscriptionModelStatus.initializing) {
          _updateModelStatus(TranscriptionModelStatus.initializing);
        }
      }

      // Transcribe full buffer
      final samplesToTranscribe = List<int>.from(_rollingAudioBuffer);
      final durationSec = samplesToTranscribe.length / 16000;
      debugPrint('[LocalAgreement] Transcribing ${durationSec.toStringAsFixed(1)}s of audio');

      final fileSystem = FileSystemService.daily();
      final tempPath = await fileSystem.getTranscriptionSegmentPath(-1);
      await _saveSamplesToWav(samplesToTranscribe, tempPath);

      final result = await _transcriptionService.transcribeAudio(tempPath);

      if (_modelStatus != TranscriptionModelStatus.ready) {
        _updateModelStatus(TranscriptionModelStatus.ready);
      }

      try {
        await File(tempPath).delete();
      } catch (_) {}

      final currentTranscription = result.text.trim();
      if (currentTranscription.isEmpty) {
        _previousTranscription = currentTranscription;
        return;
      }

      // === LocalAgreement-2 Algorithm ===
      _applyLocalAgreement(currentTranscription);

      if (!_interimTextController.isClosed) {
        _interimTextController.add(_interimText);
      }
      _emitStreamingState();

      // Debug output
      final display = '$_confirmedText $_tentativeText $_interimText'.trim();
      if (display.isNotEmpty) {
        final preview = display.length > 60 ? '${display.substring(0, 60)}...' : display;
        debugPrint('[LocalAgreement] Display: "$preview"');
        debugPrint('[LocalAgreement] Confirmed: ${_confirmedText.split(' ').length} words, '
            'Tentative: ${_tentativeText.split(' ').length} words, '
            'Interim: ${_interimText.split(' ').length} words');
      }
    } catch (e) {
      debugPrint('[LocalAgreement] Transcription failed: $e');
    } finally {
      _isReTranscribing = false;
    }
  }

  /// Final transcription for any remaining audio in rolling buffer
  /// Simple: just transcribe what's there and add to confirmedSegments
  Future<void> _doFinalTranscription() async {
    if (_rollingAudioBuffer.isEmpty) return;

    try {
      debugPrint('[AutoPauseTranscription] Final transcription: ${_rollingAudioBuffer.length} samples');

      final samplesToTranscribe = List<int>.from(_rollingAudioBuffer);

      // Save to temp file
      final fileSystem = FileSystemService.daily();
      final tempPath = await fileSystem.getTranscriptionSegmentPath(-999);

      await _saveSamplesToWav(samplesToTranscribe, tempPath);

      // Transcribe
      final result = await _transcriptionService.transcribeAudio(tempPath);

      // Clean up temp file
      try {
        await File(tempPath).delete();
      } catch (_) {}

      final transcribedText = result.text.trim();
      if (transcribedText.isNotEmpty) {
        _confirmedSegments.add(transcribedText);
        debugPrint('[AutoPauseTranscription] Final segment: "$transcribedText"');
      }

      _emitStreamingState();
    } catch (e) {
      debugPrint('[AutoPauseTranscription] Final transcription failed: $e');
    }
  }

  /// Apply LocalAgreement-2 algorithm to update confirmed/tentative/interim text
  ///
  /// SIMPLIFIED APPROACH: Since the rolling buffer produces the FULL transcription
  /// of whatever audio is currently in it (up to 30 seconds), we should just display
  /// that transcription directly. The buffer naturally slides forward as recording
  /// continues, so the transcription is always current.
  ///
  /// We use LocalAgreement only to determine visual styling (confirmed vs tentative),
  /// NOT to accumulate text across transcriptions.
  void _applyLocalAgreement(String currentTranscription) {
    if (_previousTranscription == null) {
      // First transcription - everything is interim (may change)
      _confirmedText = '';
      _tentativeText = '';
      _interimText = currentTranscription;
      _previousTranscription = currentTranscription;
      return;
    }

    // Find longest common prefix between previous and current transcription
    final commonPrefix = _longestCommonWordPrefix(_previousTranscription!, currentTranscription);
    final commonPrefixWords = commonPrefix.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final currentWords = currentTranscription.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

    debugPrint('[LocalAgreement] Common prefix: $commonPrefixWords words, Current: $currentWords words');

    // The common prefix is stable (appeared in both previous and current transcription)
    // Everything after it in current transcription is still changing
    _confirmedText = '';  // We don't accumulate - buffer already has full audio
    _tentativeText = commonPrefix;  // Stable across 2 iterations

    if (commonPrefix.length < currentTranscription.length) {
      _interimText = currentTranscription.substring(commonPrefix.length).trim();
    } else {
      _interimText = '';
    }

    _previousTranscription = currentTranscription;
  }

  /// Normalize text for duplicate comparison
  String _normalizeForComparison(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Find the longest common prefix between two strings, word-by-word
  String _longestCommonWordPrefix(String a, String b) {
    final wordsA = a.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final wordsB = b.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

    int matchLen = 0;
    for (int i = 0; i < min(wordsA.length, wordsB.length); i++) {
      if (_wordsMatchFuzzy(wordsA[i], wordsB[i])) {
        matchLen = i + 1;
      } else {
        break;
      }
    }

    return wordsA.take(matchLen).join(' ');
  }

  /// Check if two words match (case-insensitive, ignoring punctuation)
  bool _wordsMatchFuzzy(String a, String b) {
    String normalize(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w]'), '');

    final normA = normalize(a);
    final normB = normalize(b);

    if (normA == normB) return true;

    // Allow small differences (Levenshtein distance <= 1)
    if (normA.length > 2 && normB.length > 2) {
      return _levenshteinDistance(normA, normB) <= 1;
    }

    return false;
  }

  /// Emit current streaming state to UI
  void _emitStreamingState() {
    if (_streamingStateController.isClosed) return;

    final state = StreamingTranscriptionState(
      confirmedText: _confirmedText,
      tentativeText: _tentativeText,
      interimText: _interimText,
      confirmedSegments: List.unmodifiable(_confirmedSegments),
      isRecording: _isRecording,
      isProcessing: _isProcessingQueue,
      recordingDuration: _recordingStartTime != null
          ? DateTime.now().difference(_recordingStartTime!)
          : Duration.zero,
      vadLevel: _chunker?.stats.vadStats.isSpeaking == true ? 1.0 : 0.0,
      modelStatus: _modelStatus,
    );

    _streamingStateController.add(state);
  }

  /// Update model status and emit state
  void _updateModelStatus(TranscriptionModelStatus status) {
    _modelStatus = status;
    _emitStreamingState();
  }

  /// Remove overlap between confirmed text and new interim text using fuzzy matching
  /// Only removes from the END of confirmed that matches the BEGINNING of interim
  String _removeOverlapFuzzy(String confirmed, String interim) {
    if (confirmed.isEmpty || interim.isEmpty) return interim;

    // Normalize for comparison (lowercase, strip punctuation, collapse whitespace)
    String normalize(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '') // Remove punctuation
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final confirmedNorm = normalize(confirmed);
    final interimNorm = normalize(interim);

    // Case 1: Confirmed is a prefix of interim (exact or fuzzy)
    if (interimNorm.startsWith(confirmedNorm)) {
      // Find where to cut in original interim (accounting for whitespace differences)
      return _cutMatchingPrefix(interim, confirmed.length);
    }

    // Case 2: Find longest suffix of confirmed that matches prefix of interim
    // Use word-based matching for fuzziness
    final confirmedWords = confirmedNorm.split(' ').where((w) => w.isNotEmpty).toList();
    final interimWords = interimNorm.split(' ').where((w) => w.isNotEmpty).toList();

    if (confirmedWords.isEmpty || interimWords.isEmpty) return interim;

    // Try matching last N words of confirmed with first N words of interim
    int bestMatchWords = 0;
    for (int n = min(confirmedWords.length, interimWords.length); n >= 2; n--) {
      final confirmedSuffix = confirmedWords.sublist(confirmedWords.length - n);
      final interimPrefix = interimWords.sublist(0, n);

      // Check if they match (with some tolerance for minor differences)
      if (_wordListsMatchFuzzy(confirmedSuffix, interimPrefix)) {
        bestMatchWords = n;
        break;
      }
    }

    if (bestMatchWords > 0) {
      // Remove the first bestMatchWords words from interim
      // But we need to work with the original words (with punctuation)
      final interimWordsList = interim.split(RegExp(r'\s+'));
      if (bestMatchWords < interimWordsList.length) {
        return interimWordsList.sublist(bestMatchWords).join(' ').trim();
      } else {
        return '';
      }
    }

    // No significant overlap found
    return interim;
  }

  /// Check if two word lists match with fuzzy tolerance
  bool _wordListsMatchFuzzy(List<String> a, List<String> b) {
    if (a.length != b.length) return false;

    int matches = 0;
    for (int i = 0; i < a.length; i++) {
      if (a[i] == b[i]) {
        matches++;
      } else if (_levenshteinDistance(a[i], b[i]) <= 2) {
        // Allow small typos (Levenshtein distance <= 2)
        matches++;
      }
    }

    // Require at least 80% of words to match
    return matches >= (a.length * 0.8).ceil();
  }

  /// Simple Levenshtein distance for fuzzy word matching
  int _levenshteinDistance(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    List<int> prev = List.generate(b.length + 1, (i) => i);
    List<int> curr = List.filled(b.length + 1, 0);

    for (int i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (int j = 1; j <= b.length; j++) {
        int cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = min(min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      final temp = prev;
      prev = curr;
      curr = temp;
    }

    return prev[b.length];
  }

  /// Cut a matching prefix from interim, accounting for whitespace differences
  String _cutMatchingPrefix(String interim, int confirmedLength) {
    // Skip roughly confirmedLength characters, then find next word boundary
    int pos = min(confirmedLength, interim.length);

    // Find next space to get clean word boundary
    while (pos < interim.length && interim[pos] != ' ') {
      pos++;
    }

    // Skip any whitespace
    while (pos < interim.length && interim[pos] == ' ') {
      pos++;
    }

    return pos < interim.length ? interim.substring(pos).trim() : '';
  }

  /// Handle chunk ready from SmartChunker (VAD detected pause)
  ///
  /// Richardtate approach: On VAD pause, transcribe ONLY the chunk audio,
  /// add result to confirmedSegments, then clear the rolling buffer.
  /// This avoids duplicates by never re-transcribing overlapping audio.
  void _handleChunk(List<int> samples) {
    final duration = Duration(
      milliseconds: (samples.length / 16).round(),
    ); // 16 samples/ms at 16kHz

    debugPrint(
      '[StreamingTranscription] VAD pause detected! '
      'Duration: ${duration.inSeconds}s (${samples.length} samples)',
    );

    // Queue chunk for transcription - this will add to confirmedSegments
    _queueSegmentForProcessing(samples);

    // Clear rolling buffer state - we're done with this audio
    _rollingAudioBuffer.clear();
    _previousTranscription = null;
    _confirmedText = '';
    _tentativeText = '';
    _interimText = '';

    // Update segment start offset for next segment
    _segmentStartOffset = _totalSamplesWritten * 2; // Bytes
  }

  /// Stop recording and transcribe final segment
  /// Pause recording (manual pause in addition to auto-pause)
  Future<void> pauseRecording() async {
    if (!_isRecording) return;
    try {
      await _recorder.pause();
      debugPrint('[AutoPauseTranscription] Recording paused');
    } catch (e) {
      debugPrint('[AutoPauseTranscription] Failed to pause: $e');
    }
  }

  /// Resume recording
  Future<void> resumeRecording() async {
    if (!_isRecording) return;
    try {
      await _recorder.resume();
      debugPrint('[AutoPauseTranscription] Recording resumed');
    } catch (e) {
      debugPrint('[AutoPauseTranscription] Failed to resume: $e');
    }
  }

  Future<String?> stopRecording() async {
    if (!_isRecording) return null;

    try {
      debugPrint('[AutoPauseTranscription] 🛑 Stopping recording...');
      debugPrint(
        '[AutoPauseTranscription] Total audio chunks received: $_audioChunkCount',
      );

      // Stop timers first
      _stopStreamHealthCheck();
      _stopReTranscriptionLoop();
      _stopRecordingDurationTimer();

      // Cancel audio stream subscription before stopping recorder
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // Stop recorder
      await _recorder.stop();
      _isRecording = false;

      // Wait for stream to settle
      await Future.delayed(const Duration(milliseconds: 300));

      // Flush chunker FIRST - this triggers _handleChunk for any remaining audio
      // The chunker holds audio that hasn't hit a VAD pause yet
      if (_chunker != null) {
        debugPrint('[AutoPauseTranscription] Flushing chunker for final audio...');
        _chunker!.flush();
        _chunker = null;
      }

      // Wait for any queued segments to finish processing
      while (_isProcessingQueue) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // If there's still audio in rolling buffer (after VAD flush), transcribe it
      // This catches edge cases where flush didn't produce a chunk
      if (_rollingAudioBuffer.length > 8000) { // At least 0.5s of audio
        debugPrint('[AutoPauseTranscription] Transcribing remaining buffer: ${_rollingAudioBuffer.length} samples');
        await _doFinalTranscription();
      }

      // Reset noise filter for next recording
      if (_noiseFilter != null) {
        _noiseFilter!.reset();
        _noiseFilter = null;
      }

      // Emit final streaming state
      _emitStreamingState();

      debugPrint(
        '[AutoPauseTranscription] Recording stopped, transcription continuing in background...',
      );
      debugPrint(
        '[AutoPauseTranscription] Queue: ${_processingQueue.length}, Active: $_activeTranscriptions',
      );
      debugPrint(
        '[AutoPauseTranscription] Confirmed segments: ${_confirmedSegments.length}',
      );

      // Finalize WAV file (streaming approach - audio already written to disk)
      await _finalizeStreamingWavFile();

      // Clear in-memory buffers now that audio is safely on disk
      _allAudioSamples.clear();
      _rollingAudioBuffer.clear();
      _recordingStartTime = null;

      // Notify background service that recording stopped
      // This stops the foreground service on Android
      await _backgroundService.onRecordingStopped();

      debugPrint('[AutoPauseTranscription] Recording stopped: $_audioFilePath');
      return _audioFilePath;
    } catch (e) {
      debugPrint('[AutoPauseTranscription] Failed to stop: $e');
      return null;
    }
  }

  /// Cancel recording without saving
  Future<void> cancelRecording() async {
    if (!_isRecording) return;

    try {
      debugPrint('[AutoPauseTranscription] ❌ Cancelling recording...');
      debugPrint(
        '[AutoPauseTranscription] Audio chunks received: $_audioChunkCount',
      );

      // Stop all timers
      _stopStreamHealthCheck();
      _stopReTranscriptionLoop();
      _stopRecordingDurationTimer();

      // Cancel audio stream subscription before stopping recorder
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // Stop recorder
      await _recorder.stop();
      _isRecording = false;
      _recordingStartTime = null;

      // Clear chunker
      if (_chunker != null) {
        _chunker = null;
      }

      // Close and delete the streaming WAV file
      if (_audioFileSink != null) {
        await _audioFileSink!.close();
        _audioFileSink = null;
      }
      if (_audioFilePath != null) {
        final file = File(_audioFilePath!);
        if (await file.exists()) {
          await file.delete();
          debugPrint('[AutoPauseTranscription] Deleted incomplete recording');
        }
      }

      // Clear all data including streaming state
      _segments.clear();
      _allAudioSamples.clear();
      _processingQueue.clear();
      _rollingAudioBuffer.clear();
      _previousTranscription = null;
      _confirmedText = '';
      _tentativeText = '';
      _interimText = '';
      _confirmedSegments.clear();

      // Emit final state
      _emitStreamingState();

      // Notify background service that recording stopped
      await _backgroundService.onRecordingStopped();

      debugPrint('[AutoPauseTranscription] Recording cancelled');
    } catch (e) {
      debugPrint('[AutoPauseTranscription] Failed to cancel: $e');
    }
  }

  /// Queue a segment for transcription (non-blocking)
  ///
  /// Implements backpressure: if queue is full, drops oldest pending segments
  /// If [recoveredIndex] is provided, uses that index (for recovery from persistence)
  void _queueSegmentForProcessing(List<int> samples, {int? recoveredIndex}) {
    // Backpressure: if queue is too large, drop oldest pending segment
    if (_processingQueue.length >= _maxQueueSize) {
      final dropped = _processingQueue.removeAt(0);
      debugPrint(
        '[AutoPauseTranscription] ⚠️ Queue full, dropping segment ${dropped.index}',
      );
      // Update the dropped segment status in UI
      final droppedIdx = _segments.indexWhere((s) => s.index == dropped.index);
      if (droppedIdx != -1) {
        _segments[droppedIdx] = _segments[droppedIdx].copyWith(
          status: TranscriptionSegmentStatus.failed,
          text: '[Skipped - queue full]',
        );
        if (!_segmentStreamController.isClosed) {
          _segmentStreamController.add(_segments[droppedIdx]);
        }
      }
      // Update persistence
      _updatePersistedSegmentStatus(
        dropped.index,
        TranscriptionSegmentStatus.failed,
        text: '[Skipped - queue full]',
      );
    }

    final segmentIndex = recoveredIndex ?? _nextSegmentIndex++;

    final segment = _QueuedSegment(
      index: segmentIndex,
      samples: samples,
    );

    _processingQueue.add(segment);

    // Add pending segment to UI
    _segments.add(
      TranscriptionSegment(
        index: segment.index,
        text: '',
        status: TranscriptionSegmentStatus.pending,
        timestamp: DateTime.now(),
        duration: Duration(milliseconds: (samples.length / 16).round()),
      ),
    );
    if (!_segmentStreamController.isClosed) {
      _segmentStreamController.add(_segments.last);
    }

    // Persist segment for background recovery (only for new segments, not recovered ones)
    if (recoveredIndex == null && _audioFilePath != null) {
      final persistedSegment = PersistedSegment(
        index: segment.index,
        audioFilePath: _audioFilePath!,
        startOffsetBytes: _segmentStartOffset,
        durationSamples: samples.length,
        status: TranscriptionSegmentStatus.pending,
        createdAt: DateTime.now(),
      );
      _persistSegment(persistedSegment);
    }

    // Start processing if not already running
    if (!_isProcessingQueue) {
      _processQueue();
    }
  }

  /// Process queued segments sequentially
  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;
    if (!_processingStreamController.isClosed) {
      _processingStreamController.add(true);
    }

    while (_processingQueue.isNotEmpty) {
      final segment = _processingQueue.removeAt(0);
      await _transcribeSegment(segment);
    }

    _isProcessingQueue = false;
    if (!_processingStreamController.isClosed) {
      _processingStreamController.add(false);
    }
  }

  /// Transcribe a single segment
  Future<void> _transcribeSegment(_QueuedSegment segment) async {
    debugPrint(
      '[AutoPauseTranscription] Transcribing segment ${segment.index}',
    );

    // Update segment status to processing
    final segmentIndex = _segments.indexWhere((s) => s.index == segment.index);
    if (segmentIndex == -1) return;

    _segments[segmentIndex] = _segments[segmentIndex].copyWith(
      status: TranscriptionSegmentStatus.processing,
    );
    if (!_segmentStreamController.isClosed) {
      _segmentStreamController.add(_segments[segmentIndex]);
    }

    // Update persistence status
    await _updatePersistedSegmentStatus(
      segment.index,
      TranscriptionSegmentStatus.processing,
    );

    try {
      // Validate segment has audio data
      if (segment.samples.isEmpty) {
        throw Exception('Segment has no audio data');
      }

      // Save samples to temp WAV file for Whisper
      // Use centralized temp folder with unique path
      final fileSystem = FileSystemService.daily();
      final tempWavPath = await fileSystem.getTranscriptionSegmentPath(segment.index);

      debugPrint(
        '[AutoPauseTranscription] Saving temp WAV: $tempWavPath (${segment.samples.length} samples)',
      );
      await _saveSamplesToWav(segment.samples, tempWavPath);

      // Verify file was created
      final file = File(tempWavPath);
      if (!await file.exists()) {
        throw Exception('Failed to create temp WAV file: $tempWavPath');
      }
      debugPrint(
        '[AutoPauseTranscription] ✅ Temp WAV created: ${await file.length()} bytes',
      );

      // Transcribe (track active transcriptions to prevent premature file cleanup)
      _activeTranscriptions++;
      debugPrint(
        '[AutoPauseTranscription] Active transcriptions: $_activeTranscriptions',
      );

      try {
        final transcriptResult = await _transcriptionService.transcribeAudio(
          tempWavPath,
        );

        // Clean up temp WAV file after successful transcription
        try {
          await file.delete();
          debugPrint(
            '[AutoPauseTranscription] Cleaned up temp WAV: $tempWavPath',
          );
        } catch (e) {
          debugPrint('[AutoPauseTranscription] Failed to delete temp WAV: $e');
        }

        // Check if text is empty (Whisper sometimes returns empty for noise)
        if (transcriptResult.text.trim().isEmpty) {
          throw Exception('Transcription returned empty text');
        }

        final transcribedText = transcriptResult.text.trim();

        // Update with result
        _segments[segmentIndex] = _segments[segmentIndex].copyWith(
          text: transcribedText,
          status: TranscriptionSegmentStatus.completed,
        );
        if (!_segmentStreamController.isClosed) {
          _segmentStreamController.add(_segments[segmentIndex]);
        }

        // Simply add to confirmed segments - no overlap since each chunk is unique audio
        _confirmedSegments.add(transcribedText);
        _emitStreamingState();
        debugPrint('[StreamingTranscription] Segment ${segment.index}: "$transcribedText"');

        // Update persistence
        await _updatePersistedSegmentStatus(
          segment.index,
          TranscriptionSegmentStatus.completed,
          text: transcribedText,
        );

        debugPrint(
          '[AutoPauseTranscription] Segment ${segment.index} done: "$transcribedText"',
        );

        // Cleanup completed segments periodically
        if (segment.index % 5 == 0) {
          await _cleanupCompletedSegments();
        }
      } catch (e) {
        debugPrint('[AutoPauseTranscription] Transcription failed: $e');

        // Clean up temp WAV file on error too
        try {
          final errorFile = File(tempWavPath);
          if (await errorFile.exists()) {
            await errorFile.delete();
          }
        } catch (_) {
          // Ignore cleanup errors
        }

        // Update persistence with failure
        await _updatePersistedSegmentStatus(
          segment.index,
          TranscriptionSegmentStatus.failed,
          text: '[Transcription failed: $e]',
        );

        _segments[segmentIndex] = _segments[segmentIndex].copyWith(
          text: '[Transcription failed]',
          status: TranscriptionSegmentStatus.failed,
        );
        if (!_segmentStreamController.isClosed) {
          _segmentStreamController.add(_segments[segmentIndex]);
        }
      } finally {
        // Always decrement counter, even on error
        _activeTranscriptions--;
        debugPrint(
          '[AutoPauseTranscription] Active transcriptions: $_activeTranscriptions',
        );
      }
    } catch (e) {
      debugPrint('[AutoPauseTranscription] Failed to process segment: $e');
    }
  }

  /// Save int16 samples to WAV file
  Future<void> _saveSamplesToWav(List<int> samples, String filePath) async {
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;

    final dataSize = samples.length * 2; // 2 bytes per sample
    final fileSize = 36 + dataSize;

    final bytes = BytesBuilder();

    // RIFF header
    bytes.add('RIFF'.codeUnits);
    bytes.add(_int32ToBytes(fileSize));
    bytes.add('WAVE'.codeUnits);

    // fmt chunk
    bytes.add('fmt '.codeUnits);
    bytes.add(_int32ToBytes(16)); // fmt chunk size
    bytes.add(_int16ToBytes(1)); // PCM format
    bytes.add(_int16ToBytes(numChannels));
    bytes.add(_int32ToBytes(sampleRate));
    bytes.add(
      _int32ToBytes(sampleRate * numChannels * bitsPerSample ~/ 8),
    ); // byte rate
    bytes.add(_int16ToBytes(numChannels * bitsPerSample ~/ 8)); // block align
    bytes.add(_int16ToBytes(bitsPerSample));

    // data chunk
    bytes.add('data'.codeUnits);
    bytes.add(_int32ToBytes(dataSize));

    // Sample data (int16 little-endian)
    for (final sample in samples) {
      bytes.add(_int16ToBytes(sample));
    }

    // Write to file
    final file = File(filePath);
    await file.writeAsBytes(bytes.toBytes());
  }

  /// Convert int32 to little-endian bytes
  Uint8List _int32ToBytes(int value) {
    return Uint8List(4)
      ..[0] = value & 0xFF
      ..[1] = (value >> 8) & 0xFF
      ..[2] = (value >> 16) & 0xFF
      ..[3] = (value >> 24) & 0xFF;
  }

  /// Convert int16 to little-endian bytes
  Uint8List _int16ToBytes(int value) {
    // Ensure value is in int16 range
    final clamped = value.clamp(-32768, 32767);
    final unsigned = clamped < 0 ? clamped + 65536 : clamped;
    return Uint8List(2)
      ..[0] = unsigned & 0xFF
      ..[1] = (unsigned >> 8) & 0xFF;
  }

  /// Get complete transcript (all segments combined)
  /// Uses single newlines between segments for natural flow
  String getCompleteTranscript() {
    return _segments
        .where((s) => s.status.toString().contains('completed'))
        .map((s) => s.text)
        .join('\n');
  }

  /// Alias for V2 compatibility
  String getCombinedText() => getCompleteTranscript();

  /// Convert byte array to int16 samples
  List<int> _bytesToInt16(Uint8List bytes) {
    final samples = <int>[];
    for (var i = 0; i < bytes.length; i += 2) {
      if (i + 1 < bytes.length) {
        // Little-endian int16
        final sample = bytes[i] | (bytes[i + 1] << 8);
        // Convert to signed int16
        final signed = sample > 32767 ? sample - 65536 : sample;
        samples.add(signed);
      }
    }
    return samples;
  }

  /// Calculate RMS (Root Mean Square) energy for debugging
  double _calculateRMS(List<int> samples) {
    if (samples.isEmpty) return 0.0;
    double sumSquares = 0.0;
    for (final sample in samples) {
      sumSquares += sample * sample;
    }
    return sqrt(sumSquares / samples.length);
  }

  /// Get complete transcript from streaming (confirmed segments)
  /// Segments are joined with single newlines for natural paragraph flow
  String getStreamingTranscript() {
    return _confirmedSegments.join('\n');
  }

  /// Cleanup
  Future<void> dispose() async {
    debugPrint('[AutoPauseTranscription] 🧹 Disposing service...');

    // Stop all timers
    _stopStreamHealthCheck();
    _stopReTranscriptionLoop();
    _stopRecordingDurationTimer();

    // Cancel audio stream subscription first
    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;

    // Ensure recording is stopped before disposing (prevents CoreAudio leaks)
    if (_isRecording) {
      try {
        await _recorder.stop();
        _isRecording = false;
        _recordingStartTime = null;
        debugPrint(
          '[AutoPauseTranscription] Stopped active recording during dispose',
        );
      } catch (e) {
        debugPrint('[AutoPauseTranscription] Error stopping recorder: $e');
      }
    }

    // Dispose recorder
    await _recorder.dispose();

    // Close all streams
    await _segmentStreamController.close();
    await _processingStreamController.close();
    await _vadActivityController.close();
    await _debugMetricsController.close();
    await _streamHealthController.close();
    await _streamingStateController.close();
    await _interimTextController.close();

    // Clean up our temp files (but not the shared temp directory)
    if (_audioFilePath != null) {
      try {
        final file = File(_audioFilePath!);
        if (await file.exists()) {
          await file.delete();
          debugPrint('[AutoPauseTranscription] Deleted temp recording: $_audioFilePath');
        }
      } catch (e) {
        debugPrint('[AutoPauseTranscription] Failed to cleanup temp recording: $e');
      }
    }
    // Note: Segment temp files are cleaned up after transcription
    // Any remaining old files will be cleaned up by FileSystemService.cleanupTempAudioFiles()

    debugPrint('[AutoPauseTranscription] ✅ Service disposed');
  }
}

/// Internal: Queued segment for processing
class _QueuedSegment {
  final int index;
  final List<int> samples;

  _QueuedSegment({required this.index, required this.samples});
}
