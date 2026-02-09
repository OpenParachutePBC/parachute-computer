import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Layout modes for the chat interface.
enum ChatLayoutMode {
  /// Single column with push navigation (mobile)
  mobile,

  /// Two columns: session list + chat content (tablet)
  tablet,

  /// Three columns: sidebar + session list + chat content (desktop)
  desktop,
}

/// Breakpoints for adaptive layout.
class ChatLayoutBreakpoints {
  static const double tablet = 600;
  static const double desktop = 1200;

  static ChatLayoutMode fromWidth(double width) {
    if (width >= desktop) return ChatLayoutMode.desktop;
    if (width >= tablet) return ChatLayoutMode.tablet;
    return ChatLayoutMode.mobile;
  }
}

/// Current layout mode, updated by ChatShell's LayoutBuilder.
final chatLayoutModeProvider = StateProvider<ChatLayoutMode>(
  (ref) => ChatLayoutMode.mobile,
);

/// Whether the current layout uses side-by-side panels (tablet or desktop).
final isPanelModeProvider = Provider<bool>((ref) {
  final mode = ref.watch(chatLayoutModeProvider);
  return mode != ChatLayoutMode.mobile;
});
