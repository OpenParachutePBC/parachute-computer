import 'package:parachute/core/services/file_system_service.dart';

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

  /// Get full path for an audio file from relative path
  static Future<String> getFullAudioPath(String relativePath) async {
    final fileSystem = FileSystemService.daily();
    final vaultPath = await fileSystem.getRootPath();
    return '$vaultPath/$relativePath';
  }

  /// Get full path for an image file from relative path
  static Future<String> getFullImagePath(String relativePath) async {
    final fileSystem = FileSystemService.daily();
    final vaultPath = await fileSystem.getRootPath();
    return '$vaultPath/$relativePath';
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
