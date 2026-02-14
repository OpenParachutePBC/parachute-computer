import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:parachute/features/daily/journal/models/journal_entry.dart';
import 'package:parachute/features/daily/journal/services/journal_service.dart';
import 'package:parachute/features/daily/recorder/services/omi/models.dart';
import 'package:parachute/features/daily/recorder/services/omi/omi_bluetooth_service.dart';
import 'package:parachute/features/daily/recorder/services/omi/omi_connection.dart';
import 'package:parachute/core/services/transcription/transcription_service_adapter.dart';
import 'package:parachute/features/daily/recorder/utils/audio/wav_bytes_util.dart';
import 'package:parachute/core/services/file_system_service.dart';

/// Service for capturing audio recordings from Omi device
///
/// Supports two modes:
/// 1. Store-and-Forward: Device records to SD card, app downloads when done
/// 2. Real-time Streaming: Audio streams over BLE during recording (fallback)
///
/// Automatically detects which mode the device supports.
class OmiCaptureService {
  final OmiBluetoothService bluetoothService;
  final Future<JournalService> Function() getJournalService;
  final TranscriptionServiceAdapter transcriptionService;

  StreamSubscription? _buttonSubscription;
  StreamSubscription? _downloadSubscription;
  StreamSubscription? _audioSubscription;

  // Track device recording state (based on button events)
  bool _deviceIsRecording = false;

  // Track if we're currently downloading from device
  bool _isDownloading = false;

  // Last known storage info for change detection
  int? _lastKnownStorageSize;

  // Mode detection
  bool _useStreamingMode = false;
  bool _modeDetected = false;

  // Real-time streaming state
  WavBytesUtil? _wavBytesUtil;
  DateTime? _recordingStartTime;
  // ignore: unused_field
  int? _currentButtonTapCount;
  Timer? _legacyButtonTimer;

  // Callbacks for UI updates
  Function(bool isRecording)? onRecordingStateChanged;
  Function(String message)? onStatusMessage;
  Function(JournalEntry entry)? onRecordingSaved;

  OmiCaptureService({
    required this.bluetoothService,
    required this.getJournalService,
    required this.transcriptionService,
  });

  /// Check if device is currently recording
  bool get isRecording => _deviceIsRecording;

  /// Check if we're downloading from device
  bool get isDownloading => _isDownloading;

  /// Check if using streaming mode
  bool get isStreamingMode => _useStreamingMode;

  /// Get current recording duration (streaming mode only)
  Duration? get recordingDuration {
    if (_recordingStartTime == null) return null;
    return DateTime.now().difference(_recordingStartTime!);
  }

  /// Start listening for button events from device
  /// Also checks for any pending recordings on device
  Future<void> startListening() async {
    final connection = bluetoothService.activeConnection;
    if (connection == null) return;

    // Reset tracking state on new connection
    _lastKnownStorageSize = null;
    _deviceIsRecording = false;
    _modeDetected = false;
    _useStreamingMode = false;

    try {
      _buttonSubscription = await connection.getBleButtonListener(
        onButtonReceived: _onButtonEvent,
      );

      if (_buttonSubscription != null) {
        await _detectModeAndCheckRecordings();
      }
    } catch (e) {
      debugPrint('[OmiCaptureService] Error starting: $e');
    }
  }

  /// Detect which mode the device supports and check for pending recordings
  Future<void> _detectModeAndCheckRecordings() async {
    final connection = bluetoothService.activeConnection;
    if (connection == null || connection is! OmiDeviceConnection) {
      _useStreamingMode = true;
      _modeDetected = true;
      return;
    }

    final omiConnection = connection;

    if (!omiConnection.hasStorageService) {
      _useStreamingMode = true;
      _modeDetected = true;
      return;
    }

    // Check storage info to detect mode
    try {
      final storageInfo = await omiConnection.getStorageInfo();
      if (storageInfo == null) {
        _useStreamingMode = true;
        _modeDetected = true;
        return;
      }

      final fileSize = storageInfo[0];
      final currentOffset = storageInfo[1];

      // If there's data on storage, device supports store-and-forward
      if (fileSize > 0 || currentOffset > 0) {
        _useStreamingMode = false;
        _modeDetected = true;

        // Download any pending recordings
        final totalBytes = currentOffset > 0 ? currentOffset : fileSize;
        if (totalBytes > 0) {
          await _downloadRecording(omiConnection, fileSize, totalBytes);
        }
      } else {
        // Storage is empty - will detect after first recording completes
        _modeDetected = false;
      }
    } catch (e) {
      debugPrint('[OmiCaptureService] Error detecting mode: $e');
      _useStreamingMode = true;
      _modeDetected = true;
    }
  }

