import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Layout modes for the chat interface.
enum ChatLayoutMode {
  /// Single column with push navigation (mobile)
  mobile,

  /// Two columns: session list + chat content (tablet and desktop)
  panel,
}

/// Breakpoints for adaptive layout.
class ChatLayoutBreakpoints {
  static const double panel = 600;

  static ChatLayoutMode fromWidth(double width) {
    return width >= panel ? ChatLayoutMode.panel : ChatLayoutMode.mobile;
  }
}

/// Current layout mode, updated by ChatShell's LayoutBuilder.
final chatLayoutModeProvider = StateProvider<ChatLayoutMode>(
  (ref) => ChatLayoutMode.mobile,
);

/// Whether the current layout uses side-by-side panels (tablet or desktop).
final isPanelModeProvider = Provider<bool>((ref) {
  final mode = ref.watch(chatLayoutModeProvider);
  return mode == ChatLayoutMode.panel;
});
