import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/settings/screens/settings_screen.dart';
import '../models/chat_session.dart';
import '../providers/chat_providers.dart';
import '../widgets/session_list_item.dart';
import '../widgets/new_chat_sheet.dart';
import 'chat_screen.dart';
import 'claude_code_import_screen.dart';

/// Filter options for chat sessions
enum ChatFilter {
  all,
  active,
  imported,
  archived,
}

/// Chat Hub - Main entry point for AI conversations
///
/// Shows a list of recent chat sessions grouped by date,
/// with quick access to start new conversations.
class AgentHubScreen extends ConsumerStatefulWidget {
  const AgentHubScreen({super.key});

  @override
  ConsumerState<AgentHubScreen> createState() => _AgentHubScreenState();
}

class _AgentHubScreenState extends ConsumerState<AgentHubScreen> {
  ChatFilter _currentFilter = ChatFilter.active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Watch both active and archived sessions
    final activeSessionsAsync = ref.watch(chatSessionsProvider);
    final archivedSessionsAsync = ref.watch(archivedSessionsProvider);

    // Combine both lists for filtering
    final sessionsAsync = activeSessionsAsync.when(
      data: (activeSessions) => archivedSessionsAsync.when(
        data: (archivedSessions) {
          // Combine active + archived (avoiding duplicates)
          final activeIds = activeSessions.map((s) => s.id).toSet();
          final allSessions = [
            ...activeSessions,
            ...archivedSessions.where((s) => !activeIds.contains(s.id)),
          ];
          return AsyncValue.data(allSessions);
        },
        loading: () => AsyncValue.data(activeSessions), // Show active while archived loads
        error: (e, st) => AsyncValue.data(activeSessions), // Fallback to active only
      ),
      loading: () => const AsyncValue<List<ChatSession>>.loading(),
      error: (e, st) => AsyncValue<List<ChatSession>>.error(e, st),
    );

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'Chat',
          style: TextStyle(
            fontSize: TypographyTokens.titleLarge,
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        actions: [
          // Refresh button (useful for desktop where pull-to-refresh isn't natural)
          IconButton(
            onPressed: _refreshSessions,
            icon: Icon(
              Icons.refresh,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            tooltip: 'Refresh',
          ),
          // Continue from Claude Code button
          IconButton(
            onPressed: () => _continueFromClaudeCode(context),
            icon: Icon(
              Icons.terminal,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            tooltip: 'Continue Claude Code Session',
          ),
          // New chat button
          IconButton(
            onPressed: () => _startNewChat(context),
            icon: Icon(
              Icons.add_comment_outlined,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
            tooltip: 'New Chat',
          ),
          // Settings button
          IconButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsScreen()),
            ),
            icon: Icon(
              Icons.settings_outlined,
              color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
            ),
            tooltip: 'Settings',
          ),
          const SizedBox(width: Spacing.xs),
        ],
      ),
      body: Column(
        children: [
          // Filter chips
          _buildFilterChips(isDark, sessionsAsync.valueOrNull ?? []),

          // Sessions list
          Expanded(
            child: sessionsAsync.when(
              data: (sessions) => _buildSessionsList(context, sessions, isDark),
              loading: () => _buildLoading(isDark),
              error: (e, _) => _buildError(isDark, e.toString()),
            ),
          ),

          // Quick chat input at bottom
          _buildQuickChatInput(context, isDark),
        ],
      ),
    );
  }

  Widget _buildFilterChips(bool isDark, List<ChatSession> allSessions) {
    // Count sessions in each category
    final activeCount = allSessions.where((s) => !s.archived && !s.isImported).length;
    final importedCount = allSessions.where((s) => s.isImported).length;
    final archivedCount = allSessions.where((s) => s.archived).length;

    // Don't show filters if there are no imported or archived sessions
    if (importedCount == 0 && archivedCount == 0) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _buildFilterChip(
              label: 'Active',
              count: activeCount,
              isSelected: _currentFilter == ChatFilter.active,
              onTap: () => setState(() => _currentFilter = ChatFilter.active),
              isDark: isDark,
            ),
            if (importedCount > 0) ...[
              const SizedBox(width: Spacing.sm),
              _buildFilterChip(
                label: 'Imported',
                count: importedCount,
                isSelected: _currentFilter == ChatFilter.imported,
                onTap: () => setState(() => _currentFilter = ChatFilter.imported),
                isDark: isDark,
              ),
            ],
            if (archivedCount > 0) ...[
              const SizedBox(width: Spacing.sm),
              _buildFilterChip(
                label: 'Archived',
                count: archivedCount,
                isSelected: _currentFilter == ChatFilter.archived,
                onTap: () => setState(() => _currentFilter = ChatFilter.archived),
                isDark: isDark,
              ),
            ],
            const SizedBox(width: Spacing.sm),
            _buildFilterChip(
              label: 'All',
              count: allSessions.length,
              isSelected: _currentFilter == ChatFilter.all,
              onTap: () => setState(() => _currentFilter = ChatFilter.all),
              isDark: isDark,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required int count,
    required bool isSelected,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
              : (isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.stone.withValues(alpha: 0.3)),
          borderRadius: Radii.pill,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: TypographyTokens.labelMedium,
                fontWeight: FontWeight.w500,
                color: isSelected
                    ? Colors.white
                    : (isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: Spacing.xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.xs + 2,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.2)
                      : (isDark
                          ? BrandColors.nightSurface
                          : BrandColors.softWhite),
                  borderRadius: Radii.pill,
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: TypographyTokens.labelSmall,
                    fontWeight: FontWeight.w600,
                    color: isSelected
                        ? Colors.white
                        : (isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _refreshSessions() async {
    // Invalidate the provider to fetch the updated list
    ref.invalidate(chatSessionsProvider);
    await ref.read(chatSessionsProvider.future);
  }

  Widget _buildSessionsList(
    BuildContext context,
    List<ChatSession> sessions,
    bool isDark,
  ) {
    // Apply filter
    List<ChatSession> filteredSessions;
    switch (_currentFilter) {
      case ChatFilter.active:
        filteredSessions = sessions.where((s) => !s.archived && !s.isImported).toList();
        break;
      case ChatFilter.imported:
        filteredSessions = sessions.where((s) => s.isImported).toList();
        break;
      case ChatFilter.archived:
        filteredSessions = sessions.where((s) => s.archived).toList();
        break;
      case ChatFilter.all:
        filteredSessions = sessions.toList();
        break;
    }

    if (filteredSessions.isEmpty) {
      // Wrap empty states in RefreshIndicator so pull-to-refresh works
      return RefreshIndicator(
        onRefresh: _refreshSessions,
        color: BrandColors.forest,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: _currentFilter == ChatFilter.imported
                  ? _buildEmptyImportedState(isDark)
                  : _currentFilter == ChatFilter.archived
                      ? _buildEmptyArchivedState(isDark)
                      : _buildEmptyState(context, isDark),
            ),
          ),
        ),
      );
    }

    // Group sessions by date
    final grouped = _groupSessionsByDate(filteredSessions);

    return RefreshIndicator(
      onRefresh: _refreshSessions,
      color: BrandColors.forest,
      child: ListView.builder(
        padding: const EdgeInsets.all(Spacing.md),
        itemCount: grouped.length,
        itemBuilder: (context, index) {
          final group = grouped[index];
          return _buildDateGroup(context, group, isDark);
        },
      ),
    );
  }

  Widget _buildEmptyArchivedState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(Spacing.xl),
              decoration: BoxDecoration(
                color: isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.stone.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.archive_outlined,
                size: 48,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            const SizedBox(height: Spacing.xl),
            Text(
              'No archived chats',
              style: TextStyle(
                fontSize: TypographyTokens.headlineSmall,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              'Swipe left on a chat to archive it.\nArchived chats are hidden but not deleted.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                height: TypographyTokens.lineHeightRelaxed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyImportedState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(Spacing.xl),
              decoration: BoxDecoration(
                color: isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.stone.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.download_outlined,
                size: 48,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            const SizedBox(height: Spacing.xl),
            Text(
              'No imported chats',
              style: TextStyle(
                fontSize: TypographyTokens.headlineSmall,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              'Import your ChatGPT or Claude conversations\nfrom Settings → Advanced → Import Chat History',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                height: TypographyTokens.lineHeightRelaxed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateGroup(
    BuildContext context,
    _SessionGroup group,
    bool isDark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Date header
        Padding(
          padding: const EdgeInsets.only(
            left: Spacing.xs,
            top: Spacing.md,
            bottom: Spacing.sm,
          ),
          child: Text(
            group.label,
            style: TextStyle(
              fontSize: TypographyTokens.labelMedium,
              fontWeight: FontWeight.w600,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ),
        // Sessions in this group
        ...group.sessions.map((session) => Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: SessionListItem(
                session: session,
                onTap: () => _handleSessionTap(context, session),
                onDelete: () => _handleSessionDelete(session),
                onArchive: () => _handleSessionArchive(session),
                onUnarchive: () => _handleSessionUnarchive(session),
              ),
            )),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(Spacing.xl),
              decoration: BoxDecoration(
                color: isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.forestMist.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.chat_outlined,
                size: 48,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
            ),
            const SizedBox(height: Spacing.xl),
            Text(
              'Start a conversation',
              style: TextStyle(
                fontSize: TypographyTokens.headlineSmall,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              'Your AI assistant has access to your vault.\nAsk questions, explore ideas, or just think out loud.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                height: TypographyTokens.lineHeightRelaxed,
              ),
            ),
            const SizedBox(height: Spacing.xxl),

            // Quick suggestions
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              alignment: WrapAlignment.center,
              children: [
                _QuickSuggestionChip(
                  label: 'Summarize my recent notes',
                  isDark: isDark,
                  onTap: () => _startNewChatWithPrompt(context, 'Summarize my recent notes'),
                ),
                _QuickSuggestionChip(
                  label: 'What did I capture today?',
                  isDark: isDark,
                  onTap: () => _startNewChatWithPrompt(context, 'What did I capture today?'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading(bool isDark) {
    return Center(
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
      ),
    );
  }

  Widget _buildError(bool isDark, String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'Couldn\'t load conversations',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              'Check that the agent server is running',
              style: TextStyle(
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickChatInput(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: GestureDetector(
          onTap: () => _startNewChat(context),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm + 2,
            ),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightSurface
                  : BrandColors.stone.withValues(alpha: 0.5),
              borderRadius: Radii.pill,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.chat_bubble_outline,
                  size: 20,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
                const SizedBox(width: Spacing.sm),
                Text(
                  'Start a new conversation...',
                  style: TextStyle(
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ),
                const Spacer(),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 14,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // Actions
  // ============================================================

  Future<void> _continueFromClaudeCode(BuildContext context) async {
    final sessionId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => const ClaudeCodeImportScreen(),
      ),
    );

    // If a session was selected/adopted, open it
    if (sessionId != null && mounted) {
      ref.invalidate(chatSessionsProvider);
      ref.read(switchSessionProvider)(sessionId);
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const ChatScreen(),
        ),
      );
    }
  }

  Future<void> _startNewChat(BuildContext context) async {
    // Reset context selection before showing sheet
    ref.read(selectedContextFoldersProvider.notifier).state = [""];

    // Show the new chat sheet
    final config = await NewChatSheet.show(context);

    // If user cancelled, do nothing
    if (config == null) return;

    // Clear session and store configuration
    ref.read(newChatProvider)();

    // Store contexts directly in the chat state so they survive navigation
    ref.read(chatMessagesProvider.notifier).setSelectedContexts(config.contextFolders);
    ref.read(selectedContextFoldersProvider.notifier).state = config.contextFolders;

    // Set working directory if specified
    if (config.workingDirectory != null) {
      ref.read(chatMessagesProvider.notifier).setWorkingDirectory(
            config.workingDirectory,
          );
    }

    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => const ChatScreen(),
        ),
      );
    }
  }

  Future<void> _startNewChatWithPrompt(BuildContext context, String prompt) async {
    // Reset context selection before showing sheet
    ref.read(selectedContextFoldersProvider.notifier).state = [""];

    // Show the new chat sheet
    final config = await NewChatSheet.show(context);

    // If user cancelled, do nothing
    if (config == null) return;

    ref.read(newChatProvider)();

    // Store contexts directly in the chat state so they survive navigation
    ref.read(chatMessagesProvider.notifier).setSelectedContexts(config.contextFolders);
    ref.read(selectedContextFoldersProvider.notifier).state = config.contextFolders;

    // Set working directory if specified
    if (config.workingDirectory != null) {
      ref.read(chatMessagesProvider.notifier).setWorkingDirectory(
            config.workingDirectory,
          );
    }

    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ChatScreen(initialMessage: prompt),
        ),
      );
    }
  }

  void _handleSessionTap(BuildContext context, ChatSession session) {
    ref.read(switchSessionProvider)(session.id);

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const ChatScreen(),
      ),
    );
  }

  Future<void> _handleSessionDelete(ChatSession session) async {
    await ref.read(deleteSessionProvider)(session.id);
  }

  Future<void> _handleSessionArchive(ChatSession session) async {
    await ref.read(archiveSessionProvider)(session.id);
  }

  Future<void> _handleSessionUnarchive(ChatSession session) async {
    await ref.read(unarchiveSessionProvider)(session.id);
  }

  // ============================================================
  // Helpers
  // ============================================================

  List<_SessionGroup> _groupSessionsByDate(List<ChatSession> sessions) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final thisWeekStart = today.subtract(Duration(days: today.weekday - 1));

    // Helper to get the relevant date for sorting/grouping
    // Convert to local time to ensure correct date comparison
    DateTime getRelevantDate(ChatSession s) =>
        (s.updatedAt ?? s.createdAt).toLocal();

    // Sort all sessions by date descending (newest first)
    final sortedSessions = sessions.toList()
      ..sort((a, b) => getRelevantDate(b).compareTo(getRelevantDate(a)));

    final todaySessions = <ChatSession>[];
    final yesterdaySessions = <ChatSession>[];
    final thisWeekSessions = <ChatSession>[];
    final earlierSessions = <ChatSession>[];

    for (final session in sortedSessions) {
      final relevantDate = getRelevantDate(session);
      final sessionDate = DateTime(
        relevantDate.year,
        relevantDate.month,
        relevantDate.day,
      );

      if (sessionDate == today) {
        todaySessions.add(session);
      } else if (sessionDate == yesterday) {
        yesterdaySessions.add(session);
      } else if (sessionDate.isAfter(thisWeekStart) || sessionDate == thisWeekStart) {
        thisWeekSessions.add(session);
      } else {
        earlierSessions.add(session);
      }
    }

    final groups = <_SessionGroup>[];

    if (todaySessions.isNotEmpty) {
      groups.add(_SessionGroup(label: 'Today', sessions: todaySessions));
    }
    if (yesterdaySessions.isNotEmpty) {
      groups.add(_SessionGroup(label: 'Yesterday', sessions: yesterdaySessions));
    }
    if (thisWeekSessions.isNotEmpty) {
      groups.add(_SessionGroup(label: 'This Week', sessions: thisWeekSessions));
    }
    if (earlierSessions.isNotEmpty) {
      groups.add(_SessionGroup(label: 'Earlier', sessions: earlierSessions));
    }

    return groups;
  }
}

class _SessionGroup {
  final String label;
  final List<ChatSession> sessions;

  const _SessionGroup({
    required this.label,
    required this.sessions,
  });
}

class _QuickSuggestionChip extends StatelessWidget {
  final String label;
  final bool isDark;
  final VoidCallback onTap;

  const _QuickSuggestionChip({
    required this.label,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      onPressed: onTap,
      backgroundColor: isDark
          ? BrandColors.nightSurfaceElevated
          : BrandColors.stone.withValues(alpha: 0.5),
      labelStyle: TextStyle(
        fontSize: TypographyTokens.labelMedium,
        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: Radii.badge,
        side: BorderSide(
          color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone,
        ),
      ),
    );
  }
}