  /// Stop listening for button events
  Future<void> stopListening() async {
    await _buttonSubscription?.cancel();
    _buttonSubscription = null;

    await _downloadSubscription?.cancel();
    _downloadSubscription = null;

    await _audioSubscription?.cancel();
    _audioSubscription = null;

    _legacyButtonTimer?.cancel();
    _legacyButtonTimer = null;
  }

  /// Handle button event from device
  void _onButtonEvent(List<int> data) {
    if (data.isEmpty) return;

    final buttonCode = data[0];
    final buttonEvent = ButtonEvent.fromCode(buttonCode);
    debugPrint('[OmiCaptureService] Button: $buttonEvent (code=$buttonCode, recording=$_deviceIsRecording)');

    if (buttonEvent == ButtonEvent.unknown) {
      return;
    }

    // Handle button press/release events (ignore, wait for tap count)
    if (buttonEvent == ButtonEvent.buttonPressed) {
      return;
    }

    if (buttonEvent == ButtonEvent.buttonReleased) {
      // Legacy mode: If firmware doesn't send tap count events,
      // treat button release as a toggle after timeout
      _legacyButtonTimer?.cancel();
      _legacyButtonTimer = Timer(const Duration(milliseconds: 700), () {
        _handleRecordingToggle(1);
      });
      return;
    }

    // Cancel legacy timer - we got a proper tap count
    _legacyButtonTimer?.cancel();
    _legacyButtonTimer = null;

    // Handle tap events (singleTap, doubleTap, tripleTap)
    _handleRecordingToggle(buttonEvent.toCode());
  }

  /// Handle recording start/stop based on button event
  void _handleRecordingToggle(int tapCount) {
    _deviceIsRecording = !_deviceIsRecording;
    _currentButtonTapCount = tapCount;
    onRecordingStateChanged?.call(_deviceIsRecording);

    if (_deviceIsRecording) {
      onStatusMessage?.call('Recording...');
      // Always capture streaming audio when connected via BLE
      // The device streams in real-time when BLE is connected (doesn't store to SD)
      _startStreamingCapture();
    } else {
      // Stop streaming capture
      _stopStreamingCapture();

      // Save if we have streaming data
      if (_wavBytesUtil != null && _wavBytesUtil!.hasFrames) {
        _saveStreamingRecording();
      } else {
        onStatusMessage?.call('No audio captured');
      }
    }
  }

  // ============================================================
  // Real-time Streaming Mode
  // ============================================================

  /// Start capturing audio stream from device
  Future<void> _startStreamingCapture() async {
    final connection = bluetoothService.activeConnection;
    if (connection == null) return;

    try {
      final codec = await connection.getAudioCodec();
      _wavBytesUtil = WavBytesUtil(codec: codec);
      _wavBytesUtil!.clear();

      _audioSubscription = await connection.getBleAudioBytesListener(
        onAudioBytesReceived: _onAudioData,
      );

      if (_audioSubscription == null) {
        _wavBytesUtil = null;
        return;
      }

      _recordingStartTime = DateTime.now();
    } catch (e) {
      debugPrint('[OmiCaptureService] Error starting stream: $e');
      _wavBytesUtil = null;
    }
  }

  /// Receive audio data from device stream
  void _onAudioData(List<int> data) {
    if (_wavBytesUtil == null) return;
    _wavBytesUtil!.storeFramePacket(data);
  }

  /// Stop streaming capture
  Future<void> _stopStreamingCapture() async {
    await _audioSubscription?.cancel();
    _audioSubscription = null;
  }

  /// Save recording from streaming data to journal
  Future<void> _saveStreamingRecording() async {
    if (_wavBytesUtil == null || !_wavBytesUtil!.hasFrames) {
      _cleanupStreaming();
      return;
    }

    try {
      final wavBytes = _wavBytesUtil!.buildWavFile();
      final duration = _wavBytesUtil!.duration;

      // Save WAV file to temp location first
      final fileSystem = FileSystemService.daily();
      final wavFilePath = await fileSystem.getRecordingTempPath();
      final wavFile = File(wavFilePath);
      await wavFile.writeAsBytes(wavBytes);

      _cleanupStreaming();

      // Save to journal with empty transcript (will be transcribed async)
      final journalService = await getJournalService();
      final result = await journalService.addVoiceEntry(
        transcript: '', // Will be transcribed async
        audioPath: wavFilePath,
        durationSeconds: duration.inSeconds,
        title: 'Omi Recording',
      );

      onStatusMessage?.call('Recording saved!');
      onRecordingSaved?.call(result.entry);

      // Transcribe using the vault path (not the temp path)
      if (result.entry.audioPath != null) {
        final fileSystem = FileSystemService.daily();
        final vaultAudioPath = await fileSystem.resolveAssetPath(result.entry.audioPath!);
        _transcribeAndUpdateEntry(result.entry, vaultAudioPath).catchError((e) {
          debugPrint('[OmiCaptureService] Transcribe error: $e');
        });
      }

      // Clean up the temp file since it's now copied to vault
      try {
        await File(wavFilePath).delete();
      } catch (_) {}
    } catch (e) {
      debugPrint('[OmiCaptureService] Error saving recording: $e');
      onStatusMessage?.call('Error saving recording');
      _cleanupStreaming();
    }
  }

