import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/settings/screens/settings_screen.dart';
import '../models/chat_session.dart';
import '../providers/chat_providers.dart';
import '../services/chat_service.dart';
import '../providers/chat_layout_provider.dart';
import '../providers/session_search_provider.dart';
import '../models/project.dart';
import '../providers/project_providers.dart';
import '../widgets/session_config_sheet.dart';
import '../widgets/session_list_item.dart';
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
        // Header
        _buildHeader(context, isDark),
        // Session list
        Expanded(child: _buildSessionList(context, isDark, isPanelMode, currentSessionId)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    final layoutMode = ref.watch(chatLayoutModeProvider);
    final activeSlug = ref.watch(activeProjectProvider).valueOrNull;
    final containerEnvsAsync = ref.watch(projectsProvider);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                : BrandColors.stone.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          Text(
            _showArchived ? 'Archived' : 'Chats',
            style: TextStyle(
              fontSize: TypographyTokens.titleMedium,
              fontWeight: FontWeight.w600,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          // Container env filter chip (hidden on desktop where sidebar handles this)
          if (layoutMode != ChatLayoutMode.desktop) ...[
            const SizedBox(width: Spacing.xs),
            _buildEnvChip(isDark, activeSlug, containerEnvsAsync),
          ],
          const Spacer(),
          IconButton(
            icon: Icon(
              Icons.settings_outlined,
              size: 20,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
            onPressed: () => Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
            tooltip: 'Settings',
          ),
          IconButton(
            icon: Icon(
              _showArchived ? Icons.inbox : Icons.archive_outlined,
              size: 20,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
            onPressed: () => setState(() => _showArchived = !_showArchived),
            tooltip: _showArchived ? 'Show active' : 'Show archived',
          ),
          IconButton(
            icon: Icon(
              Icons.add,
              size: 20,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            onPressed: _startNewChat,
            tooltip: 'New Chat',
          ),
        ],
      ),
    );
  }


  Widget _buildSessionList(
    BuildContext context,
    bool isDark,
    bool isPanelMode,
    String? currentSessionId,
  ) {
    final searchQuery = ref.watch(sessionSearchQueryProvider);

    final activeProject = ref.watch(activeProjectProvider).valueOrNull;

    final AsyncValue<List<ChatSession>> sessionsAsync;
    if (_showArchived) {
      sessionsAsync = ref.watch(archivedSessionsProvider);
    } else if (searchQuery.isNotEmpty) {
      sessionsAsync = ref.watch(searchedSessionsProvider);
    } else if (activeProject != null) {
      sessionsAsync = ref.watch(projectSessionsProvider);
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

  Widget _buildEnvChip(
    bool isDark,
    String? activeSlug,
    AsyncValue<List<Project>> containerEnvsAsync,
  ) {
    final hasFilter = activeSlug != null;
    final label = containerEnvsAsync.whenOrNull(
      data: (envs) {
        if (activeSlug == null) return null;
        final match = envs.where((e) => e.slug == activeSlug);
        return match.isNotEmpty ? match.first.displayName : activeSlug;
      },
    );

    return GestureDetector(
      onTap: () => _showEnvPicker(isDark),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xxs,
        ),
        decoration: BoxDecoration(
          color: hasFilter
              ? (isDark ? BrandColors.nightForest : BrandColors.forest).withValues(alpha: 0.15)
              : (isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone.withValues(alpha: 0.1)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasFilter ? Icons.dns_outlined : Icons.filter_list,
              size: 14,
              color: hasFilter
                  ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                  : (isDark ? BrandColors.nightTextSecondary : BrandColors.stone),
            ),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 100),
              child: Text(
                label ?? 'All',
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  fontWeight: hasFilter ? FontWeight.w600 : FontWeight.w400,
                  color: hasFilter
                      ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                      : (isDark ? BrandColors.nightTextSecondary : BrandColors.stone),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasFilter) ...[
              const SizedBox(width: 2),
              Icon(
                Icons.close,
                size: 12,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showEnvPicker(bool isDark) {
    final containerEnvsAsync = ref.read(projectsProvider);
    final activeSlug = ref.read(activeProjectProvider).valueOrNull;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.85,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: isDark ? BrandColors.nightSurface : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle
                Padding(
                  padding: EdgeInsets.only(top: Spacing.sm),
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(Spacing.md),
                  child: Text(
                    'Filter by Environment',
                    style: TextStyle(
                      fontSize: TypographyTokens.titleSmall,
                      fontWeight: FontWeight.w600,
                      color: isDark ? BrandColors.nightText : BrandColors.ink,
                    ),
                  ),
                ),
                // "All Chats" option
                ListTile(
                  leading: Icon(
                    Icons.chat_bubble_outline,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                  title: Text(
                    'All Chats',
                    style: TextStyle(
                      color: isDark ? BrandColors.nightText : BrandColors.ink,
                      fontWeight: activeSlug == null ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  trailing: activeSlug == null
                      ? Icon(Icons.check, color: isDark ? BrandColors.nightForest : BrandColors.forest)
                      : null,
                  onTap: () {
                    ref.read(activeProjectProvider.notifier).setProject(null);
                    Navigator.pop(sheetContext);
                  },
                ),
                // Scrollable env list
                Flexible(
                  child: SingleChildScrollView(
                    child: containerEnvsAsync.when(
                      data: (envs) {
                        if (envs.isEmpty) {
                          return Padding(
                            padding: EdgeInsets.all(Spacing.lg),
                            child: Text(
                              'No named environments configured',
                              style: TextStyle(
                                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                              ),
                            ),
                          );
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: envs.map((env) {
                            final isActive = env.slug == activeSlug;
                            return ListTile(
                              leading: Icon(
                                Icons.dns_outlined,
                                color: isActive
                                    ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                                    : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
                              ),
                              title: Text(
                                env.displayName,
                                style: TextStyle(
                                  color: isDark ? BrandColors.nightText : BrandColors.ink,
                                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                                ),
                              ),
                              trailing: isActive
                                  ? Icon(Icons.check, color: isDark ? BrandColors.nightForest : BrandColors.forest)
                                  : null,
                              onTap: () {
                                ref.read(activeProjectProvider.notifier).setProject(env.slug);
                                Navigator.pop(sheetContext);
                              },
                            );
                          }).toList(),
                        );
                      },
                      loading: () => Padding(
                        padding: EdgeInsets.all(Spacing.lg),
                        child: const CircularProgressIndicator(),
                      ),
                      error: (_, __) => Padding(
                        padding: EdgeInsets.all(Spacing.lg),
                        child: Text(
                          'Failed to load environments',
                          style: TextStyle(color: BrandColors.error),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(height: Spacing.md),
              ],
            ),
          ),
        );
      },
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

  void _selectSession(ChatSession session, bool isPanelMode) {
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

    ref.read(switchSessionProvider)(session.id);

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
