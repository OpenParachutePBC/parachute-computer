import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_session.dart';
import '../providers/chat_providers.dart';
import '../providers/chat_layout_provider.dart';
import '../providers/session_search_provider.dart';
import '../providers/workspace_providers.dart';
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
