import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:parachute/core/services/file_system_service.dart';

enum RecordingState { stopped, recording, paused }

class AudioService {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  AudioService();

  RecordingState _recordingState = RecordingState.stopped;
  String? _currentRecordingPath;
  DateTime? _recordingStartTime;
  Duration _recordingDuration = Duration.zero;
  Duration _pausedDuration = Duration.zero;
  DateTime? _pauseStartTime;
  Timer? _durationTimer;
  bool _isInitialized = false;
  Completer<void>? _initCompleter;

  RecordingState get recordingState => _recordingState;
  Duration get recordingDuration => _recordingDuration;
  bool get isPlaying => _player.playing;
  bool get isInitialized => _isInitialized;

  /// Access the recorder for amplitude monitoring
  AudioRecorder get recorder => _recorder;

  /// Wait for initialization to complete.
  /// Safe to call multiple times - will return immediately if already initialized.
  Future<void> ensureInitialized() async {
    if (_isInitialized) return;
    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }
    await initialize();
  }

  Future<void> initialize() async {
    if (_isInitialized) {
      debugPrint('AudioService already initialized');
      return;
    }

    // If already initializing, wait for that to complete
    if (_initCompleter != null) {
      debugPrint('AudioService already initializing, waiting...');
      await _initCompleter!.future;
      return;
    }

    _initCompleter = Completer<void>();

    try {
      debugPrint('Initializing AudioService...');

      // Check if recording is supported
      if (await _recorder.hasPermission()) {
        debugPrint('Recording permissions granted');
      } else {
        debugPrint('Recording permissions not granted');
      }

      _isInitialized = true;
      _initCompleter!.complete();
      debugPrint('AudioService initialized successfully');
    } catch (e, stackTrace) {
      debugPrint('Error initializing AudioService: $e');
      debugPrint('Stack trace: $stackTrace');
      _isInitialized = false;
      _initCompleter!.completeError(e);
      _initCompleter = null; // Allow retry on failure
      rethrow;
    }
  }

  Future<void> dispose() async {
    _durationTimer?.cancel();

    // Ensure wakelock is disabled on disposal
    try {
      if (await WakelockPlus.enabled) {
        await WakelockPlus.disable();
        debugPrint('Wakelock disabled on dispose');
      }
    } catch (e) {
      debugPrint('Error checking/disabling wakelock on dispose: $e');
    }

    await _recorder.dispose();
    await _player.dispose();
    _isInitialized = false;
    debugPrint('AudioService disposed');
  }

  Future<bool> requestPermissions() async {
    try {
      // Use the record package's built-in permission handling
      // which works across all platforms including macOS
      final hasPermission = await _recorder.hasPermission();
      debugPrint('Recording permission check: $hasPermission');

      if (!hasPermission) {
        debugPrint('Microphone permission denied');

        // On Android, try to open settings if permission is denied
        if (Platform.isAndroid) {
          try {
            final micPermission = await Permission.microphone.status;
            if (micPermission.isPermanentlyDenied) {
              debugPrint('Opening app settings for permission...');
              await openAppSettings();
            }
          } catch (e) {
            debugPrint('Could not open settings: $e');
          }
        }

        return false;
      }

      // For Android 13+, also check notification permission for background recording
      if (Platform.isAndroid) {
        try {
          if (await Permission.notification.isDenied) {
            final notificationPermission = await Permission.notification
                .request();
            debugPrint(
              'Android Notification permission: $notificationPermission',
            );
          }
        } catch (e) {
          debugPrint('Could not request notification permission: $e');
          // Not critical, continue anyway
        }
      }

      return true;
    } catch (e) {
      debugPrint('Error requesting permissions: $e');
      // If there's an error but the recorder says it has permission, trust it
      try {
        return await _recorder.hasPermission();
      } catch (e2) {
        debugPrint('Fallback permission check failed: $e2');
        return false;
      }
    }
  }

  Future<String> _getRecordingPath(String recordingId) async {
    try {
      // Use temp folder for recording-in-progress WAV files
      // The final Opus file will be saved to captures folder by StorageService
      final fileSystem = FileSystemService.daily();
      final path = await fileSystem.getRecordingTempPath();
      debugPrint('Generated temp recording path: $path');
      return path;
    } catch (e) {
      debugPrint('Error getting recording path: $e');
      rethrow;
    }
  }

  void _startDurationTimer() {
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_recordingState == RecordingState.recording &&
          _recordingStartTime != null) {
        _recordingDuration =
            DateTime.now().difference(_recordingStartTime!) - _pausedDuration;
      }
    });
  }

  Future<bool> startRecording() async {
    debugPrint('startRecording called, current state: $_recordingState');
    if (_recordingState != RecordingState.stopped) {
      debugPrint('Cannot start recording: state is $_recordingState');
      return false;
    }

    // Check and request permissions
    final hasPermission = await requestPermissions();
    debugPrint('Permission check result: $hasPermission');
    if (!hasPermission) {
      debugPrint('Permission denied, cannot start recording');
      return false;
    }

    try {
      // Ensure recorder is properly initialized
      if (!_isInitialized) {
        debugPrint('Recorder not initialized, initializing now...');
        await initialize();
      }

      // Check if already recording
      if (await _recorder.isRecording()) {
        debugPrint('Recorder is already recording');
        return false;
      }

      // Generate recording ID and path
      debugPrint('Generating recording ID...');
      final recordingId = DateTime.now().millisecondsSinceEpoch.toString();
      debugPrint('Recording ID: $recordingId');

      debugPrint('Getting recording path...');
      _currentRecordingPath = await _getRecordingPath(recordingId);
      debugPrint('Will record to: $_currentRecordingPath');

      // Enable wakelock to prevent device sleep during recording
      debugPrint('Enabling wakelock...');
      await WakelockPlus.enable();
      debugPrint('Wakelock enabled');

      // Start recording with WAV format (compatible with Parakeet)
      debugPrint('Starting recorder...');
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000, // 16kHz for Parakeet/Whisper
          numChannels: 1, // Mono
        ),
        path: _currentRecordingPath!,
      );
      debugPrint('Recorder.start() completed');

      _recordingStartTime = DateTime.now();
      _recordingState = RecordingState.recording;
      _recordingDuration = Duration.zero;
      _pausedDuration = Duration.zero;
      _startDurationTimer();

      debugPrint('Recording started successfully');
      return true;
    } catch (e, stackTrace) {
      debugPrint('Error starting recording: $e');
      debugPrint('Stack trace: $stackTrace');
      _recordingState = RecordingState.stopped;
      _currentRecordingPath = null;
      return false;
    }
  }

  Future<bool> pauseRecording() async {
    if (_recordingState != RecordingState.recording) return false;

    try {
      await _recorder.pause();
      _recordingState = RecordingState.paused;
      _pauseStartTime = DateTime.now();
      _durationTimer?.cancel();
      debugPrint('Recording paused');
      return true;
    } catch (e) {
      debugPrint('Error pausing recording: $e');
      return false;
    }
  }

  Future<bool> resumeRecording() async {
    if (_recordingState != RecordingState.paused) return false;

    try {
      await _recorder.resume();
      _recordingState = RecordingState.recording;

      // Add the paused duration to total paused time
      if (_pauseStartTime != null) {
        _pausedDuration += DateTime.now().difference(_pauseStartTime!);
        _pauseStartTime = null;
      }

      _startDurationTimer();
      debugPrint('Recording resumed');
      return true;
    } catch (e) {
      debugPrint('Error resuming recording: $e');
      return false;
    }
  }

  Future<String?> stopRecording() async {
    if (_recordingState == RecordingState.stopped) return null;

    try {
      _durationTimer?.cancel();

      // Disable wakelock when recording stops
      debugPrint('Disabling wakelock...');
      await WakelockPlus.disable();
      debugPrint('Wakelock disabled');

      final path = await _recorder.stop();
      _recordingState = RecordingState.stopped;
      _currentRecordingPath = null;
      _recordingStartTime = null;
      _pauseStartTime = null;
      _pausedDuration = Duration.zero;

      // Verify file exists
      if (path != null) {
        final file = File(path);
        if (await file.exists()) {
          final size = await file.length();
          debugPrint(
            'Recording stopped and saved: $path (size: ${size / 1024}KB)',
          );
          return path;
        } else {
          debugPrint('Recording file not found at: $path');
        }
      }

      debugPrint('Recording stopped but file not found');
      return null;
    } catch (e) {
      debugPrint('Error stopping recording: $e');
      _recordingState = RecordingState.stopped;
      _durationTimer?.cancel();
      // Ensure wakelock is disabled even on error
      try {
        await WakelockPlus.disable();
      } catch (wakelockError) {
        debugPrint('Error disabling wakelock: $wakelockError');
      }
      return null;
    }
  }

  Future<bool> playRecording(String filePath) async {
    try {
      if (filePath.isEmpty) {
        debugPrint('Cannot play: empty file path');
        return false;
      }

      // Opus files are no longer supported for playback
      if (filePath.endsWith('.opus')) {
        debugPrint('Cannot play opus file: $filePath (opus support removed)');
        return false;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        debugPrint('File not found: $filePath');
        return false;
      }

      await _player.setFilePath(filePath);
      await _player.play();

      debugPrint('Playing recording: $filePath');
      return true;
    } catch (e, stackTrace) {
      debugPrint('Error playing recording: $e');
      debugPrint('Stack trace: $stackTrace');
      return false;
    }
  }

  Future<bool> stopPlayback() async {
    try {
      await _player.stop();
      debugPrint('Playback stopped');
      return true;
    } catch (e) {
      debugPrint('Error stopping playback: $e');
      return false;
    }
  }

  Future<bool> pausePlayback() async {
    try {
      await _player.pause();
      return true;
    } catch (e) {
      debugPrint('Error pausing playback: $e');
      return false;
    }
  }

  Future<bool> resumePlayback() async {
    try {
      await _player.play();
      return true;
    } catch (e) {
      debugPrint('Error resuming playback: $e');
      return false;
    }
  }

  Future<bool> seekTo(Duration position) async {
    try {
      await _player.seek(position);
      return true;
    } catch (e) {
      debugPrint('Error seeking playback: $e');
      return false;
    }
  }

  Stream<Duration> get positionStream => _player.positionStream;

  Stream<Duration?> get durationStream => _player.durationStream;

  Stream<bool> get playingStream => _player.playingStream;

  Future<Duration?> getRecordingDuration(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) {
        return null;
      }

      await _player.setFilePath(filePath);
      return _player.duration;
    } catch (e) {
      debugPrint('Error getting recording duration: $e');
      return null;
    }
  }

  Future<double> getFileSizeKB(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        final size = await file.length();
        return size / 1024;
      }
      return 0;
    } catch (e) {
      debugPrint('Error getting file size: $e');
      return 0;
    }
  }

  Future<bool> deleteRecordingFile(String filePath) async {
    try {
      if (filePath.isEmpty) {
        debugPrint('Cannot delete: empty file path');
        return false;
      }

      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        debugPrint('Deleted recording file: $filePath');
        return true;
      }

      debugPrint('File not found for deletion: $filePath');
      return false;
    } catch (e) {
      debugPrint('Error deleting recording file: $e');
      return false;
    }
  }

  /// Appends audio from sourceWavPath to targetWavPath.
  /// Both files must be WAV format with matching sample rate and channels.
  /// Returns the duration of the appended segment in seconds.
  Future<double> appendWavFile(String targetWavPath, String sourceWavPath) async {
    try {
      final targetFile = File(targetWavPath);
      final sourceFile = File(sourceWavPath);

      if (!await targetFile.exists()) {
        throw Exception('Target WAV file not found: $targetWavPath');
      }
      if (!await sourceFile.exists()) {
        throw Exception('Source WAV file not found: $sourceWavPath');
      }

      // Read both files
      final targetBytes = await targetFile.readAsBytes();
      final sourceBytes = await sourceFile.readAsBytes();

      // Validate WAV headers (RIFF....WAVE)
      if (targetBytes.length < 44 || sourceBytes.length < 44) {
        throw Exception('Invalid WAV file: too small');
      }

      final targetRiff = String.fromCharCodes(targetBytes.sublist(0, 4));
      final sourceRiff = String.fromCharCodes(sourceBytes.sublist(0, 4));
      if (targetRiff != 'RIFF' || sourceRiff != 'RIFF') {
        throw Exception('Invalid WAV file: missing RIFF header');
      }

      // Extract audio parameters from target to validate compatibility
      // Find the 'fmt ' chunk to get audio parameters
      final targetFmtOffset = _findChunkOffset(targetBytes, 'fmt ');
      final sourceFmtOffset = _findChunkOffset(sourceBytes, 'fmt ');

      if (targetFmtOffset == -1 || sourceFmtOffset == -1) {
        throw Exception('Could not find fmt chunk in WAV file');
      }

      // fmt chunk layout after 'fmt ' and size (8 bytes):
      // +0: audio format (2 bytes)
      // +2: num channels (2 bytes)
      // +4: sample rate (4 bytes)
      // +8: byte rate (4 bytes)
      // +12: block align (2 bytes)
      // +14: bits per sample (2 bytes)
      final targetNumChannels = _readUint16LE(targetBytes, targetFmtOffset + 10);
      final targetSampleRate = _readUint32LE(targetBytes, targetFmtOffset + 12);
      final targetBitsPerSample = _readUint16LE(targetBytes, targetFmtOffset + 22);

      final sourceNumChannels = _readUint16LE(sourceBytes, sourceFmtOffset + 10);
      final sourceSampleRate = _readUint32LE(sourceBytes, sourceFmtOffset + 12);
      final sourceBitsPerSample = _readUint16LE(sourceBytes, sourceFmtOffset + 22);

      debugPrint(
        'WAV params - target: $targetSampleRate Hz, $targetNumChannels ch, $targetBitsPerSample bit; '
        'source: $sourceSampleRate Hz, $sourceNumChannels ch, $sourceBitsPerSample bit',
      );

      if (targetSampleRate != sourceSampleRate ||
          targetNumChannels != sourceNumChannels ||
          targetBitsPerSample != sourceBitsPerSample) {
        throw Exception(
          'WAV format mismatch: target($targetSampleRate Hz, $targetNumChannels ch, $targetBitsPerSample bit) '
          'vs source($sourceSampleRate Hz, $sourceNumChannels ch, $sourceBitsPerSample bit)',
        );
      }

      // Find the data chunk in both files
      final targetDataOffset = _findDataChunkOffset(targetBytes);
      final sourceDataOffset = _findDataChunkOffset(sourceBytes);

      if (targetDataOffset == -1 || sourceDataOffset == -1) {
        throw Exception('Could not find data chunk in WAV file');
      }

      // Read existing data sizes
      final targetDataSize = _readUint32LE(targetBytes, targetDataOffset + 4);
      final sourceDataSize = _readUint32LE(sourceBytes, sourceDataOffset + 4);

      // Extract source PCM data (after 'data' + size)
      final sourcePcmData = sourceBytes.sublist(sourceDataOffset + 8);

      // Use actual PCM data length (more reliable than header value)
      final actualSourceDataSize = sourcePcmData.length;

      debugPrint(
        'Data sizes - target: $targetDataSize bytes, source header: $sourceDataSize bytes, '
        'source actual: $actualSourceDataSize bytes',
      );

      // Calculate new total size using actual data length
      final newDataSize = targetDataSize + actualSourceDataSize;
      final newFileSize = targetBytes.length + actualSourceDataSize;

      // Create new file with updated header
      final newBytes = ByteData(newFileSize);

      // Copy original target file
      for (int i = 0; i < targetBytes.length; i++) {
        newBytes.setUint8(i, targetBytes[i]);
      }

      // Update RIFF chunk size (file size - 8)
      _writeInt32LE(newBytes, 4, newFileSize - 8);

      // Update data chunk size
      _writeInt32LE(newBytes, targetDataOffset + 4, newDataSize);

      // Append source PCM data
      for (int i = 0; i < sourcePcmData.length; i++) {
        newBytes.setUint8(targetBytes.length + i, sourcePcmData[i]);
      }

      // Write the combined file
      await targetFile.writeAsBytes(newBytes.buffer.asUint8List());

      // Calculate segment duration
      final bytesPerSample = targetBitsPerSample ~/ 8;
      final bytesPerSecond = targetSampleRate * targetNumChannels * bytesPerSample;

      // Guard against division by zero
      double segmentDuration = 0.0;
      if (bytesPerSecond > 0) {
        segmentDuration = actualSourceDataSize / bytesPerSecond;
      }

      debugPrint(
        'Appended ${actualSourceDataSize / 1024}KB of audio to $targetWavPath '
        '(${segmentDuration.toStringAsFixed(2)}s, bytesPerSecond: $bytesPerSecond)',
      );

      return segmentDuration;
    } catch (e, stackTrace) {
      debugPrint('Error appending WAV files: $e');
      debugPrint('Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Gets the duration of a WAV file in seconds
  Future<double> getWavDurationSeconds(String wavPath) async {
    try {
      final file = File(wavPath);
      if (!await file.exists()) {
        throw Exception('WAV file not found: $wavPath');
      }

      final bytes = await file.readAsBytes();
      if (bytes.length < 44) {
        throw Exception('Invalid WAV file: too small');
      }

      // Find the fmt chunk to get audio parameters
      final fmtOffset = _findChunkOffset(bytes, 'fmt ');
      if (fmtOffset == -1) {
        throw Exception('Could not find fmt chunk in WAV file');
      }

      final numChannels = _readUint16LE(bytes, fmtOffset + 10);
      final sampleRate = _readUint32LE(bytes, fmtOffset + 12);
      final bitsPerSample = _readUint16LE(bytes, fmtOffset + 22);

      final dataOffset = _findDataChunkOffset(bytes);
      if (dataOffset == -1) {
        throw Exception('Could not find data chunk in WAV file');
      }

      final dataSize = _readUint32LE(bytes, dataOffset + 4);
      final bytesPerSecond = sampleRate * numChannels * (bitsPerSample ~/ 8);

      if (bytesPerSecond == 0) return 0.0;
      return dataSize / bytesPerSecond;
    } catch (e) {
      debugPrint('Error getting WAV duration: $e');
      rethrow;
    }
  }

  // Helper to find a chunk by ID in a WAV file
  int _findChunkOffset(Uint8List bytes, String chunkIdToFind) {
    // Start after the RIFF header (12 bytes)
    int offset = 12;
    while (offset < bytes.length - 8) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      if (chunkId == chunkIdToFind) {
        return offset;
      }
      // Skip to next chunk (chunk header is 8 bytes + chunk size)
      final chunkSize = _readUint32LE(bytes, offset + 4);
      offset += 8 + chunkSize;
    }
    return -1;
  }

  // Helper to find the 'data' chunk offset in a WAV file
  int _findDataChunkOffset(Uint8List bytes) {
    return _findChunkOffset(bytes, 'data');
  }

  int _readUint16LE(Uint8List bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  int _readUint32LE(Uint8List bytes, int offset) {
    // Use ByteData to properly read unsigned 32-bit integer
    final byteData = ByteData.sublistView(bytes, offset, offset + 4);
    return byteData.getUint32(0, Endian.little);
  }

  void _writeInt32LE(ByteData data, int offset, int value) {
    data.setUint8(offset, value & 0xFF);
    data.setUint8(offset + 1, (value >> 8) & 0xFF);
    data.setUint8(offset + 2, (value >> 16) & 0xFF);
    data.setUint8(offset + 3, (value >> 24) & 0xFF);
  }
}
