import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'transcription_service.dart';
import 'vad/smart_chunker.dart';
import 'audio_processing/simple_noise_filter.dart';

/// Transcription model status
enum TranscriptionModelStatus {
  notInitialized, // Model not yet initialized
  initializing, // Model is loading
  ready, // Model ready for transcription
  error, // Initialization failed
}

/// Streaming transcription state for UI
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

/// Streaming voice input service for Chat
///
/// Provides real-time transcription feedback during recording:
/// 1. User starts recording → Continuous audio capture
/// 2. Audio → Noise filter → VAD → Rolling buffer (30s)
/// 3. Every 3s during speech → Re-transcribe last 15s → Stream interim text
/// 4. On 1s silence → Finalize chunk → Confirmed text
/// 5. On stop → Flush with 2s silence → Capture final words
class StreamingVoiceService {
  final TranscriptionService _transcriptionService;

  // Recording state
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  DateTime? _recordingStartTime;
  StreamSubscription<Uint8List>? _audioStreamSubscription;

  // Noise filtering & VAD
  SimpleNoiseFilter? _noiseFilter;
  SmartChunker? _chunker;

  // === STREAMING TRANSCRIPTION WITH LOCAL AGREEMENT ===
  //
  // Architecture based on whisper_streaming's LocalAgreement-2 algorithm:
  // 1. Maintain a rolling audio buffer (30 seconds max)
  // 2. Periodically transcribe the buffer (every 2 seconds)
  // 3. Compare consecutive transcriptions to find stable text
  // 4. Only "confirm" text that has been stable across 2 iterations
  // 5. Display: [confirmed stable text] + [tentative] + [interim]

  List<int> _rollingAudioBuffer = [];
  static const int _rollingBufferMaxSamples = 16000 * 30; // 30 seconds max
  static const Duration _reTranscriptionInterval = Duration(seconds: 2); // Faster updates

  Timer? _reTranscriptionTimer;
  Timer? _recordingDurationTimer;
  bool _isReTranscribing = false;

  // === LocalAgreement-2 State ===
  String? _previousTranscription; // Last transcription result
  String _confirmedText = '';      // Text stable across 2+ iterations (locked)
  String _tentativeText = '';      // Text stable for 1 iteration (likely stable)
  String _interimText = '';        // Current transcription suffix (may change)

  // Track when we last had a VAD pause to avoid re-transcribing stale audio
  DateTime? _lastVadPauseTime;

  // For final transcript assembly
  final List<String> _confirmedSegments = [];

  // Map from queued segment index to confirmed segment index
  final Map<int, int> _segmentToConfirmedIndex = {};

  // Segment processing
  int _nextSegmentIndex = 1;
  final List<_QueuedSegment> _processingQueue = [];
  bool _isProcessingQueue = false;

  // File management
  String? _audioFilePath;
  IOSink? _audioFileSink;
  int _totalSamplesWritten = 0;

  // Stream controllers
  final _streamingStateController =
      StreamController<StreamingTranscriptionState>.broadcast();
  final _interimTextController = StreamController<String>.broadcast();

  // Track transcription model status
  TranscriptionModelStatus _modelStatus = TranscriptionModelStatus.notInitialized;

  // Audio chunk tracking
  int _audioChunkCount = 0;

  Stream<StreamingTranscriptionState> get streamingStateStream =>
      _streamingStateController.stream;

  Stream<String> get interimTextStream => _interimTextController.stream;

  bool get isRecording => _isRecording;
  List<String> get confirmedSegments => List.unmodifiable(_confirmedSegments);
  String get interimText => _interimText;

  StreamingVoiceService(this._transcriptionService);

