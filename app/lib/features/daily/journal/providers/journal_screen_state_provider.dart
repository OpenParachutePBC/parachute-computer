import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// State for journal screen progress tracking
@immutable
class JournalScreenState {
  /// Entries that are actively transcribing
  final Set<String> transcribingEntryIds;

  /// Transcription progress per entry (0.0-1.0)
  final Map<String, double> transcriptionProgress;

  /// Entries that are being AI-enhanced
  final Set<String> enhancingEntryIds;

  /// Enhancement progress per entry (0.0-1.0, null for indeterminate)
  final Map<String, double?> enhancementProgress;

  /// Enhancement status message per entry
  final Map<String, String> enhancementStatus;

  /// Entry pending transcription (for streaming audio)
  final String? pendingTranscriptionEntryId;

  const JournalScreenState({
    this.transcribingEntryIds = const {},
    this.transcriptionProgress = const {},
    this.enhancingEntryIds = const {},
    this.enhancementProgress = const {},
    this.enhancementStatus = const {},
    this.pendingTranscriptionEntryId,
  });

  JournalScreenState copyWith({
    Set<String>? transcribingEntryIds,
    Map<String, double>? transcriptionProgress,
    Set<String>? enhancingEntryIds,
    Map<String, double?>? enhancementProgress,
    Map<String, String>? enhancementStatus,
    String? pendingTranscriptionEntryId,
    bool clearPendingTranscription = false,
  }) {
    return JournalScreenState(
      transcribingEntryIds: transcribingEntryIds ?? this.transcribingEntryIds,
      transcriptionProgress: transcriptionProgress ?? this.transcriptionProgress,
      enhancingEntryIds: enhancingEntryIds ?? this.enhancingEntryIds,
      enhancementProgress: enhancementProgress ?? this.enhancementProgress,
      enhancementStatus: enhancementStatus ?? this.enhancementStatus,
      pendingTranscriptionEntryId: clearPendingTranscription
          ? null
          : (pendingTranscriptionEntryId ?? this.pendingTranscriptionEntryId),
    );
  }
}

/// Notifier for managing journal screen state
class JournalScreenStateNotifier extends StateNotifier<JournalScreenState> {
  JournalScreenStateNotifier() : super(const JournalScreenState());

  Timer? _progressDebounceTimer;
  final Map<String, double> _pendingProgress = {};

  @override
  void dispose() {
    _progressDebounceTimer?.cancel();
    super.dispose();
  }

  /// Set pending transcription entry ID
  void setPendingTranscription(String? entryId) {
    state = state.copyWith(
      pendingTranscriptionEntryId: entryId,
      clearPendingTranscription: entryId == null,
    );
  }

  /// Start transcription for an entry
  void startTranscription(String entryId) {
    final newTranscribing = Set<String>.from(state.transcribingEntryIds)..add(entryId);
    final newProgress = Map<String, double>.from(state.transcriptionProgress)..[entryId] = 0.0;

    state = state.copyWith(
      transcribingEntryIds: newTranscribing,
      transcriptionProgress: newProgress,
    );
  }

  /// Update transcription progress with debouncing to avoid excessive rebuilds
  void updateTranscriptionProgress(String entryId, double progress) {
    _pendingProgress[entryId] = progress;

    // Debounce to max 5 updates per second (200ms)
    _progressDebounceTimer ??= Timer(const Duration(milliseconds: 200), () {
      _progressDebounceTimer = null;
      if (_pendingProgress.isNotEmpty) {
        final newProgress = Map<String, double>.from(state.transcriptionProgress)
          ..addAll(_pendingProgress);
        _pendingProgress.clear();

        state = state.copyWith(transcriptionProgress: newProgress);
      }
    });
  }

  /// Complete transcription for an entry
  void completeTranscription(String entryId) {
    final newTranscribing = Set<String>.from(state.transcribingEntryIds)..remove(entryId);
    final newProgress = Map<String, double>.from(state.transcriptionProgress)..remove(entryId);

    state = state.copyWith(
      transcribingEntryIds: newTranscribing,
      transcriptionProgress: newProgress,
    );
  }

  /// Start enhancement for an entry
  void startEnhancement(String entryId) {
    final newEnhancing = Set<String>.from(state.enhancingEntryIds)..add(entryId);

    state = state.copyWith(enhancingEntryIds: newEnhancing);
  }

  /// Update enhancement progress
  void updateEnhancementProgress(String entryId, {double? progress, String? status}) {
    final newProgress = progress != null
        ? (Map<String, double?>.from(state.enhancementProgress)..[entryId] = progress)
        : state.enhancementProgress;

    final newStatus = status != null
        ? (Map<String, String>.from(state.enhancementStatus)..[entryId] = status)
        : state.enhancementStatus;

    state = state.copyWith(
      enhancementProgress: newProgress,
      enhancementStatus: newStatus,
    );
  }

  /// Complete enhancement for an entry
  void completeEnhancement(String entryId) {
    final newEnhancing = Set<String>.from(state.enhancingEntryIds)..remove(entryId);
    final newProgress = Map<String, double?>.from(state.enhancementProgress)..remove(entryId);
    final newStatus = Map<String, String>.from(state.enhancementStatus)..remove(entryId);

    state = state.copyWith(
      enhancingEntryIds: newEnhancing,
      enhancementProgress: newProgress,
      enhancementStatus: newStatus,
    );
  }
}

/// Provider for journal screen state
final journalScreenStateProvider = StateNotifierProvider<JournalScreenStateNotifier, JournalScreenState>(
  (ref) => JournalScreenStateNotifier(),
);
