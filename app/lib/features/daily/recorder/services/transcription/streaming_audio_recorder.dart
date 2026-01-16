import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'package:parachute/core/services/file_system_service.dart';

/// Callback for audio chunks
typedef AudioChunkCallback = void Function(Uint8List audioBytes);

/// Manages audio recording and streaming to disk
///
/// Features:
/// - Streaming WAV file output (writes incrementally to avoid memory buildup)
/// - Stream health monitoring (detects broken audio streams)
/// - Platform-specific permission handling
class StreamingAudioRecorder {
  final AudioRecorder _recorder = AudioRecorder();

  // Recording state
  bool _isRecording = false;
  DateTime? _recordingStartTime;
  StreamSubscription<Uint8List>? _audioStreamSubscription;

  // Stream health monitoring
  DateTime? _lastAudioChunkTime;
  int _audioChunkCount = 0;
  Timer? _streamHealthCheckTimer;

  // Streaming to disk
  IOSink? _audioFileSink;
  int _totalSamplesWritten = 0;
  String? _audioFilePath;
  static const int _flushThreshold = 16000 * 10; // Flush every ~10 seconds

  // Stream controllers
  final _streamHealthController = StreamController<bool>.broadcast();

  Stream<bool> get streamHealthStream => _streamHealthController.stream;
  bool get isRecording => _isRecording;
  DateTime? get recordingStartTime => _recordingStartTime;
  String? get audioFilePath => _audioFilePath;
  int get totalSamplesWritten => _totalSamplesWritten;