  /// Start streaming recording with real-time transcription
  Future<bool> startRecording({
    double vadEnergyThreshold = 200.0,
    Duration silenceThreshold = const Duration(seconds: 1),
    Duration minChunkDuration = const Duration(milliseconds: 500),
    Duration maxChunkDuration = const Duration(seconds: 30),
  }) async {
    if (_isRecording) {
      debugPrint('[StreamingVoice] Already recording');
      return false;
    }

    try {
      // Request permission
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          final status = await Permission.microphone.status;
          debugPrint('[StreamingVoice] Mic permission status: $status');
          if (!status.isGranted && !status.isLimited) {
            debugPrint('[StreamingVoice] Requesting microphone permission...');
            final requestResult = await Permission.microphone.request();
            debugPrint('[StreamingVoice] Permission request result: $requestResult');
          }
        } catch (e) {
          debugPrint('[StreamingVoice] Permission check failed: $e - proceeding anyway');
        }
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

      // Set up temp file path
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _audioFilePath = '${tempDir.path}/streaming_voice_$timestamp.wav';

      // Initialize streaming WAV file
      await _initializeStreamingWavFile(_audioFilePath!);

      // Enable wakelock
      try {
        await WakelockPlus.enable();
      } catch (e) {
        debugPrint('[StreamingVoice] Failed to enable wakelock: $e');
      }

      // Start recording with stream
      debugPrint('[StreamingVoice] Starting audio stream...');
      Stream<Uint8List> stream;
      try {
        stream = await _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
            echoCancel: false,
            autoGain: true,
            noiseSuppress: false,
          ),
        );
        debugPrint('[StreamingVoice] Audio stream started successfully');
      } catch (e) {
        debugPrint('[StreamingVoice] Failed to start audio stream: $e');
        return false;
      }

      _isRecording = true;
      _recordingStartTime = DateTime.now();
      _audioChunkCount = 0;

      // Reset streaming state
      _rollingAudioBuffer = [];
      _previousTranscription = null;
      _confirmedText = '';
      _tentativeText = '';
      _interimText = '';
      _confirmedSegments.clear();
      _segmentToConfirmedIndex.clear();
      _nextSegmentIndex = 1;
      _processingQueue.clear();
      _totalSamplesWritten = 0;
      _lastVadPauseTime = null;

      // Set initial model status
      final isModelReady = await _transcriptionService.isReady();
      _modelStatus = isModelReady
          ? TranscriptionModelStatus.ready
          : TranscriptionModelStatus.initializing;
      debugPrint('[StreamingVoice] Initial model status: $_modelStatus');

      // NOTE: Re-transcription loop disabled - using richardtate VAD-only approach
      // No interim text during speech, only final text after VAD pauses
      // _startReTranscriptionLoop();

      // Start recording duration timer
      _startRecordingDurationTimer();

      // Emit initial state
      _emitStreamingState();

      // Process audio stream
      _audioStreamSubscription = stream.listen(
        _processAudioChunk,
        onError: (error, stackTrace) {
          debugPrint('[StreamingVoice] STREAM ERROR: $error');
        },
        onDone: () {
          debugPrint('[StreamingVoice] Stream completed');
        },
        cancelOnError: false,
      );

      debugPrint('[StreamingVoice] Recording started with VAD');
      return true;
    } catch (e) {
      debugPrint('[StreamingVoice] Failed to start: $e');
      return false;
    }
  }

  /// Process incoming audio chunk from stream
  void _processAudioChunk(Uint8List audioBytes) {
    _audioChunkCount++;

    if (_audioChunkCount == 1) {
      debugPrint('[StreamingVoice] First audio chunk received! (${audioBytes.length} bytes)');
    }

    if (!_isRecording || _chunker == null || _noiseFilter == null) {
      return;
    }

    // Convert bytes to int16 samples
    final rawSamples = _bytesToInt16(audioBytes);
    if (rawSamples.isEmpty) return;

    // Apply noise filter
    final cleanSamples = _noiseFilter!.process(rawSamples);

    // Add to rolling buffer for streaming re-transcription
    _rollingAudioBuffer.addAll(cleanSamples);
    if (_rollingAudioBuffer.length > _rollingBufferMaxSamples) {
      _rollingAudioBuffer = _rollingAudioBuffer.sublist(
        _rollingAudioBuffer.length - _rollingBufferMaxSamples,
      );
    }

    // Stream audio to disk
    _streamAudioToDisk(cleanSamples);

    // Process through SmartChunker (VAD + auto-chunking)
    _chunker!.processSamples(cleanSamples);
  }

  /// Initialize WAV file for streaming audio data
  Future<void> _initializeStreamingWavFile(String path) async {
    final file = File(path);
    _audioFileSink = file.openWrite();

    // Write WAV header with placeholder size
    _audioFileSink!.add([0x52, 0x49, 0x46, 0x46]); // "RIFF"
    _audioFileSink!.add([0x00, 0x00, 0x00, 0x00]); // Placeholder file size
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
  }

  /// Stream audio samples to disk
  void _streamAudioToDisk(List<int> samples) {
    if (_audioFileSink == null) return;

    final bytes = Uint8List(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      final sample = samples[i];
      bytes[i * 2] = sample & 0xFF;
      bytes[i * 2 + 1] = (sample >> 8) & 0xFF;
    }
    _audioFileSink!.add(bytes);
    _totalSamplesWritten += samples.length;
  }

  /// Finalize WAV file by updating header
  Future<void> _finalizeStreamingWavFile() async {
    if (_audioFileSink == null || _audioFilePath == null) return;

    await _audioFileSink!.flush();
    await _audioFileSink!.close();
    _audioFileSink = null;

    final file = File(_audioFilePath!);
    final raf = await file.open(mode: FileMode.writeOnlyAppend);

    final dataSize = _totalSamplesWritten * 2;
    final fileSize = dataSize + 36;

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
    debugPrint('[StreamingVoice] Finalized WAV: ${dataSize ~/ 1024}KB');
  }

  /// Start the re-transcription loop for streaming feedback
  void _startReTranscriptionLoop() {
    _reTranscriptionTimer?.cancel();

    _reTranscriptionTimer = Timer.periodic(_reTranscriptionInterval, (_) async {
      if (!_isRecording) return;
      if (_chunker == null) return;

      // Check if model became ready
      if (_modelStatus == TranscriptionModelStatus.initializing) {
        final isReady = await _transcriptionService.isReady();
        if (isReady) {
          debugPrint('[StreamingVoice] Model became ready during recording!');
          _updateModelStatus(TranscriptionModelStatus.ready);
        }
      }

      final isSpeaking = _chunker!.stats.vadStats.isSpeaking;
      final hasSpeech = _chunker!.stats.vadStats.speechDuration > const Duration(milliseconds: 500);
      final bufferSeconds = _rollingAudioBuffer.length / 16000;

      if (isSpeaking || hasSpeech || bufferSeconds >= 3.0) {
        _transcribeRollingBuffer();
      }
    });
  }

  /// Stop re-transcription loop
  void _stopReTranscriptionLoop() {
    _reTranscriptionTimer?.cancel();
    _reTranscriptionTimer = null;
  }

  /// Start recording duration timer
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
  Future<void> _transcribeRollingBuffer() async {
    if (_isReTranscribing) return;
    if (_rollingAudioBuffer.isEmpty || _rollingAudioBuffer.length < 16000) return;

    _isReTranscribing = true;

    try {
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

      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/interim_${DateTime.now().millisecondsSinceEpoch}.wav';
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
      }
    } catch (e) {
      debugPrint('[LocalAgreement] Transcription failed: $e');
    } finally {
      _isReTranscribing = false;
    }
  }

  /// Apply LocalAgreement-2 algorithm to update confirmed/tentative/interim text
  ///
  /// SIMPLIFIED: The rolling buffer produces the FULL transcription of current audio.
  /// We just display that directly, using LocalAgreement only for visual styling.
  void _applyLocalAgreement(String currentTranscription) {
    if (_previousTranscription == null) {
      _confirmedText = '';
      _tentativeText = '';
      _interimText = currentTranscription;
      _previousTranscription = currentTranscription;
      return;
    }

    final commonPrefix = _longestCommonWordPrefix(_previousTranscription!, currentTranscription);

    // Common prefix is stable, rest is still changing
    _confirmedText = '';  // Don't accumulate - buffer has full audio
    _tentativeText = commonPrefix;

    if (commonPrefix.length < currentTranscription.length) {
      _interimText = currentTranscription.substring(commonPrefix.length).trim();
    } else {
      _interimText = '';
    }

    _previousTranscription = currentTranscription;
  }

  /// Find the longest common prefix between two strings, word-by-word
  String _longestCommonWordPrefix(String a, String b) {
    final wordsA = a.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final wordsB = b.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

    int matchLen = 0;
    for (int i = 0; i < min(wordsA.length, wordsB.length); i++) {
      if (_wordMatchesFuzzy(wordsA[i], wordsB[i])) {
        matchLen = i + 1;
      } else {
        break;
      }
    }
    return wordsA.take(matchLen).join(' ');
  }

  /// Check if two words match (case-insensitive, ignoring punctuation)
  bool _wordMatchesFuzzy(String a, String b) {
    String normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
    final normA = normalize(a);
    final normB = normalize(b);
    if (normA == normB) return true;
    if (normA.length > 2 && normB.length > 2) {
      return _levenshteinDistance(normA, normB) <= 1;
    }
    return false;
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
      if (_wordsMatchFuzzy(confirmedSuffix, interimPrefix)) {
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
  bool _wordsMatchFuzzy(List<String> a, List<String> b) {
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

  /// Final transcription for any remaining audio in rolling buffer
  /// Simple: just transcribe what's there and add to confirmedSegments
  Future<void> _doFinalTranscription() async {
    if (_rollingAudioBuffer.isEmpty) return;

    try {
      debugPrint('[StreamingVoice] Final transcription: ${_rollingAudioBuffer.length} samples');

      final samplesToTranscribe = List<int>.from(_rollingAudioBuffer);

      // Save to temp file
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/final_${DateTime.now().millisecondsSinceEpoch}.wav';

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
        debugPrint('[StreamingVoice] Final segment: "$transcribedText"');
      }

      _emitStreamingState();
    } catch (e) {
      debugPrint('[StreamingVoice] Final transcription failed: $e');
    }
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

  /// Normalize text for duplicate comparison
  String _normalizeForComparison(String text) {
    return text.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Handle chunk ready from SmartChunker (VAD detected pause)
  ///
  /// Richardtate approach: On VAD pause, transcribe ONLY the chunk audio,
  /// add result to confirmedSegments, then clear the rolling buffer.
  /// This avoids duplicates by never re-transcribing overlapping audio.
  void _handleChunk(List<int> samples) {
    debugPrint('[StreamingVoice] VAD pause detected! (${samples.length} samples)');

    // Queue chunk for transcription - this will add to confirmedSegments
    final segmentIndex = _nextSegmentIndex++;
    _queueSegmentForProcessing(samples, segmentIndex);

    // Clear rolling buffer state - we're done with this audio
    _rollingAudioBuffer.clear();
    _previousTranscription = null;
    _confirmedText = '';
    _tentativeText = '';
    _interimText = '';
  }

  /// Queue a segment for transcription
  void _queueSegmentForProcessing(List<int> samples, int segmentIndex) {
    _processingQueue.add(_QueuedSegment(
      index: segmentIndex,
      samples: samples,
    ));

    if (!_isProcessingQueue) {
      _processQueue();
    }
  }

  /// Process queued segments
  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    while (_processingQueue.isNotEmpty) {
      final segment = _processingQueue.removeAt(0);
      await _transcribeSegment(segment);
    }

    _isProcessingQueue = false;
  }

  /// Transcribe a single segment
  Future<void> _transcribeSegment(_QueuedSegment segment) async {
    try {
      // Save segment to temp file
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/segment_${segment.index}.wav';

      await _saveSamplesToWav(segment.samples, tempPath);

      // Transcribe
      final result = await _transcriptionService.transcribeAudio(tempPath);

      // Clean up
      try {
        await File(tempPath).delete();
      } catch (_) {}

      final transcribedText = result.text.trim();
      if (transcribedText.isEmpty) return;

      // Simply add to confirmed segments - no overlap since each chunk is unique audio
      _confirmedSegments.add(transcribedText);
      _emitStreamingState();
      debugPrint('[StreamingVoice] Segment ${segment.index}: "$transcribedText"');
    } catch (e) {
      debugPrint('[StreamingVoice] Failed to transcribe segment: $e');
    }
  }

  /// Save samples to WAV file
  Future<void> _saveSamplesToWav(List<int> samples, String filePath) async {
    const sampleRate = 16000;
    const numChannels = 1;
    const bitsPerSample = 16;

    final dataSize = samples.length * 2;
    final fileSize = 36 + dataSize;

    final bytes = BytesBuilder();

    // RIFF header
    bytes.add('RIFF'.codeUnits);
    bytes.add(_int32ToBytes(fileSize));
    bytes.add('WAVE'.codeUnits);

    // fmt chunk
    bytes.add('fmt '.codeUnits);
    bytes.add(_int32ToBytes(16));
    bytes.add(_int16ToBytes(1));
    bytes.add(_int16ToBytes(numChannels));
    bytes.add(_int32ToBytes(sampleRate));
    bytes.add(_int32ToBytes(sampleRate * numChannels * bitsPerSample ~/ 8));
    bytes.add(_int16ToBytes(numChannels * bitsPerSample ~/ 8));
    bytes.add(_int16ToBytes(bitsPerSample));

    // data chunk
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

  /// Stop recording and return audio file path
  Future<String?> stopRecording() async {
    if (!_isRecording) return null;

    try {
      debugPrint('[StreamingVoice] Stopping recording...');

      _stopReTranscriptionLoop();
      _stopRecordingDurationTimer();

      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      await _recorder.stop();
      _isRecording = false;

      // Wait for stream to settle
      await Future.delayed(const Duration(milliseconds: 300));

      // Flush chunker FIRST - this triggers _handleChunk for any remaining audio
      // The chunker holds audio that hasn't hit a VAD pause yet
      if (_chunker != null) {
        debugPrint('[StreamingVoice] Flushing chunker for final audio...');
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
        debugPrint('[StreamingVoice] Transcribing remaining buffer: ${_rollingAudioBuffer.length} samples');
        await _doFinalTranscription();
      }

      if (_noiseFilter != null) {
        _noiseFilter!.reset();
        _noiseFilter = null;
      }

      _emitStreamingState();
      _recordingStartTime = null;

      // Finalize WAV file
      await _finalizeStreamingWavFile();

      // Disable wakelock
      try {
        await WakelockPlus.disable();
      } catch (_) {}

      // Clear buffers
      _rollingAudioBuffer.clear();

      debugPrint('[StreamingVoice] Recording stopped: $_audioFilePath');
      return _audioFilePath;
    } catch (e) {
      debugPrint('[StreamingVoice] Failed to stop: $e');
      return null;
    }
  }

  /// Cancel recording without saving
  Future<void> cancelRecording() async {
    if (!_isRecording) return;

    try {
      _stopReTranscriptionLoop();
      _stopRecordingDurationTimer();

      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      await _recorder.stop();
      _isRecording = false;
      _recordingStartTime = null;

      _chunker = null;

      // Close and delete file
      if (_audioFileSink != null) {
        await _audioFileSink!.close();
        _audioFileSink = null;
      }
      if (_audioFilePath != null) {
        final file = File(_audioFilePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }

      // Clear state
      _rollingAudioBuffer.clear();
      _previousTranscription = null;
      _confirmedText = '';
      _tentativeText = '';
      _interimText = '';
      _confirmedSegments.clear();
      _processingQueue.clear();

      _emitStreamingState();

      try {
        await WakelockPlus.disable();
      } catch (_) {}

      debugPrint('[StreamingVoice] Recording cancelled');
    } catch (e) {
      debugPrint('[StreamingVoice] Failed to cancel: $e');
    }
  }

  /// Get complete transcript from streaming (confirmed segments)
  String getStreamingTranscript() {
    if (_confirmedSegments.isEmpty) return '';

    // Join segments with spaces and deduplicate any repeated phrases
    final result = StringBuffer();

    for (int i = 0; i < _confirmedSegments.length; i++) {
      final segment = _confirmedSegments[i].trim();
      if (segment.isEmpty) continue;

      if (result.isEmpty) {
        result.write(segment);
      } else {
        // Use fuzzy overlap removal
        final currentText = result.toString();
        final deduped = _removeOverlapFuzzy(currentText, segment);

        if (deduped.isNotEmpty) {
          result.write(' ');
          result.write(deduped);
        }
      }
    }

    return result.toString().trim();
  }

  /// Dispose
  void dispose() {
    _stopReTranscriptionLoop();
    _stopRecordingDurationTimer();
    _audioStreamSubscription?.cancel();
    _recorder.dispose();
    _streamingStateController.close();
    _interimTextController.close();
  }
}

/// Internal: Queued segment for processing
class _QueuedSegment {
  final int index;
  final List<int> samples;

  _QueuedSegment({required this.index, required this.samples});
}
