import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
    debugPrint('[OmiCaptureService] Starting button listener');

    final connection = bluetoothService.activeConnection;
    if (connection == null) {
      debugPrint('[OmiCaptureService] No active connection');
      return;
    }

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
        debugPrint('[OmiCaptureService] Button listener started');

        // Check for pending recordings and detect mode
        await _detectModeAndCheckRecordings();
      } else {
        debugPrint('[OmiCaptureService] Failed to start button listener');
      }
    } catch (e) {
      debugPrint('[OmiCaptureService] Error starting button listener: $e');
    }
  }

  /// Detect which mode the device supports and check for pending recordings
  Future<void> _detectModeAndCheckRecordings() async {
    final connection = bluetoothService.activeConnection;
    if (connection == null || connection is! OmiDeviceConnection) {
      debugPrint('[OmiCaptureService] No OmiDeviceConnection, using streaming mode');
      _useStreamingMode = true;
      _modeDetected = true;
      return;
    }

    final omiConnection = connection;

    if (!omiConnection.hasStorageService) {
      debugPrint('[OmiCaptureService] No storage service, using streaming mode');
      _useStreamingMode = true;
      _modeDetected = true;
      return;
    }

    // Check storage info to detect mode
    try {
      final storageInfo = await omiConnection.getStorageInfo();
      if (storageInfo == null) {
        debugPrint('[OmiCaptureService] Failed to get storage info, using streaming mode');
        _useStreamingMode = true;
        _modeDetected = true;
        return;
      }

      final fileSize = storageInfo[0];
      final currentOffset = storageInfo[1];

      debugPrint('[OmiCaptureService] Storage info: fileSize=$fileSize, offset=$currentOffset');

      // If there's data on storage, device supports store-and-forward
      if (fileSize > 0 || currentOffset > 0) {
        debugPrint('[OmiCaptureService] Storage has data, using store-and-forward mode');
        _useStreamingMode = false;
        _modeDetected = true;

        // Download any pending recordings
        final totalBytes = currentOffset > 0 ? currentOffset : fileSize;
        if (totalBytes > 0) {
          await _downloadRecording(omiConnection, fileSize, totalBytes);
        }
      } else {
        // Storage is empty - could be either mode
        // We'll detect after first recording completes
        debugPrint('[OmiCaptureService] Storage empty, will detect mode after first recording');
        _modeDetected = false;
      }
    } catch (e) {
      debugPrint('[OmiCaptureService] Error detecting mode: $e, using streaming mode');
      _useStreamingMode = true;
      _modeDetected = true;
    }
  }

  /// Stop listening for button events
  Future<void> stopListening() async {
    debugPrint('[OmiCaptureService] Stopping button listener');

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

    // Log button press prominently
    debugPrint('');
    debugPrint('═══════════════════════════════════════════════════');
    debugPrint('🔘 OMI BUTTON EVENT!');
    debugPrint('   Type: $buttonEvent');
    debugPrint('   Code: $buttonCode');
    debugPrint('   Device Recording: ${_deviceIsRecording ? "ACTIVE" : "INACTIVE"}');
    debugPrint('   Mode: ${_useStreamingMode ? "STREAMING" : "STORE-AND-FORWARD"}${_modeDetected ? "" : " (detecting)"}');
    debugPrint('═══════════════════════════════════════════════════');
    debugPrint('');

    if (buttonEvent == ButtonEvent.unknown) {
      debugPrint('[OmiCaptureService] ⚠️  Unknown button event: $buttonCode');
      return;
    }

    // Handle button press/release events
    if (buttonEvent == ButtonEvent.buttonPressed) {
      debugPrint('[OmiCaptureService] 👆 Button pressed');
      return;
    }

    if (buttonEvent == ButtonEvent.buttonReleased) {
      debugPrint('[OmiCaptureService] 👆 Button released');

      // Legacy mode: If firmware doesn't send tap count events,
      // treat button release as a toggle after timeout
      _legacyButtonTimer?.cancel();
      _legacyButtonTimer = Timer(const Duration(milliseconds: 700), () {
        debugPrint('[OmiCaptureService] ⚠️  No tap count received - using legacy mode');
        _handleRecordingToggle(1);
      });
      return;
    }

    // Cancel legacy timer - we got a proper tap count
    _legacyButtonTimer?.cancel();
    _legacyButtonTimer = null;

    // Handle tap events
    _handleRecordingToggle(buttonEvent.toCode());
  }

  /// Handle recording start/stop based on button event
  void _handleRecordingToggle(int tapCount) {
    final wasRecording = _deviceIsRecording;
    _deviceIsRecording = !_deviceIsRecording;
    _currentButtonTapCount = tapCount;

    debugPrint('[OmiCaptureService] Device recording state: $wasRecording -> $_deviceIsRecording');
    onRecordingStateChanged?.call(_deviceIsRecording);

    if (_deviceIsRecording) {
      // Device started recording
      debugPrint('[OmiCaptureService] ⏺️  Device started recording');
      onStatusMessage?.call('Recording on device...');

      // If using streaming mode, start capturing audio
      if (_useStreamingMode || !_modeDetected) {
        _startStreamingCapture();
      }
    } else {
      // Device stopped recording
      debugPrint('[OmiCaptureService] ⏹️  Device stopped recording');

      if (_useStreamingMode) {
        // Streaming mode: stop and save what we captured
        _stopStreamingCapture();
        _saveStreamingRecording();
      } else if (!_modeDetected) {
        // Mode not detected yet - check storage first, fall back to streaming
        _stopStreamingCapture(); // Stop streaming capture if it was running

        onStatusMessage?.call('Checking for recording...');

        Future.delayed(const Duration(milliseconds: 500), () async {
          final hasStorageRecording = await checkAndDownloadRecordings();
          if (!hasStorageRecording && _wavBytesUtil != null && _wavBytesUtil!.hasFrames) {
            // No storage data, but we have streaming data - use streaming mode
            debugPrint('[OmiCaptureService] No storage data, detected streaming mode');
            _useStreamingMode = true;
            _modeDetected = true;
            await _saveStreamingRecording();
          } else if (hasStorageRecording) {
            // Storage worked - use store-and-forward mode
            debugPrint('[OmiCaptureService] Storage has data, detected store-and-forward mode');
            _useStreamingMode = false;
            _modeDetected = true;
          }
        });
      } else {
        // Store-and-forward mode
        onStatusMessage?.call('Recording complete, downloading...');

        Future.delayed(const Duration(milliseconds: 500), () {
          checkAndDownloadRecordings();
        });
      }
    }
  }

  // ============================================================
  // Real-time Streaming Mode
  // ============================================================

  /// Start capturing audio stream from device
  Future<void> _startStreamingCapture() async {
    debugPrint('[OmiCaptureService] Starting streaming capture');

    final connection = bluetoothService.activeConnection;
    if (connection == null) {
      debugPrint('[OmiCaptureService] No active connection for streaming');
      return;
    }

    try {
      // Get audio codec from device
      final codec = await connection.getAudioCodec();
      debugPrint('[OmiCaptureService] Audio codec: $codec');

      // Initialize WAV builder
      _wavBytesUtil = WavBytesUtil(codec: codec);
      _wavBytesUtil!.clear();

      // Start audio stream
      _audioSubscription = await connection.getBleAudioBytesListener(
        onAudioBytesReceived: _onAudioData,
      );

      if (_audioSubscription == null) {
        debugPrint('[OmiCaptureService] Failed to start audio stream');
        _wavBytesUtil = null;
        return;
      }

      _recordingStartTime = DateTime.now();
      debugPrint('[OmiCaptureService] Streaming capture started');
    } catch (e) {
      debugPrint('[OmiCaptureService] Error starting streaming capture: $e');
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
    debugPrint('[OmiCaptureService] Stopping streaming capture');

    await _audioSubscription?.cancel();
    _audioSubscription = null;
  }

  /// Save recording from streaming data to journal
  Future<void> _saveStreamingRecording() async {
    if (_wavBytesUtil == null || !_wavBytesUtil!.hasFrames) {
      debugPrint('[OmiCaptureService] No streaming data to save');
      _cleanupStreaming();
      return;
    }

    try {
      final wavBytes = _wavBytesUtil!.buildWavFile();
      final duration = _wavBytesUtil!.duration;

      debugPrint('[OmiCaptureService] Built WAV file: ${wavBytes.length} bytes, duration: $duration');

      // Save WAV file to temp location first
      final fileSystem = FileSystemService.daily();
      final wavFilePath = await fileSystem.getRecordingTempPath();
      final wavFile = File(wavFilePath);
      await wavFile.writeAsBytes(wavBytes);

      debugPrint('[OmiCaptureService] Saved temp WAV file: $wavFilePath');

      _cleanupStreaming();

      // Save to journal with empty transcript (will be transcribed async)
      final journalService = await getJournalService();
      final result = await journalService.addVoiceEntry(
        transcript: '', // Will be transcribed async
        audioPath: wavFilePath,
        durationSeconds: duration.inSeconds,
        title: 'Omi Recording',
      );

      debugPrint('[OmiCaptureService] Recording saved to journal: ${result.entry.id}');
      onStatusMessage?.call('Recording saved!');
      onRecordingSaved?.call(result.entry);

      // Transcribe and update the entry
      _transcribeAndUpdateEntry(result.entry, wavFilePath).catchError((e) {
        debugPrint('[OmiCaptureService] Auto-transcribe error (non-fatal): $e');
      });
    } catch (e) {
      debugPrint('[OmiCaptureService] Error saving streaming recording: $e');
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
    if (_isDownloading) {
      debugPrint('[OmiCaptureService] Already downloading, skipping check');
      return false;
    }

    final connection = bluetoothService.activeConnection;
    if (connection == null) {
      debugPrint('[OmiCaptureService] No active connection');
      return false;
    }

    if (connection is! OmiDeviceConnection) {
      debugPrint('[OmiCaptureService] Connection is not OmiDeviceConnection');
      return false;
    }

    final omiConnection = connection;

    if (!omiConnection.hasStorageService) {
      debugPrint('[OmiCaptureService] Storage service not available');
      return false;
    }

    try {
      final storageInfo = await omiConnection.getStorageInfo();
      if (storageInfo == null) {
        debugPrint('[OmiCaptureService] Failed to get storage info');
        return false;
      }

      final fileSize = storageInfo[0];
      final currentOffset = storageInfo[1];

      debugPrint('[OmiCaptureService] Storage info: fileSize=$fileSize, offset=$currentOffset');

      final totalBytes = currentOffset > 0 ? currentOffset : fileSize;

      if (totalBytes == 0) {
        debugPrint('[OmiCaptureService] No recordings on device');
        onStatusMessage?.call('No recordings on device');
        return false;
      }

      if (_lastKnownStorageSize != null && totalBytes <= _lastKnownStorageSize!) {
        debugPrint('[OmiCaptureService] No new recordings since last check');
        return false;
      }

      debugPrint('[OmiCaptureService] New recording detected: $totalBytes bytes');
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
        onComplete: () {
          debugPrint('[OmiCaptureService] Download complete: ${downloadedData.length} bytes');
          completer.complete();
        },
        onError: (error) {
          debugPrint('[OmiCaptureService] Download error: $error');
          completer.completeError(error);
        },
      );

      await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          throw TimeoutException('Download timed out');
        },
      );

      await _downloadSubscription?.cancel();
      _downloadSubscription = null;

      if (downloadedData.isEmpty) {
        debugPrint('[OmiCaptureService] Downloaded data is empty');
        onStatusMessage?.call('Download failed - no data');
        return;
      }

      _lastKnownStorageSize = totalBytes;

      await _processDownloadedRecording(Uint8List.fromList(downloadedData));

      await connection.deleteStorageFile(1);
      debugPrint('[OmiCaptureService] Deleted recording from device');
    } catch (e) {
      debugPrint('[OmiCaptureService] Download failed: $e');
      onStatusMessage?.call('Download failed: $e');
    } finally {
      _isDownloading = false;
      await _downloadSubscription?.cancel();
      _downloadSubscription = null;
    }
  }

  /// Process downloaded audio data and save to journal
  Future<void> _processDownloadedRecording(Uint8List audioData) async {
    debugPrint('[OmiCaptureService] Processing downloaded recording: ${audioData.length} bytes');
    onStatusMessage?.call('Processing recording...');

    try {
      // Save raw Opus data to temp location
      final fileSystem = FileSystemService.daily();
      final tempPath = await fileSystem.getTempWavPath(prefix: 'omi_download');
      // Change extension to .opus since this is Opus data
      final opusPath = tempPath.replaceAll('.wav', '.opus');

      final opusFile = File(opusPath);
      await opusFile.writeAsBytes(audioData);
      debugPrint('[OmiCaptureService] Saved temp Opus file: $opusPath');

      // Estimate duration (rough estimate: ~3KB per second for Opus)
      final estimatedDurationMs = (audioData.length / 3000 * 1000).round();
      final durationSeconds = (estimatedDurationMs / 1000).round();

      // Save to journal with empty transcript (will be transcribed async)
      final journalService = await getJournalService();
      final result = await journalService.addVoiceEntry(
        transcript: '', // Will be transcribed async
        audioPath: opusPath,
        durationSeconds: durationSeconds,
        title: 'Omi Recording',
      );

      debugPrint('[OmiCaptureService] Recording saved to journal: ${result.entry.id}');
      onStatusMessage?.call('Recording saved!');
      onRecordingSaved?.call(result.entry);

      // Transcribe and update the entry
      _transcribeAndUpdateEntry(result.entry, opusPath).catchError((e) {
        debugPrint('[OmiCaptureService] Auto-transcribe error (non-fatal): $e');
      });
    } catch (e) {
      debugPrint('[OmiCaptureService] Error processing recording: $e');
      onStatusMessage?.call('Error processing recording');
    }
  }

  /// Transcribe audio and update journal entry
  Future<void> _transcribeAndUpdateEntry(JournalEntry entry, String audioPath) async {
    try {
      debugPrint('[OmiCaptureService] Starting transcription...');
      onStatusMessage?.call('Transcribing...');

      final transcriptResult = await transcriptionService.transcribeAudio(
        audioPath,
        language: 'auto',
        onProgress: (progress) {
          onStatusMessage?.call('Transcribing: ${progress.status}');
        },
      );

      debugPrint('[OmiCaptureService] Transcription complete: ${transcriptResult.text.length} chars');
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
      debugPrint('[OmiCaptureService] Auto-transcription failed: $e');
      onStatusMessage?.call('Transcription failed');
    }
  }

  /// Dispose service
  Future<void> dispose() async {
    await stopListening();
    _cleanupStreaming();
  }
}
