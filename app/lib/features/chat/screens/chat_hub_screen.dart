import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
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
///
/// Requires server connection to function.
class ChatHubScreen extends ConsumerWidget {
  const ChatHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final serverUrlAsync = ref.watch(aiServerUrlProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Chat',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
        actions: [
          // Refresh button
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh sessions',
            onPressed: () => ref.invalidate(chatSessionsProvider),
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
      floatingActionButton: serverUrlAsync.valueOrNull?.isNotEmpty == true
          ? FloatingActionButton(
              onPressed: () => _startNewChat(context, ref),
              backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  void _startNewChat(BuildContext context, WidgetRef ref) {
    // Use newChatProvider to properly clear session state
    ref.read(newChatProvider)();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ChatScreen(),
      ),
    );
  }

  void _openSession(BuildContext context, WidgetRef ref, ChatSession session) {
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
    final sessionsAsync = ref.watch(chatSessionsProvider);

    return sessionsAsync.when(
      data: (sessions) {
        if (sessions.isEmpty) {
          return _buildEmptyState(context, isDark, serverUrl);
        }

        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(chatSessionsProvider);
            // Wait for the new data
            await ref.read(chatSessionsProvider.future);
          },
          child: ListView.builder(
            padding: EdgeInsets.symmetric(vertical: Spacing.sm),
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              return SessionListItem(
                session: session,
                onTap: () => _openSession(context, ref, session),
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
      error: (error, _) => _buildSessionsError(context, ref, isDark, error),
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
              Icons.chat_bubble_outline,
              size: 64,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(height: Spacing.lg),
            Text(
              'No Conversations Yet',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            SizedBox(height: Spacing.md),
            Text(
              'Connected to: $serverUrl',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    fontFamily: 'monospace',
                  ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: Spacing.md),
            Text(
              'Tap + to start a new conversation',
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

  Widget _buildSessionsError(BuildContext context, WidgetRef ref, bool isDark, Object error) {
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
              onPressed: () => ref.invalidate(chatSessionsProvider),
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
