import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Status of a transcription job
enum TranscriptionJobStatus {
  processing,
  complete,
  failed,
}

/// A single transcription job tracked on disk
class TranscriptionJob {
  final String entryId;
  final String audioPath;
  final TranscriptionJobStatus status;
  final DateTime createdAt;

  const TranscriptionJob({
    required this.entryId,
    required this.audioPath,
    required this.status,
    required this.createdAt,
  });

  TranscriptionJob copyWith({TranscriptionJobStatus? status}) {
    return TranscriptionJob(
      entryId: entryId,
      audioPath: audioPath,
      status: status ?? this.status,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'entryId': entryId,
    'audioPath': audioPath,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
  };

  factory TranscriptionJob.fromJson(Map<String, dynamic> json) {
    return TranscriptionJob(
      entryId: json['entryId'] as String,
      audioPath: json['audioPath'] as String,
      status: TranscriptionJobStatus.values.byName(json['status'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

/// Minimal JSON persistence for transcription jobs
///
/// Tracks which entries have pending transcription so we can restart
/// after app kill / crash. Each job is a single JSON file at:
///   {appDocDir}/parachute/transcription-jobs/{entryId}.json
///
/// Deliberately simple for v1: no chunk-level tracking. If interrupted,
/// restart transcription from scratch.
class TranscriptionProgressTracker {
  Directory? _jobsDir;

  /// Get (and create if needed) the jobs directory
  Future<Directory> get _directory async {
    if (_jobsDir != null) return _jobsDir!;

    final appDir = await getApplicationDocumentsDirectory();
    _jobsDir = Directory('${appDir.path}/parachute/transcription-jobs');
    if (!await _jobsDir!.exists()) {
      await _jobsDir!.create(recursive: true);
    }
    return _jobsDir!;
  }

  /// Create a new job when transcription starts
  Future<void> createJob({
    required String entryId,
    required String audioPath,
  }) async {
    final job = TranscriptionJob(
      entryId: entryId,
      audioPath: audioPath,
      status: TranscriptionJobStatus.processing,
      createdAt: DateTime.now(),
    );

    await _writeJob(job);
    debugPrint('[TranscriptionTracker] Created job for entry $entryId');
  }

  /// Mark a job as complete and remove it
  Future<void> completeJob(String entryId) async {
    await _deleteJob(entryId);
    debugPrint('[TranscriptionTracker] Completed and removed job for $entryId');
  }

  /// Mark a job as failed (keeps the file for retry)
  Future<void> failJob(String entryId) async {
    final job = await getJob(entryId);
    if (job != null) {
      await _writeJob(job.copyWith(status: TranscriptionJobStatus.failed));
      debugPrint('[TranscriptionTracker] Marked job $entryId as failed');
    }
  }

  /// Get a specific job
  Future<TranscriptionJob?> getJob(String entryId) async {
    final dir = await _directory;
    final file = File('${dir.path}/$entryId.json');

    if (!await file.exists()) return null;

    try {
      final json = jsonDecode(await file.readAsString());
      return TranscriptionJob.fromJson(json as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[TranscriptionTracker] Failed to read job $entryId: $e');
      return null;
    }
  }

  /// Get all incomplete jobs (processing or failed)
  ///
  /// Called on app startup to detect interrupted transcriptions.
  Future<List<TranscriptionJob>> getIncompleteJobs() async {
    final dir = await _directory;

    if (!await dir.exists()) return [];

    final jobs = <TranscriptionJob>[];

    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final json = jsonDecode(await entity.readAsString());
          final job = TranscriptionJob.fromJson(json as Map<String, dynamic>);
          if (job.status != TranscriptionJobStatus.complete) {
            jobs.add(job);
          }
        } catch (e) {
          debugPrint('[TranscriptionTracker] Skipping corrupt job file: ${entity.path}');
        }
      }
    }

    debugPrint('[TranscriptionTracker] Found ${jobs.length} incomplete jobs');
    return jobs;
  }

  /// Write a job to disk
  Future<void> _writeJob(TranscriptionJob job) async {
    final dir = await _directory;
    final file = File('${dir.path}/${job.entryId}.json');
    await file.writeAsString(jsonEncode(job.toJson()));
  }

  /// Delete a job file
  Future<void> _deleteJob(String entryId) async {
    final dir = await _directory;
    final file = File('${dir.path}/$entryId.json');
    if (await file.exists()) {
      await file.delete();
    }
  }
}
