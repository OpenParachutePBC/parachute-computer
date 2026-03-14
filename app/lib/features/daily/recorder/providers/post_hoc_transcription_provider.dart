import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/daily/journal/providers/journal_providers.dart';
import 'package:parachute/features/daily/journal/providers/journal_screen_state_provider.dart';
import 'package:parachute/features/daily/recorder/providers/service_providers.dart';
import '../services/post_hoc_transcription_service.dart';
import '../services/transcription_progress_tracker.dart';

/// State for a single post-hoc transcription job
class PostHocTranscriptionJobState {
  final String entryId;
  final String audioPath;
  final double progress; // 0.0 - 1.0
  final String status;
  final bool isComplete;
  final bool isFailed;
  final String? error;

  const PostHocTranscriptionJobState({
    required this.entryId,
    required this.audioPath,
    this.progress = 0.0,
    this.status = 'Waiting...',
    this.isComplete = false,
    this.isFailed = false,
    this.error,
  });
}

/// State for the post-hoc transcription system
class PostHocTranscriptionState {
  /// Currently active job (null if idle)
  final PostHocTranscriptionJobState? activeJob;

  /// Queue of pending jobs (entry IDs waiting to be processed)
  final List<({String entryId, String audioPath, int durationSeconds})> queue;

  const PostHocTranscriptionState({
    this.activeJob,
    this.queue = const [],
  });

  bool get isProcessing => activeJob != null && !activeJob!.isComplete && !activeJob!.isFailed;
}

/// Orchestrates post-hoc transcription lifecycle
///
/// Responsibilities:
/// - Manages transcription queue (sequential, one at a time)
/// - Tracks jobs via TranscriptionProgressTracker (crash recovery)
/// - Updates entries via DailyApiService when transcription completes
/// - Updates JournalScreenState for UI progress indicators
/// - Restarts incomplete jobs on app startup
class PostHocTranscriptionNotifier extends StateNotifier<PostHocTranscriptionState> {
  final Ref _ref;
  final TranscriptionProgressTracker _tracker = TranscriptionProgressTracker();
  PostHocTranscriptionService? _service;
  StreamSubscription<PostHocProgress>? _progressSubscription;
  bool _isProcessingQueue = false;

  PostHocTranscriptionNotifier(this._ref) : super(const PostHocTranscriptionState());

  /// Enqueue a transcription job
  ///
  /// Called after recording stops. The entry should already be created
  /// with empty content in "processing" state.
  Future<void> enqueue({
    required String entryId,
    required String audioPath,
    required int durationSeconds,
  }) async {
    debugPrint('[PostHocTranscription] Enqueuing job for entry $entryId');

    // Persist the job for crash recovery
    await _tracker.createJob(entryId: entryId, audioPath: audioPath);

    // Add to in-memory queue
    state = PostHocTranscriptionState(
      activeJob: state.activeJob,
      queue: [
        ...state.queue,
        (entryId: entryId, audioPath: audioPath, durationSeconds: durationSeconds),
      ],
    );

    // Update UI state
    _ref.read(journalScreenStateProvider.notifier).startTranscription(entryId);

    // Process queue if not already running
    _processQueue();
  }

  /// Retry a failed transcription
  Future<void> retry(String entryId, String audioPath, int durationSeconds) async {
    debugPrint('[PostHocTranscription] Retrying job for entry $entryId');

    // Transition server status back to processing
    try {
      final api = _ref.read(dailyApiServiceProvider);
      await api.updateEntry(
        entryId,
        metadata: {'transcription_status': 'processing'},
      );
    } catch (e) {
      debugPrint('[PostHocTranscription] Failed to update server status for retry: $e');
    }

    await enqueue(
      entryId: entryId,
      audioPath: audioPath,
      durationSeconds: durationSeconds,
    );
  }

  /// Check for incomplete jobs on app startup and restart them
  Future<void> restartIncompleteJobs() async {
    final incompleteJobs = await _tracker.getIncompleteJobs();

    if (incompleteJobs.isEmpty) {
      debugPrint('[PostHocTranscription] No incomplete jobs to restart');
      return;
    }

    debugPrint('[PostHocTranscription] Restarting ${incompleteJobs.length} incomplete jobs');

    for (final job in incompleteJobs) {
      // Verify the audio file still exists
      final audioFile = File(job.audioPath);
      if (!await audioFile.exists()) {
        debugPrint('[PostHocTranscription] Audio file missing for ${job.entryId}, marking failed');
        await _tracker.failJob(job.entryId);

        // Update server status so entry shows as failed (retryable if audio reappears)
        try {
          final api = _ref.read(dailyApiServiceProvider);
          await api.updateEntry(
            job.entryId,
            metadata: {'transcription_status': 'failed'},
          );
        } catch (e) {
          debugPrint('[PostHocTranscription] Failed to update server status: $e');
        }
        continue;
      }

      // Re-enqueue (estimate duration from file size: 16kHz mono = 32000 bytes/sec)
      final fileSize = await audioFile.length();
      final estimatedDuration = ((fileSize - 44) / 32000).round().clamp(1, 999999);

      await enqueue(
        entryId: job.entryId,
        audioPath: job.audioPath,
        durationSeconds: estimatedDuration,
      );
    }
  }

