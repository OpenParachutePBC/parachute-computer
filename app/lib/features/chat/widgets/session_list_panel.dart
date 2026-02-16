import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_session.dart';
import '../providers/chat_providers.dart';
import '../services/chat_service.dart';
import '../providers/chat_layout_provider.dart';
import '../providers/session_search_provider.dart';
import '../providers/workspace_providers.dart';
import '../models/workspace.dart';
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
  bool _showSearch = false;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isPanelMode = ref.watch(isPanelModeProvider);
    final currentSessionId = ref.watch(currentSessionIdProvider);

    return Column(
      children: [
        // Header
        _buildHeader(context, isDark),
        if (_showSearch) _buildSearchBar(context, isDark),
        // Session list
        Expanded(child: _buildSessionList(context, isDark, isPanelMode, currentSessionId)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, bool isDark) {
    final layoutMode = ref.watch(chatLayoutModeProvider);
    final activeSlug = ref.watch(activeWorkspaceProvider);
    final workspacesAsync = ref.watch(workspacesProvider);

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
          // Workspace filter chip (hidden on desktop where sidebar handles this)
          if (layoutMode != ChatLayoutMode.desktop) ...[
            const SizedBox(width: Spacing.xs),
            _buildWorkspaceChip(isDark, activeSlug, workspacesAsync),
          ],
          const Spacer(),
          IconButton(
            icon: Icon(
              _showSearch ? Icons.search_off : Icons.search,
              size: 20,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
            onPressed: () {
              setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) {
                  _searchController.clear();
                  ref.read(sessionSearchQueryProvider.notifier).state = '';
                }
              });
            },
            tooltip: 'Search',
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

  Widget _buildSearchBar(BuildContext context, bool isDark) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.xs),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        decoration: InputDecoration(
          hintText: 'Search chats...',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    ref.read(sessionSearchQueryProvider.notifier).state = '';
                  },
                )
              : null,
          isDense: true,
          border: OutlineInputBorder(borderRadius: Radii.card),
          contentPadding: EdgeInsets.symmetric(vertical: Spacing.sm),
        ),
        onChanged: (value) {
          ref.read(sessionSearchQueryProvider.notifier).state = value;
        },
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

    final activeWorkspace = ref.watch(activeWorkspaceProvider);

    final AsyncValue<List<ChatSession>> sessionsAsync;
    if (_showArchived) {
      sessionsAsync = ref.watch(archivedSessionsProvider);
    } else if (searchQuery.isNotEmpty) {
      sessionsAsync = ref.watch(searchedSessionsProvider);
    } else if (activeWorkspace != null) {
      sessionsAsync = ref.watch(workspaceSessionsProvider);
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

  Widget _buildWorkspaceChip(
    bool isDark,
    String? activeSlug,
    AsyncValue<List<Workspace>> workspacesAsync,
  ) {
    final hasFilter = activeSlug != null;
    final label = workspacesAsync.whenOrNull(
      data: (workspaces) {
        if (activeSlug == null) return null;
        final ws = workspaces.where((w) => w.slug == activeSlug);
        return ws.isNotEmpty ? ws.first.name : activeSlug;
      },
    );

    return GestureDetector(
      onTap: () => _showWorkspacePicker(isDark),
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
              hasFilter ? Icons.workspaces : Icons.filter_list,
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

  void _showWorkspacePicker(bool isDark) {
    final workspacesAsync = ref.read(workspacesProvider);
    final activeSlug = ref.read(activeWorkspaceProvider);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return Container(
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
                  'Filter by Workspace',
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
                  ref.read(activeWorkspaceProvider.notifier).state = null;
                  Navigator.pop(sheetContext);
                },
              ),
              // Workspace list
              workspacesAsync.when(
                data: (workspaces) {
                  if (workspaces.isEmpty) {
                    return Padding(
                      padding: EdgeInsets.all(Spacing.lg),
                      child: Text(
                        'No workspaces configured',
                        style: TextStyle(
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: workspaces.map((ws) {
                      final isActive = ws.slug == activeSlug;
                      return ListTile(
                        leading: Icon(
                          Icons.workspaces,
                          color: isActive
                              ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                              : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
                        ),
                        title: Text(
                          ws.name,
                          style: TextStyle(
                            color: isDark ? BrandColors.nightText : BrandColors.ink,
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                        subtitle: ws.description.isNotEmpty
                            ? Text(
                                ws.description,
                                style: TextStyle(
                                  fontSize: TypographyTokens.labelSmall,
                                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : null,
                        trailing: isActive
                            ? Icon(Icons.check, color: isDark ? BrandColors.nightForest : BrandColors.forest)
                            : null,
                        onTap: () {
                          ref.read(activeWorkspaceProvider.notifier).state = ws.slug;
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
                error: (_, _) => Padding(
                  padding: EdgeInsets.all(Spacing.lg),
                  child: Text(
                    'Failed to load workspaces',
                    style: TextStyle(color: BrandColors.error),
                  ),
                ),
              ),
              SizedBox(height: Spacing.md),
            ],
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
