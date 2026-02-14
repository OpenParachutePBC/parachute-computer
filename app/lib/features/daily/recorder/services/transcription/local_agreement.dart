import 'dart:math';

/// LocalAgreement-2 algorithm for streaming transcription stability
///
/// Based on whisper_streaming's LocalAgreement-2 algorithm:
/// 1. Maintain a rolling audio buffer (15-30 seconds)
/// 2. Periodically transcribe the buffer
/// 3. Compare consecutive transcriptions to find stable text
/// 4. Only "confirm" text that has been stable across 2 iterations
/// 5. Display: [confirmed stable text] + [current interim]
class LocalAgreementState {
  String? previousTranscription;
  String confirmedText = '';
  String tentativeText = '';
  String interimText = '';

  /// Apply LocalAgreement-2 algorithm to update confirmed/tentative/interim text
  ///
  /// Returns true if state was updated.
  bool apply(String currentTranscription) {
    if (previousTranscription == null) {
      // First transcription - everything is interim (may change)
      confirmedText = '';
      tentativeText = '';
      interimText = currentTranscription;
      previousTranscription = currentTranscription;
      return true;
    }

    // Find longest common prefix between previous and current transcription
    final commonPrefix = _longestCommonWordPrefix(previousTranscription!, currentTranscription);

    // The common prefix is stable (appeared in both transcriptions)
    confirmedText = '';  // We don't accumulate - buffer already has full audio
    tentativeText = commonPrefix;  // Stable across 2 iterations

    if (commonPrefix.length < currentTranscription.length) {
      interimText = currentTranscription.substring(commonPrefix.length).trim();
    } else {
      interimText = '';
    }

    previousTranscription = currentTranscription;
    return true;
  }

  /// Reset state for new recording
  void reset() {
    previousTranscription = null;
    confirmedText = '';
    tentativeText = '';
    interimText = '';
  }

  /// Get display text combining all parts
  String get displayText {
    return '$confirmedText $tentativeText $interimText'.trim();
  }

  /// Find the longest common prefix between two strings, word-by-word
  String _longestCommonWordPrefix(String a, String b) {
    final wordsA = a.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final wordsB = b.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

    int matchLen = 0;
    for (int i = 0; i < min(wordsA.length, wordsB.length); i++) {
      if (_wordsMatchFuzzy(wordsA[i], wordsB[i])) {
        matchLen = i + 1;
      } else {
        break;
      }
    }

    return wordsA.take(matchLen).join(' ');
  }

  /// Check if two words match (case-insensitive, ignoring punctuation)
  bool _wordsMatchFuzzy(String a, String b) {
    String normalize(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w]'), '');

    final normA = normalize(a);
    final normB = normalize(b);

    if (normA == normB) return true;

    // Allow small differences (Levenshtein distance <= 1)
    if (normA.length > 2 && normB.length > 2) {
      return _levenshteinDistance(normA, normB) <= 1;
    }

    return false;
  }

  /// Simple Levenshtein distance for fuzzy word matching
  int _levenshteinDistance(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    List<int> prev = List.generate(b.length + 1, (i) => i);
    List<int> curr = List.filled(b.length + 1, 0);

    for (int i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (int j = 1; j <= b.length; j++) {
        int cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = min(min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      final temp = prev;
      prev = curr;
      curr = temp;
    }

    return prev[b.length];
  }
}

/// Manages a rolling audio buffer for streaming re-transcription
class RollingAudioBuffer {
  List<int> _buffer = [];
  static const int maxSamples = 16000 * 30; // 30 seconds max

  List<int> get samples => _buffer;
  int get length => _buffer.length;
  bool get isEmpty => _buffer.isEmpty;
  double get durationSeconds => _buffer.length / 16000;

  /// Add samples to the buffer, trimming if needed
  void addSamples(List<int> samples) {
    _buffer.addAll(samples);

    // Trim to max size (keep last 30s)
    if (_buffer.length > maxSamples) {
      _buffer = _buffer.sublist(_buffer.length - maxSamples);
    }
  }

  /// Get a copy of the buffer for transcription
  List<int> getBufferCopy() {
    return List<int>.from(_buffer);
  }

  /// Clear the buffer
  void clear() {
    _buffer = [];
  }
}
