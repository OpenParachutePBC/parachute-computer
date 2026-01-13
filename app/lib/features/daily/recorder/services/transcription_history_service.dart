import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks historical transcription times to improve progress estimates
///
/// Stores transcription performance data in app storage (SharedPreferences)
/// and uses median ratios for more accurate time remaining predictions.
class TranscriptionHistoryService {
  static const String _storageKey = 'transcription_history';
  static const int _maxHistorySize = 50; // Keep last 50 transcriptions

  // Default speed ratio if no history exists (conservative estimate)
  static const double _defaultSpeedRatio = 10.0;

  List<TranscriptionRecord> _history = [];
  bool _isLoaded = false;

  /// Singleton instance
  static final TranscriptionHistoryService _instance = TranscriptionHistoryService._internal();
  factory TranscriptionHistoryService() => _instance;
  TranscriptionHistoryService._internal();

  /// Load history from storage
  Future<void> load() async {
    if (_isLoaded) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_storageKey);

      if (jsonString != null) {
        final List<dynamic> jsonList = json.decode(jsonString);
        _history = jsonList
            .map((item) => TranscriptionRecord.fromJson(item as Map<String, dynamic>))
            .toList();
        debugPrint('[TranscriptionHistory] Loaded ${_history.length} records');
      }
    } catch (e) {
      debugPrint('[TranscriptionHistory] Failed to load history: $e');
      _history = [];
    }

    _isLoaded = true;
  }

  /// Save history to storage
  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = _history.map((r) => r.toJson()).toList();
      await prefs.setString(_storageKey, json.encode(jsonList));
    } catch (e) {
      debugPrint('[TranscriptionHistory] Failed to save history: $e');
    }
  }

  /// Record a completed transcription
  Future<void> recordTranscription({
    required int audioDurationMs,
    required int transcriptionTimeMs,
  }) async {
    await load();

    // Calculate speed ratio (audio duration / transcription time)
    // Higher = faster transcription
    final speedRatio = audioDurationMs / transcriptionTimeMs;

    final record = TranscriptionRecord(
      audioDurationMs: audioDurationMs,
      transcriptionTimeMs: transcriptionTimeMs,
      speedRatio: speedRatio,
      timestamp: DateTime.now(),
    );

    _history.add(record);

    // Trim to max size (keep most recent)
    if (_history.length > _maxHistorySize) {
      _history = _history.sublist(_history.length - _maxHistorySize);
    }

    await _save();

    debugPrint(
      '[TranscriptionHistory] Recorded: ${audioDurationMs}ms audio → ${transcriptionTimeMs}ms '
      '(${speedRatio.toStringAsFixed(1)}x real-time)',
    );
  }

  /// Get estimated transcription time for given audio duration
  ///
  /// Uses median speed ratio from history for robust estimation.
  /// Falls back to default if no history available.
  Future<Duration> estimateTranscriptionTime(int audioDurationMs) async {
    await load();

    final speedRatio = getMedianSpeedRatio();
    final estimatedMs = (audioDurationMs / speedRatio).round();

    return Duration(milliseconds: estimatedMs);
  }

  /// Get the median speed ratio from history
  ///
  /// Median is more robust to outliers than mean.
  double getMedianSpeedRatio() {
    if (_history.isEmpty) {
      return _defaultSpeedRatio;
    }

    // Sort by speed ratio
    final ratios = _history.map((r) => r.speedRatio).toList()..sort();

    final middle = ratios.length ~/ 2;

    if (ratios.length % 2 == 0) {
      // Even number of elements - average the two middle values
      return (ratios[middle - 1] + ratios[middle]) / 2;
    } else {
      // Odd number - take the middle value
      return ratios[middle];
    }
  }

  /// Get statistics about transcription performance
  TranscriptionStats getStats() {
    if (_history.isEmpty) {
      return TranscriptionStats(
        recordCount: 0,
        medianSpeedRatio: _defaultSpeedRatio,
        minSpeedRatio: _defaultSpeedRatio,
        maxSpeedRatio: _defaultSpeedRatio,
        meanSpeedRatio: _defaultSpeedRatio,
      );
    }

    final ratios = _history.map((r) => r.speedRatio).toList()..sort();
    final sum = ratios.reduce((a, b) => a + b);

    return TranscriptionStats(
      recordCount: _history.length,
      medianSpeedRatio: getMedianSpeedRatio(),
      minSpeedRatio: ratios.first,
      maxSpeedRatio: ratios.last,
      meanSpeedRatio: sum / ratios.length,
    );
  }

  /// Clear all history (for testing/debugging)
  Future<void> clear() async {
    _history = [];
    await _save();
    debugPrint('[TranscriptionHistory] History cleared');
  }
}

/// A single transcription record
class TranscriptionRecord {
  final int audioDurationMs;
  final int transcriptionTimeMs;
  final double speedRatio;
  final DateTime timestamp;

  TranscriptionRecord({
    required this.audioDurationMs,
    required this.transcriptionTimeMs,
    required this.speedRatio,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'audioDurationMs': audioDurationMs,
    'transcriptionTimeMs': transcriptionTimeMs,
    'speedRatio': speedRatio,
    'timestamp': timestamp.toIso8601String(),
  };

  factory TranscriptionRecord.fromJson(Map<String, dynamic> json) {
    return TranscriptionRecord(
      audioDurationMs: json['audioDurationMs'] as int,
      transcriptionTimeMs: json['transcriptionTimeMs'] as int,
      speedRatio: (json['speedRatio'] as num).toDouble(),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }
}

/// Statistics about transcription performance
class TranscriptionStats {
  final int recordCount;
  final double medianSpeedRatio;
  final double minSpeedRatio;
  final double maxSpeedRatio;
  final double meanSpeedRatio;

  TranscriptionStats({
    required this.recordCount,
    required this.medianSpeedRatio,
    required this.minSpeedRatio,
    required this.maxSpeedRatio,
    required this.meanSpeedRatio,
  });

  @override
  String toString() =>
    'TranscriptionStats(count: $recordCount, median: ${medianSpeedRatio.toStringAsFixed(1)}x, '
    'range: ${minSpeedRatio.toStringAsFixed(1)}x - ${maxSpeedRatio.toStringAsFixed(1)}x)';
}
