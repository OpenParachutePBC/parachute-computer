/// Display formatting utilities for chat messages.
///
/// These are presentation-layer transformations separate from the
/// data model in [SessionTranscript].
class ChatDisplayFormatter {
  ChatDisplayFormatter._();

  /// Extracts the user-visible command display text from a Claude Code
  /// skill-injected human message.
  ///
  /// Skill injection wraps the command like:
  /// `<command-name>commit</command-name><command-args>...</command-args>`
  /// or falls back to the raw text if the tags are absent.
  static String extractCommandDisplay(String text) {
    // Extract user's actual args (their typed input)
    final argsMatch = RegExp(
      r'<command-args>([\s\S]*?)</command-args>',
      multiLine: true,
    ).firstMatch(text);
    if (argsMatch != null) {
      final args = argsMatch.group(1)?.trim() ?? '';
      // Strip leading '#' that the skill command wrapper sometimes adds
      final cleaned = args.startsWith('#') ? args.substring(1).trim() : args;
      if (cleaned.isNotEmpty) return cleaned;
    }

    // Fall back to command name
    final cmdMatch = RegExp(r'<command-name>([^<]+)</command-name>').firstMatch(text);
    if (cmdMatch != null) {
      return cmdMatch.group(1)?.trim() ?? text;
    }

    return text;
  }
}