  /// Clean up streaming resources
  void _cleanupStreaming() {
    _wavBytesUtil = null;
    _recordingStartTime = null;
    _currentButtonTapCount = null;
  }

  // ============================================================
  // Store-and-Forward Mode
  // ============================================================

  /// Check device storage and download any new recordings
  /// Returns true if a recording was found and downloaded
  Future<bool> checkAndDownloadRecordings() async {
    if (_isDownloading) return false;

    final connection = bluetoothService.activeConnection;
    if (connection == null || connection is! OmiDeviceConnection) {
      return false;
    }

    final omiConnection = connection;
    if (!omiConnection.hasStorageService) return false;

    try {
      final storageInfo = await omiConnection.getStorageInfo();
      if (storageInfo == null) return false;

      final fileSize = storageInfo[0];
      final currentOffset = storageInfo[1];
      final totalBytes = currentOffset > 0 ? currentOffset : fileSize;

      if (totalBytes == 0) {
        onStatusMessage?.call('No recordings on device');
        return false;
      }

      if (_lastKnownStorageSize != null && totalBytes <= _lastKnownStorageSize!) {
        return false;
      }

      await _downloadRecording(omiConnection, fileSize, totalBytes);
      return true;
    } catch (e) {
      debugPrint('[OmiCaptureService] Error checking storage: $e');
      onStatusMessage?.call('Error checking device storage');
      return false;
    }
  }