  /// Process the transcription queue (sequential, one at a time)
  Future<void> _processQueue() async {
    if (_isProcessingQueue) return;
    _isProcessingQueue = true;

    try {
      while (state.queue.isNotEmpty) {
        final job = state.queue.first;

        // Remove from queue, set as active
        state = PostHocTranscriptionState(
          activeJob: PostHocTranscriptionJobState(
            entryId: job.entryId,
            audioPath: job.audioPath,
          ),
          queue: state.queue.sublist(1),
        );

        await _processJob(job.entryId, job.audioPath, job.durationSeconds);
      }
    } finally {
      _isProcessingQueue = false;
    }
  }

  /// Process a single transcription job
  Future<void> _processJob(String entryId, String audioPath, int durationSeconds) async {
    debugPrint('[PostHocTranscription] Processing job for $entryId');

    try {
      // Create/get the transcription service
      final transcriptionAdapter = _ref.read(transcriptionServiceAdapterProvider);
      _service = PostHocTranscriptionService(
        transcriptionService: transcriptionAdapter,
      );

      // Listen to progress
      _progressSubscription?.cancel();
      _progressSubscription = _service!.progressStream.listen((progress) {
        switch (progress) {
          case PostHocInProgress(:final progress, :final status):
            state = PostHocTranscriptionState(
              activeJob: PostHocTranscriptionJobState(
                entryId: entryId,
                audioPath: audioPath,
                progress: progress,
                status: status,
              ),
              queue: state.queue,
            );
            // Update UI
            _ref.read(journalScreenStateProvider.notifier)
                .updateTranscriptionProgress(entryId, progress);

          case PostHocComplete():
          case PostHocFailed():
          case PostHocIdle():
            break; // Handled below
        }
      });

      // Run transcription
      final transcript = await _service!.transcribe(audioPath);

      // Update the entry with the transcript + status via API
      debugPrint('[PostHocTranscription] Updating entry $entryId with transcript (${transcript.length} chars)');
      final api = _ref.read(dailyApiServiceProvider);
      await api.updateEntry(
        entryId,
        content: transcript,
        metadata: {'transcription_status': 'complete'},
      );

      // Mark job complete
      await _tracker.completeJob(entryId);

      // Update UI state
      _ref.read(journalScreenStateProvider.notifier).completeTranscription(entryId);

      // Invalidate journal to show updated entry
      _ref.invalidate(selectedJournalProvider);

      state = PostHocTranscriptionState(
        activeJob: PostHocTranscriptionJobState(
          entryId: entryId,
          audioPath: audioPath,
          progress: 1.0,
          status: 'Complete!',
          isComplete: true,
        ),
        queue: state.queue,
      );

      debugPrint('[PostHocTranscription] ✅ Job complete for $entryId');

    } catch (e) {
      debugPrint('[PostHocTranscription] ❌ Job failed for $entryId: $e');

      // Mark job as failed (keeps the file for retry)
      await _tracker.failJob(entryId);

      // Update server-side status
      try {
        final api = _ref.read(dailyApiServiceProvider);
        await api.updateEntry(
          entryId,
          metadata: {'transcription_status': 'failed'},
        );
      } catch (apiError) {
        debugPrint('[PostHocTranscription] Failed to update server status: $apiError');
      }

      // Update UI state
      _ref.read(journalScreenStateProvider.notifier).completeTranscription(entryId);

      state = PostHocTranscriptionState(
        activeJob: PostHocTranscriptionJobState(
          entryId: entryId,
          audioPath: audioPath,
          isFailed: true,
          error: e.toString(),
          status: 'Failed',
        ),
        queue: state.queue,
      );
    } finally {
      _progressSubscription?.cancel();
      _progressSubscription = null;
      _service?.dispose();
      _service = null;
    }
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _service?.dispose();
    super.dispose();
  }
}

/// Provider for post-hoc transcription orchestration
///
/// keepAlive: survives navigation (transcription continues in background)
final postHocTranscriptionProvider =
    StateNotifierProvider<PostHocTranscriptionNotifier, PostHocTranscriptionState>((ref) {
  final notifier = PostHocTranscriptionNotifier(ref);

  // On creation, check for incomplete jobs from previous session
  Future.microtask(() => notifier.restartIncompleteJobs());

  // Keep alive so transcription continues during navigation
  ref.keepAlive();

  return notifier;
});
