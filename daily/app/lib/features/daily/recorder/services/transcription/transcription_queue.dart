import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

import 'package:parachute/core/services/transcription/transcription_service_adapter.dart';
import 'package:parachute/core/services/file_system_service.dart';
import 'models/models.dart';
import 'segment_persistence.dart';

/// Internal: Queued segment for processing
class QueuedSegment {
  final int index;
  final List<int> samples;

  QueuedSegment({required this.index, required this.samples});
}

/// Callback for segment status updates
typedef SegmentUpdateCallback = void Function(TranscriptionSegment segment);

/// Callback for confirmed segment text
typedef ConfirmedSegmentCallback = void Function(String text);

/// Manages a queue of audio segments for transcription
///
/// Features:
/// - Sequential processing to avoid overloading transcription service
/// - Backpressure: drops oldest pending segments if queue is too large
/// - Persistence integration for crash recovery
class TranscriptionQueue {
  final TranscriptionServiceAdapter _transcriptionService;
  final SegmentPersistence _persistence;
  final SegmentUpdateCallback? onSegmentUpdate;
  final ConfirmedSegmentCallback? onConfirmedSegment;

  // Queue size limit to prevent unbounded growth
  static const int _maxQueueSize = 20;

  final List<QueuedSegment> _processingQueue = [];
  final List<TranscriptionSegment> _segments = [];
  bool _isProcessingQueue = false;
  int _activeTranscriptions = 0;

  // Stream controllers
  final _segmentStreamController = StreamController<TranscriptionSegment>.broadcast();
  final _processingStreamController = StreamController<bool>.broadcast();

  Stream<TranscriptionSegment> get segmentStream => _segmentStreamController.stream;
  Stream<bool> get isProcessingStream => _processingStreamController.stream;
  bool get isProcessing => _isProcessingQueue;
  List<TranscriptionSegment> get segments => List.unmodifiable(_segments);

  TranscriptionQueue({
    required TranscriptionServiceAdapter transcriptionService,
    required SegmentPersistence persistence,
    this.onSegmentUpdate,
    this.onConfirmedSegment,
  }) : _transcriptionService = transcriptionService,
       _persistence = persistence;

