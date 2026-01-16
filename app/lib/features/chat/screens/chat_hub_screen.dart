import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/features/settings/screens/settings_screen.dart';
import '../providers/chat_providers.dart';
import '../models/chat_session.dart';
import '../widgets/session_list_item.dart';
import 'chat_screen.dart';

/// Chat Hub Screen - shows list of chat sessions
///
/// Features:
/// - List of recent chat sessions
/// - New chat button
/// - Connection status
/// - Pull to refresh
/// - Toggle between active and archived chats
///
/// Requires server connection to function.
class ChatHubScreen extends ConsumerStatefulWidget {
  const ChatHubScreen({super.key});

  @override
  ConsumerState<ChatHubScreen> createState() => _ChatHubScreenState();
}

class _ChatHubScreenState extends ConsumerState<ChatHubScreen> {
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final serverUrlAsync = ref.watch(aiServerUrlProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _showArchived ? 'Archived Chats' : 'Chat',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
        actions: [
          // Archive toggle
          IconButton(
            icon: Icon(_showArchived ? Icons.inbox : Icons.archive_outlined),
            tooltip: _showArchived ? 'Show active chats' : 'Show archived chats',
            onPressed: () {
              setState(() {
                _showArchived = !_showArchived;
              });
            },
          ),
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh sessions',
            onPressed: () {
              ref.invalidate(chatSessionsProvider);
              ref.invalidate(archivedSessionsProvider);
            },
          ),
          // Settings button
          IconButton(
            icon: Icon(
              Icons.settings_outlined,
              color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
            ),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: serverUrlAsync.when(
        data: (serverUrl) {
          if (serverUrl.isEmpty) {
            return _buildNoServerState(context, isDark);
          }
          return _buildChatList(context, ref, isDark, serverUrl);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _buildErrorState(context, isDark, e),
      ),
      floatingActionButton: serverUrlAsync.valueOrNull?.isNotEmpty == true && !_showArchived
          ? FloatingActionButton(
              onPressed: () => _startNewChat(context),
              backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  void _startNewChat(BuildContext context) {
    // Use newChatProvider to properly clear session state
    ref.read(newChatProvider)();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ChatScreen(),
      ),
    );
  }

  void _openSession(BuildContext context, ChatSession session) {
    // Use switchSessionProvider to properly load session with messages
    // This sets currentSessionIdProvider AND calls loadSession
    ref.read(switchSessionProvider)(session.id);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ChatScreen(),
      ),
    );
  }

  Widget _buildNoServerState(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 64,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            SizedBox(height: Spacing.lg),
            Text(
              'No Server Connected',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            SizedBox(height: Spacing.md),
            Text(
              'Configure a Parachute Base server in Settings to enable AI Chat.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: Spacing.xl),
            FilledButton.icon(
              onPressed: () {
                Navigator.pushNamed(context, '/settings');
              },
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
              style: FilledButton.styleFrom(
                backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatList(BuildContext context, WidgetRef ref, bool isDark, String serverUrl) {
    // Watch the appropriate provider based on archive toggle
    final sessionsAsync = _showArchived
        ? ref.watch(archivedSessionsProvider)
        : ref.watch(chatSessionsProvider);

    return sessionsAsync.when(
      data: (sessions) {
        if (sessions.isEmpty) {
          return _buildEmptyState(context, isDark, serverUrl);
        }

        return RefreshIndicator(
          onRefresh: () async {
            if (_showArchived) {
              ref.invalidate(archivedSessionsProvider);
              await ref.read(archivedSessionsProvider.future);
            } else {
              ref.invalidate(chatSessionsProvider);
              await ref.read(chatSessionsProvider.future);
            }
          },
          child: ListView.builder(
            padding: EdgeInsets.symmetric(vertical: Spacing.sm),
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              return SessionListItem(
                session: session,
                onTap: () => _openSession(context, session),
                isDark: isDark,
              );
            },
          ),
        );
      },
      loading: () => const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: Spacing.md),
            Text('Loading sessions...'),
          ],
        ),
      ),
      error: (error, _) => _buildSessionsError(context, isDark, error),
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isDark, String serverUrl) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _showArchived ? Icons.archive_outlined : Icons.chat_bubble_outline,
              size: 64,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(height: Spacing.lg),
            Text(
              _showArchived ? 'No Archived Chats' : 'No Conversations Yet',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            SizedBox(height: Spacing.md),
            if (!_showArchived) ...[
              Text(
                'Connected to: $serverUrl',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      fontFamily: 'monospace',
                    ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: Spacing.md),
            ],
            Text(
              _showArchived
                  ? 'Archived conversations will appear here'
                  : 'Tap + to start a new conversation',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionsError(BuildContext context, bool isDark, Object error) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 64,
              color: BrandColors.warning,
            ),
            SizedBox(height: Spacing.lg),
            Text(
              'Unable to Load Sessions',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            SizedBox(height: Spacing.md),
            Text(
              'Could not connect to the server.\nMake sure Parachute Base is running.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: Spacing.xl),
            FilledButton.icon(
              onPressed: () {
                ref.invalidate(chatSessionsProvider);
                ref.invalidate(archivedSessionsProvider);
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
              style: FilledButton.styleFrom(
                backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, bool isDark, Object error) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: BrandColors.error,
            ),
            SizedBox(height: Spacing.lg),
            Text(
              'Error',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            SizedBox(height: Spacing.md),
            Text(
              error.toString(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: BrandColors.error,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
