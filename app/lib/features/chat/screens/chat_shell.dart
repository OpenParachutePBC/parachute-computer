import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/chat_layout_provider.dart';
import '../widgets/session_list_panel.dart';
import '../widgets/chat_content_panel.dart';

/// Adaptive shell for the chat feature.
///
/// Uses LayoutBuilder to pick the right layout:
/// - **Mobile** (<600px): Just SessionListPanel; tapping a session pushes ChatScreen.
/// - **Panel** (>=600px): Two-column — session list + chat content side by side.
///
/// Workspace switching is handled by the WorkspaceContextBar inside
/// SessionListPanel, which works identically on every screen size.
class ChatShell extends ConsumerWidget {
  const ChatShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mode = ChatLayoutBreakpoints.fromWidth(constraints.maxWidth);

        // Update the layout mode provider only when the mode actually changes
        // to avoid redundant invalidations and rebuild cascades on resize
        final currentMode = ref.read(chatLayoutModeProvider);
        if (currentMode != mode) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(chatLayoutModeProvider.notifier).state = mode;
          });
        }

        switch (mode) {
          case ChatLayoutMode.mobile:
            return const _MobileLayout();
          case ChatLayoutMode.panel:
            return const _PanelLayout();
        }
      },
    );
  }
}

/// Mobile: session list only; navigation handled by SessionListPanel push.
class _MobileLayout extends StatelessWidget {
  const _MobileLayout();

  @override
  Widget build(BuildContext context) {
    return const SessionListPanel();
  }
}

/// Panel: two-column layout — session list (narrow) + chat content (expanded).
///
/// Serves both tablet and desktop widths. The workspace context bar inside
/// SessionListPanel handles container switching on all screen sizes.
class _PanelLayout extends StatelessWidget {
  const _PanelLayout();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return LayoutBuilder(
      builder: (context, constraints) {
        // At 600px, 300px session list leaves only 300px for chat.
        // Cap at 40% of width (max 300px) to ensure chat gets enough space.
        final listWidth = constraints.maxWidth * 0.4 < 300
            ? constraints.maxWidth * 0.4
            : 300.0;

        return Row(
          children: [
            SizedBox(
              width: listWidth,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(
                      color: isDark
                          ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                          : BrandColors.stone.withValues(alpha: 0.2),
                    ),
                  ),
                ),
                child: const SessionListPanel(),
              ),
            ),
            const Expanded(child: ChatContentPanel()),
          ],
        );
      },
    );
  }
}
