/// Helper functions for journal screen
class JournalHelpers {
  /// Get the relative path for a journal file for a given date
  /// Used to push specific file changes to sync
  static String journalPathForDate(DateTime date) {
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return 'journals/$dateStr.md';
  }

  /// Format time as HH:MM
  static String formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  /// Build an HTTP URL for an audio file stored on the server.
  ///
  /// For absolute server paths like `/Users/foo/.parachute/daily/assets/2026-03-03/rec.wav`,
  /// derives the relative segment and returns `$serverBaseUrl/api/daily/assets/2026-03-03/rec.wav`.
  ///
  /// For legacy relative paths (before migration), returns a best-effort URL.
  static String getAudioUrl(String audioPath, String serverBaseUrl) {
    if (audioPath.startsWith('/')) {
      // Absolute path — extract relative portion after assets directory
      const assetsMarker = '/daily/assets/';
      final idx = audioPath.indexOf(assetsMarker);
      if (idx != -1) {
        final rel = audioPath.substring(idx + assetsMarker.length);
        return '$serverBaseUrl/api/storage/$rel';
      }
    }
    // Relative path (e.g. "2026-03-27/filename.wav")
    return '$serverBaseUrl/api/storage/$audioPath';
  }

  /// Format duration in seconds to human-readable string
  static String formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    if (minutes > 0) {
      return '$minutes min ${secs > 0 ? '$secs sec' : ''}';
    }
    return '$secs sec';
  }
}