  /// Download recording from device storage
  Future<void> _downloadRecording(
    OmiDeviceConnection connection,
    int fileSize,
    int totalBytes,
  ) async {
    _isDownloading = true;
    onStatusMessage?.call('Downloading recording...');

    final downloadedData = <int>[];
    final completer = Completer<void>();

    try {
      _downloadSubscription = await connection.startStorageDownload(
        fileNum: 1,
        startOffset: 0,
        onDataReceived: (data) {
          downloadedData.addAll(data);
          final progress = (downloadedData.length / totalBytes * 100).clamp(0, 100).toInt();
          onStatusMessage?.call('Downloading: $progress%');
        },
        onComplete: () => completer.complete(),
        onError: (error) => completer.completeError(error),
      );

      await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException('Download timed out'),
      );

      await _downloadSubscription?.cancel();
      _downloadSubscription = null;

      if (downloadedData.isEmpty) {
        onStatusMessage?.call('Download failed - no data');
        return;
      }

      _lastKnownStorageSize = totalBytes;
      await _processDownloadedRecording(Uint8List.fromList(downloadedData));
      await connection.deleteStorageFile(1);
    } catch (e) {
      debugPrint('[OmiCaptureService] Download failed: $e');
      onStatusMessage?.call('Download failed');
    } finally {
      _isDownloading = false;
      await _downloadSubscription?.cancel();
      _downloadSubscription = null;
    }
  }

  /// Process downloaded audio data and save to journal
  ///
  /// The Omi device stores audio as sequential Opus frames (80 bytes each at 16kHz).
  /// We decode these to PCM and save as WAV for compatibility with transcription.
  Future<void> _processDownloadedRecording(Uint8List audioData) async {
    onStatusMessage?.call('Processing recording...');

    try {
      final fileSystem = FileSystemService.daily();

      // Convert Opus frames to WAV
      final wavBytes = await _convertOpusToWav(audioData);
      if (wavBytes == null || wavBytes.isEmpty) {
        onStatusMessage?.call('Failed to process recording');
        return;
      }

      // Save WAV to temp location
      final wavPath = await fileSystem.getRecordingTempPath();
      final wavFile = File(wavPath);
      await wavFile.writeAsBytes(wavBytes);

      // Calculate actual duration from WAV data
      // WAV header is 44 bytes, 16-bit samples at 16kHz mono
      final pcmBytes = wavBytes.length - 44;
      final samples = pcmBytes ~/ 2; // 2 bytes per sample
      final durationSeconds = samples ~/ 16000;

      // Save to journal with empty transcript (will be transcribed async)
      final journalService = await getJournalService();
      final result = await journalService.addVoiceEntry(
        transcript: '', // Will be transcribed async
        audioPath: wavPath,
        durationSeconds: durationSeconds,
        title: 'Omi Recording',
      );

      onStatusMessage?.call('Recording saved!');
      onRecordingSaved?.call(result.entry);

      // Transcribe using the vault path (not the temp path)
      if (result.entry.audioPath != null) {
        final vaultAudioPath = await fileSystem.resolveAssetPath(result.entry.audioPath!);
        _transcribeAndUpdateEntry(result.entry, vaultAudioPath).catchError((e) {
          debugPrint('[OmiCaptureService] Transcribe error: $e');
        });
      }

      // Clean up the temp file
      try {
        await File(wavPath).delete();
      } catch (_) {}
    } catch (e) {
      debugPrint('[OmiCaptureService] Error processing: $e');
      onStatusMessage?.call('Error processing recording');
    }
  }

  /// Convert raw Opus frames from device storage to WAV
  ///
  /// The Omi device stores Opus frames sequentially. Each frame is typically
  /// 80 bytes for 16kHz mono audio with 20ms frame size.
  Future<Uint8List?> _convertOpusToWav(Uint8List opusData) async {
    try {
      final decoder = SimpleOpusDecoder(sampleRate: 16000, channels: 1);
      final decodedSamples = <int>[];
      const frameSize = 80; // Typical Opus frame size for Omi

      int offset = 0;
      int framesDecoded = 0;
      int errorsEncountered = 0;

      while (offset < opusData.length) {
        int bytesToRead = frameSize;
        if (offset + bytesToRead > opusData.length) {
          bytesToRead = opusData.length - offset;
        }

        if (bytesToRead < 10) break; // Too small to be a valid frame

        try {
          final frame = opusData.sublist(offset, offset + bytesToRead);
          final decoded = decoder.decode(input: Uint8List.fromList(frame));
          decodedSamples.addAll(decoded);
          framesDecoded++;
        } catch (_) {
          errorsEncountered++;
          if (errorsEncountered > 10 && framesDecoded == 0) {
            return null;
          }
        }

        offset += bytesToRead;
      }

      if (decodedSamples.isEmpty) return null;

      return _buildWavFromSamples(decodedSamples, 16000);
    } catch (e) {
      debugPrint('[OmiCaptureService] Opus conversion failed: $e');
      return null;
    }
  }

  /// Build a WAV file from PCM samples
  Uint8List _buildWavFromSamples(List<int> samples, int sampleRate) {
    // Convert samples to bytes (16-bit little-endian)
    final pcmData = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      pcmData.setInt16(i * 2, samples[i], Endian.little);
    }
    final pcmBytes = pcmData.buffer.asUint8List();

    // Build WAV header
    final header = ByteData(44);
    final fileSize = pcmBytes.length + 36;
    const channelCount = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channelCount * (bitsPerSample ~/ 8);
    final blockAlign = channelCount * (bitsPerSample ~/ 8);

    // RIFF chunk
    header.setUint8(0, 0x52); // 'R'
    header.setUint8(1, 0x49); // 'I'
    header.setUint8(2, 0x46); // 'F'
    header.setUint8(3, 0x46); // 'F'
    header.setUint32(4, fileSize, Endian.little);
    header.setUint8(8, 0x57); // 'W'
    header.setUint8(9, 0x41); // 'A'
    header.setUint8(10, 0x56); // 'V'
    header.setUint8(11, 0x45); // 'E'

    // fmt chunk
    header.setUint8(12, 0x66); // 'f'
    header.setUint8(13, 0x6D); // 'm'
    header.setUint8(14, 0x74); // 't'
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little); // Subchunk1Size
    header.setUint16(20, 1, Endian.little); // AudioFormat (1 = PCM)
    header.setUint16(22, channelCount, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);

    // data chunk
    header.setUint8(36, 0x64); // 'd'
    header.setUint8(37, 0x61); // 'a'
    header.setUint8(38, 0x74); // 't'
    header.setUint8(39, 0x61); // 'a'
    header.setUint32(40, pcmBytes.length, Endian.little);

    return Uint8List.fromList([...header.buffer.asUint8List(), ...pcmBytes]);
  }

  /// Transcribe audio and update journal entry
  Future<void> _transcribeAndUpdateEntry(JournalEntry entry, String audioPath) async {
    try {
      onStatusMessage?.call('Transcribing...');

      final transcriptResult = await transcriptionService.transcribeAudio(
        audioPath,
        language: 'auto',
        onProgress: (progress) {
          onStatusMessage?.call('Transcribing: ${progress.status}');
        },
      );

      onStatusMessage?.call('Transcription complete!');

      // Update the journal entry with the transcript
      final journalService = await getJournalService();
      final updatedEntry = entry.copyWith(
        content: transcriptResult.text,
        isPendingTranscription: false,
      );
      await journalService.updateEntry(DateTime.now(), updatedEntry);

      onRecordingSaved?.call(updatedEntry);
    } catch (e) {
      debugPrint('[OmiCaptureService] Transcription failed: $e');
      onStatusMessage?.call('Transcription failed');
    }
  }

  /// Dispose service
  Future<void> dispose() async {
    await stopListening();
    _cleanupStreaming();
  }
}