  /// Queue a segment for transcription (non-blocking)
  ///
  /// Implements backpressure: if queue is full, drops oldest pending segments
  void queueSegment(List<int> samples, {int? index, String? audioFilePath, int? startOffset}) {
    // Backpressure: if queue is too large, drop oldest pending segment
    if (_processingQueue.length >= _maxQueueSize) {
      final dropped = _processingQueue.removeAt(0);
      debugPrint('[TranscriptionQueue] ⚠️ Queue full, dropping segment ${dropped.index}');

      // Update the dropped segment status
      final droppedIdx = _segments.indexWhere((s) => s.index == dropped.index);
      if (droppedIdx != -1) {
        _segments[droppedIdx] = _segments[droppedIdx].copyWith(
          status: TranscriptionSegmentStatus.failed,
          text: '[Skipped - queue full]',
        );
        _emitSegment(_segments[droppedIdx]);
      }

      // Update persistence
      _persistence.updateSegmentStatus(
        dropped.index,
        TranscriptionSegmentStatus.failed,
        text: '[Skipped - queue full]',
      );
    }

    final segmentIndex = index ?? _segments.length + 1;

    final segment = QueuedSegment(
      index: segmentIndex,
      samples: samples,
    );

    _processingQueue.add(segment);

    // Add pending segment to UI
    final uiSegment = TranscriptionSegment(
      index: segment.index,
      text: '',
      status: TranscriptionSegmentStatus.pending,
      timestamp: DateTime.now(),
      duration: Duration(milliseconds: (samples.length / 16).round()),
    );
    _segments.add(uiSegment);
    _emitSegment(uiSegment);

    // Persist segment for crash recovery (only for new segments)
    if (index == null && audioFilePath != null) {
      final persistedSegment = PersistedSegment(
        index: segment.index,
        audioFilePath: audioFilePath,
        startOffsetBytes: startOffset ?? 0,
        durationSamples: samples.length,
        status: TranscriptionSegmentStatus.pending,
        createdAt: DateTime.now(),
      );
      _persistence.persistSegment(persistedSegment);
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
  Future<void> _transcribeSegment(QueuedSegment segment) async {
    debugPrint('[TranscriptionQueue] Transcribing segment ${segment.index}');

    // Update segment status to processing
    final segmentIndex = _segments.indexWhere((s) => s.index == segment.index);
    if (segmentIndex == -1) return;

    _segments[segmentIndex] = _segments[segmentIndex].copyWith(
      status: TranscriptionSegmentStatus.processing,
    );
    _emitSegment(_segments[segmentIndex]);

    // Update persistence status
    await _persistence.updateSegmentStatus(
      segment.index,
      TranscriptionSegmentStatus.processing,
    );

    try {
      // Validate segment has audio data
      if (segment.samples.isEmpty) {
        throw Exception('Segment has no audio data');
      }

      // Save samples to temp WAV file
      final fileSystem = FileSystemService.daily();
      final tempWavPath = await fileSystem.getTranscriptionSegmentPath(segment.index);

      debugPrint('[TranscriptionQueue] Saving temp WAV: $tempWavPath (${segment.samples.length} samples)');
      await _saveSamplesToWav(segment.samples, tempWavPath);

      // Verify file was created
      final file = File(tempWavPath);
      if (!await file.exists()) {
        throw Exception('Failed to create temp WAV file: $tempWavPath');
      }
      debugPrint('[TranscriptionQueue] ✅ Temp WAV created: ${await file.length()} bytes');

      // Transcribe
      _activeTranscriptions++;
      debugPrint('[TranscriptionQueue] Active transcriptions: $_activeTranscriptions');

      try {
        final transcriptResult = await _transcriptionService.transcribeAudio(tempWavPath);

        // Clean up temp WAV file after successful transcription
        try {
          await file.delete();
          debugPrint('[TranscriptionQueue] Cleaned up temp WAV: $tempWavPath');
        } catch (e) {
          debugPrint('[TranscriptionQueue] Failed to delete temp WAV: $e');
        }

        // Check if text is empty
        if (transcriptResult.text.trim().isEmpty) {
          throw Exception('Transcription returned empty text');
        }

        final transcribedText = transcriptResult.text.trim();

        // Update with result
        _segments[segmentIndex] = _segments[segmentIndex].copyWith(
          text: transcribedText,
          status: TranscriptionSegmentStatus.completed,
        );
        _emitSegment(_segments[segmentIndex]);

        // Notify callback
        onConfirmedSegment?.call(transcribedText);
        debugPrint('[TranscriptionQueue] Segment ${segment.index}: "$transcribedText"');

        // Update persistence
        await _persistence.updateSegmentStatus(
          segment.index,
          TranscriptionSegmentStatus.completed,
          text: transcribedText,
        );

        debugPrint('[TranscriptionQueue] Segment ${segment.index} done: "$transcribedText"');

        // Cleanup completed segments periodically
        if (segment.index % 5 == 0) {
          await _persistence.cleanupCompletedSegments();
        }
      } catch (e) {
        debugPrint('[TranscriptionQueue] Transcription failed: $e');

        // Clean up temp WAV file on error too
        try {
          final errorFile = File(tempWavPath);
          if (await errorFile.exists()) {
            await errorFile.delete();
          }
        } catch (_) {}

        // Update persistence with failure
        await _persistence.updateSegmentStatus(
          segment.index,
          TranscriptionSegmentStatus.failed,
          text: '[Transcription failed: $e]',
        );

        _segments[segmentIndex] = _segments[segmentIndex].copyWith(
          text: '[Transcription failed]',
          status: TranscriptionSegmentStatus.failed,
        );
        _emitSegment(_segments[segmentIndex]);
      } finally {
        _activeTranscriptions--;
        debugPrint('[TranscriptionQueue] Active transcriptions: $_activeTranscriptions');
      }
    } catch (e) {
      debugPrint('[TranscriptionQueue] Failed to process segment: $e');
    }
  }

  void _emitSegment(TranscriptionSegment segment) {
    if (!_segmentStreamController.isClosed) {
      _segmentStreamController.add(segment);
    }
    onSegmentUpdate?.call(segment);
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
    bytes.add(_int32ToBytes(sampleRate * numChannels * bitsPerSample ~/ 8)); // byte rate
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

  /// Get complete transcript (all segments combined)
  String getCompleteTranscript() {
    return _segments
        .where((s) => s.status == TranscriptionSegmentStatus.completed)
        .map((s) => s.text)
        .join('\n');
  }

  /// Clear all segments and queue
  void clear() {
    _segments.clear();
    _processingQueue.clear();
  }

  /// Dispose resources
  Future<void> dispose() async {
    await _segmentStreamController.close();
    await _processingStreamController.close();
  }
}