  /// Start recording with streaming output
  ///
  /// Returns true if recording started successfully.
  /// [onAudioChunk] is called for each chunk of audio data received.
  Future<bool> startRecording({
    required AudioChunkCallback onAudioChunk,
  }) async {
    if (_isRecording) {
      debugPrint('[StreamingAudioRecorder] Already recording');
      return false;
    }

    try {
      // Request permission on mobile platforms
      if (Platform.isAndroid || Platform.isIOS) {
        try {
          final status = await Permission.microphone.status;
          debugPrint('[StreamingAudioRecorder] Mic permission status: $status');
          if (!status.isGranted && !status.isLimited) {
            debugPrint('[StreamingAudioRecorder] Requesting microphone permission...');
            final requestResult = await Permission.microphone.request();
            debugPrint('[StreamingAudioRecorder] Permission request result: $requestResult');
          }
        } catch (e) {
          debugPrint('[StreamingAudioRecorder] Permission check failed: $e - proceeding anyway');
        }
      }

      // Get recording path
      final fileSystem = FileSystemService.daily();
      _audioFilePath = await fileSystem.getRecordingTempPath();

      // Initialize streaming WAV file
      await _initializeStreamingWavFile(_audioFilePath!);

      // Start recording stream
      debugPrint('[StreamingAudioRecorder] 🎙️ Starting audio stream...');
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
        debugPrint('[StreamingAudioRecorder] ✅ Audio stream started successfully');
      } catch (e) {
        debugPrint('[StreamingAudioRecorder] ❌ Failed to start audio stream: $e');
        return false;
      }

      _isRecording = true;
      _recordingStartTime = DateTime.now();
      _totalSamplesWritten = 0;

      // Reset health monitoring
      _lastAudioChunkTime = DateTime.now();
      _audioChunkCount = 0;

      // Process audio stream
      debugPrint('[StreamingAudioRecorder] 🎧 Setting up stream listener...');
      _audioStreamSubscription = stream.listen(
        (audioBytes) {
          _lastAudioChunkTime = DateTime.now();
          _audioChunkCount++;

          if (_audioChunkCount == 1) {
            debugPrint('[StreamingAudioRecorder] ✅ First audio chunk received! (${audioBytes.length} bytes)');
          }

          onAudioChunk(audioBytes);
        },
        onError: (error, stackTrace) {
          debugPrint('[StreamingAudioRecorder] ❌ STREAM ERROR: $error');
          debugPrint('[StreamingAudioRecorder] Chunks received before error: $_audioChunkCount');
        },
        onDone: () {
          debugPrint('[StreamingAudioRecorder] ⚠️ STREAM COMPLETED/CLOSED');
          debugPrint('[StreamingAudioRecorder] Total chunks received: $_audioChunkCount');
        },
        cancelOnError: false,
      );

      // Start health check timer
      _startStreamHealthCheck();

      debugPrint('[StreamingAudioRecorder] ✅ Recording started');
      return true;
    } catch (e) {
      debugPrint('[StreamingAudioRecorder] Failed to start: $e');
      return false;
    }
  }

  /// Write audio samples to the streaming WAV file
  void writeSamples(List<int> samples) {
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
      debugPrint('[StreamingAudioRecorder] Flushed ${_totalSamplesWritten ~/ 16000}s of audio to disk');
    }
  }

  /// Stop recording and finalize WAV file
  ///
  /// Returns the path to the recorded WAV file.
  Future<String?> stopRecording() async {
    if (!_isRecording) return null;

    try {
      debugPrint('[StreamingAudioRecorder] 🛑 Stopping recording...');
      debugPrint('[StreamingAudioRecorder] Total audio chunks received: $_audioChunkCount');

      // Stop health check
      _stopStreamHealthCheck();

      // Cancel stream subscription
      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      // Stop recorder
      await _recorder.stop();
      _isRecording = false;

      // Wait for stream to settle
      await Future.delayed(const Duration(milliseconds: 300));

      // Finalize WAV file
      await _finalizeStreamingWavFile();

      _recordingStartTime = null;

      debugPrint('[StreamingAudioRecorder] Recording stopped: $_audioFilePath');
      return _audioFilePath;
    } catch (e) {
      debugPrint('[StreamingAudioRecorder] Failed to stop: $e');
      return null;
    }
  }

  /// Cancel recording without saving
  Future<void> cancelRecording() async {
    if (!_isRecording) return;

    try {
      debugPrint('[StreamingAudioRecorder] ❌ Cancelling recording...');

      _stopStreamHealthCheck();

      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;

      await _recorder.stop();
      _isRecording = false;
      _recordingStartTime = null;

      // Close and delete the streaming WAV file
      if (_audioFileSink != null) {
        await _audioFileSink!.close();
        _audioFileSink = null;
      }
      if (_audioFilePath != null) {
        final file = File(_audioFilePath!);
        if (await file.exists()) {
          await file.delete();
          debugPrint('[StreamingAudioRecorder] Deleted incomplete recording');
        }
      }

      debugPrint('[StreamingAudioRecorder] Recording cancelled');
    } catch (e) {
      debugPrint('[StreamingAudioRecorder] Failed to cancel: $e');
    }
  }

  /// Pause recording
  Future<void> pauseRecording() async {
    if (!_isRecording) return;
    try {
      await _recorder.pause();
      debugPrint('[StreamingAudioRecorder] Recording paused');
    } catch (e) {
      debugPrint('[StreamingAudioRecorder] Failed to pause: $e');
    }
  }

  /// Resume recording
  Future<void> resumeRecording() async {
    if (!_isRecording) return;
    try {
      await _recorder.resume();
      debugPrint('[StreamingAudioRecorder] Recording resumed');
    } catch (e) {
      debugPrint('[StreamingAudioRecorder] Failed to resume: $e');
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

    debugPrint('[StreamingAudioRecorder] Initialized streaming WAV: $path');
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

    debugPrint('[StreamingAudioRecorder] Finalized WAV: ${dataSize ~/ 1024}KB, ${_totalSamplesWritten ~/ 16000}s');
  }

  /// Start periodic health check for audio stream
  void _startStreamHealthCheck() {
    _streamHealthCheckTimer?.cancel();

    // Initially healthy
    if (!_streamHealthController.isClosed) {
      _streamHealthController.add(true);
    }

    _streamHealthCheckTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!_isRecording) {
        timer.cancel();
        return;
      }

      final now = DateTime.now();
      final timeSinceLastChunk = _lastAudioChunkTime != null
          ? now.difference(_lastAudioChunkTime!)
          : null;

      if (timeSinceLastChunk != null && timeSinceLastChunk > const Duration(seconds: 5)) {
        // Stream is broken
        if (!_streamHealthController.isClosed) {
          _streamHealthController.add(false);
        }
        debugPrint('[StreamingAudioRecorder] ⚠️ Audio stream broken (${timeSinceLastChunk.inSeconds}s since last chunk)');

        if (timeSinceLastChunk.inSeconds == 5 || timeSinceLastChunk.inSeconds == 6) {
          debugPrint('[StreamingAudioRecorder] Possible causes:');
          debugPrint('[StreamingAudioRecorder]   - System audio service issue');
          debugPrint('[StreamingAudioRecorder]   - Microphone permission revoked');
          debugPrint('[StreamingAudioRecorder]   - Another app captured audio input');
        }
      } else {
        // Stream is healthy
        if (!_streamHealthController.isClosed) {
          _streamHealthController.add(true);
        }
      }
    });
  }

  void _stopStreamHealthCheck() {
    _streamHealthCheckTimer?.cancel();
    _streamHealthCheckTimer = null;
    debugPrint('[StreamingAudioRecorder] 🔍 Stream health monitoring stopped');
  }

  /// Dispose resources
  Future<void> dispose() async {
    _stopStreamHealthCheck();

    await _audioStreamSubscription?.cancel();
    _audioStreamSubscription = null;

    if (_isRecording) {
      try {
        await _recorder.stop();
        _isRecording = false;
        _recordingStartTime = null;
        debugPrint('[StreamingAudioRecorder] Stopped active recording during dispose');
      } catch (e) {
        debugPrint('[StreamingAudioRecorder] Error stopping recorder: $e');
      }
    }

    await _recorder.dispose();
    await _streamHealthController.close();

    debugPrint('[StreamingAudioRecorder] ✅ Disposed');
  }
}
