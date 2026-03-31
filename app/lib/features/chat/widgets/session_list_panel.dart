import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_session.dart';
import '../providers/chat_providers.dart';
import '../services/chat_service.dart';
import '../providers/chat_layout_provider.dart';
import '../providers/session_search_provider.dart';
import '../providers/container_providers.dart';
import '../widgets/session_config_sheet.dart';
import '../widgets/session_list_item.dart';
import '../widgets/workspace_context_bar.dart';
import '../screens/chat_screen.dart';

/// Composable session list panel for use in adaptive layouts.
///
/// In panel mode (tablet/desktop): selecting a session updates the provider
/// without navigation. In mobile mode: pushes ChatScreen.
class SessionListPanel extends ConsumerStatefulWidget {
  const SessionListPanel({super.key});

  @override
  ConsumerState<SessionListPanel> createState() => _SessionListPanelState();
}

class _SessionListPanelState extends ConsumerState<SessionListPanel> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isPanelMode = ref.watch(isPanelModeProvider);
    final currentSessionId = ref.watch(currentSessionIdProvider);

    return Column(
      children: [
        // Workspace context bar (replaces old header + filter chip)
        WorkspaceContextBar(
          onNewChat: _startNewChat,
          onToggleArchive: () => setState(() => _showArchived = !_showArchived),
          showArchived: _showArchived,
        ),
        // Session list
        Expanded(child: _buildSessionList(context, isDark, isPanelMode, currentSessionId)),
      ],
    );
  }

  Widget _buildSessionList(
    BuildContext context,
    bool isDark,
    bool isPanelMode,
    String? currentSessionId,
  ) {
    final searchQuery = ref.watch(sessionSearchQueryProvider);

    final activeContainer = ref.watch(activeContainerProvider).valueOrNull;

    final AsyncValue<List<ChatSession>> sessionsAsync;
    if (_showArchived) {
      sessionsAsync = ref.watch(archivedSessionsProvider);
    } else if (searchQuery.isNotEmpty) {
      sessionsAsync = ref.watch(searchedSessionsProvider);
    } else if (activeContainer != null) {
      sessionsAsync = ref.watch(containerSessionsProvider);
    } else {
      sessionsAsync = ref.watch(chatSessionsProvider);
    }

    return sessionsAsync.when(
      data: (sessions) {
        if (sessions.isEmpty) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(Spacing.xl),
              child: Text(
                _showArchived ? 'No archived chats' : 'No chats yet',
                style: TextStyle(
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                ),
              ),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(chatSessionsProvider);
            ref.invalidate(archivedSessionsProvider);
            ref.invalidate(containerSessionsProvider);
            ref.invalidate(containerSessionCountsProvider);
            ref.invalidate(containersProvider);
            ref.invalidate(allContainersProvider);
          },
          child: ListView.builder(
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              final isSelected = isPanelMode && session.id == currentSessionId;
              return Container(
                color: isSelected
                    ? (isDark
                        ? BrandColors.nightForest.withValues(alpha: 0.15)
                        : BrandColors.forest.withValues(alpha: 0.08))
                    : null,
                child: SessionListItem(
                  session: session,
                  onTap: () => _selectSession(session, isPanelMode),
                  onApprove: session.isPendingApproval && session.pairingRequestId != null
                    ? () => _approvePairing(session)
                    : null,
                  onDeny: session.isPendingApproval && session.pairingRequestId != null
                    ? () => _denyPairing(session)
                    : null,
                ),
              );
            },
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Text('Error: $error'),
      ),
    );
  }

  Future<void> _approvePairing(ChatSession session) async {
    try {
      final service = ref.read(chatServiceProvider);
      await service.approvePairing(session.pairingRequestId!);
      ref.invalidate(chatSessionsProvider);
      ref.invalidate(pendingPairingCountProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to approve: $e')),
        );
      }
    }
  }

  Future<void> _denyPairing(ChatSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deny this user?'),
        content: const Text(
          'They will be notified and the session will be archived.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: BrandColors.error),
            child: const Text('Deny'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final service = ref.read(chatServiceProvider);
      await service.denyPairing(session.pairingRequestId!);
      ref.invalidate(chatSessionsProvider);
      ref.invalidate(pendingPairingCountProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to deny: $e')),
        );
      }
    }
  }

  Future<void> _selectSession(ChatSession session, bool isPanelMode) async {
    // Pending approval — use inline buttons, don't navigate into chat
    if (session.isPendingApproval) return;

    // Pending initialization sessions show the config sheet for activation
    if (session.isPendingInitialization) {
      SessionConfigSheet.show(context, session).then((saved) {
        if (saved == true) {
          ref.invalidate(chatSessionsProvider);
        }
      });
      return;
    }

    await ref.read(switchSessionProvider)(session.id);

    if (!mounted) return;
    if (!isPanelMode) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const ChatScreen()),
      );
    }
  }

  void _startNewChat() {
    final isPanelMode = ref.read(isPanelModeProvider);
    ref.read(newChatProvider)();

    if (!isPanelMode) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const ChatScreen()),
      );
    }
  }
}
