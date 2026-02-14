import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'models/models.dart';

/// Handles persistence of transcription segments for crash recovery
///
/// Segments are saved to JSON before transcription starts, allowing
/// recovery if the app is killed mid-transcription.
class SegmentPersistence {
  static const String _pendingSegmentsFileName = 'pending_segments.json';

  String? _pendingSegmentsPath;
  final String _tempDirectory;

  SegmentPersistence(this._tempDirectory) {
    _pendingSegmentsPath = path.join(_tempDirectory, _pendingSegmentsFileName);
  }

  /// Recover pending segments from a previous interrupted session
  ///
  /// Returns list of segments that need to be re-transcribed.
  /// Segments with status pending, processing, or interrupted are recovered.
  Future<List<PersistedSegment>> recoverPendingSegments() async {
    if (_pendingSegmentsPath == null) return [];

    final file = File(_pendingSegmentsPath!);
    if (!await file.exists()) {
      debugPrint('[SegmentPersistence] No pending segments to recover');
      return [];
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
        debugPrint('[SegmentPersistence] No pending segments to recover');
        await file.delete();
        return [];
      }

      debugPrint('[SegmentPersistence] 🔄 Found ${pendingSegments.length} pending segments');
      return pendingSegments;
    } catch (e) {
      debugPrint('[SegmentPersistence] ❌ Failed to parse pending segments: $e');
      // Delete corrupted file
      await file.delete();
      return [];
    }
  }

  /// Save a segment to persistent storage before transcription
  Future<void> persistSegment(PersistedSegment segment) async {
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
      debugPrint('[SegmentPersistence] 💾 Persisted segment ${segment.index}');
    } catch (e) {
      debugPrint('[SegmentPersistence] ⚠️ Failed to persist segment: $e');
    }
  }

  /// Update a persisted segment's status
  Future<void> updateSegmentStatus(
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
      debugPrint('[SegmentPersistence] ⚠️ Failed to update persisted segment: $e');
    }
  }

  /// Clean up completed segments from persistence
  Future<void> cleanupCompletedSegments() async {
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
        debugPrint('[SegmentPersistence] 🧹 Cleaned up all completed segments');
      } else {
        await file.writeAsString(jsonEncode(segments.map((s) => s.toJson()).toList()));
      }
    } catch (e) {
      debugPrint('[SegmentPersistence] ⚠️ Failed to cleanup segments: $e');
    }
  }
}
