import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/features/settings/models/trust_level.dart';
import 'package:parachute/features/settings/screens/settings_screen.dart';
import '../providers/chat_providers.dart';
import '../providers/session_search_provider.dart';
import '../models/chat_session.dart';
import '../widgets/date_grouped_session_list.dart';
import '../widgets/session_config_sheet.dart';
import '../widgets/usage_bar.dart';
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
          // New chat button (moved from FAB)
          if (!_showArchived && serverUrlAsync.valueOrNull?.isNotEmpty == true)
            IconButton(
              icon: Icon(
                Icons.add_comment_outlined,
                color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
              tooltip: 'New chat',
              onPressed: () => _startNewChat(context),
            ),
          // Search toggle
          if (!_showArchived && serverUrlAsync.valueOrNull?.isNotEmpty == true)
            IconButton(
              icon: Icon(
                _showSearch ? Icons.search_off : Icons.search,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
              tooltip: _showSearch ? 'Close search' : 'Search sessions',
              onPressed: () {
                setState(() {
                  _showSearch = !_showSearch;
                  if (!_showSearch) {
                    _searchController.clear();
                    ref.read(sessionSearchQueryProvider.notifier).state = '';
                  }
                });
              },
            ),
          // Archive toggle
          IconButton(
            icon: Icon(_showArchived ? Icons.inbox : Icons.archive_outlined),
            tooltip: _showArchived ? 'Show active chats' : 'Show archived chats',
            onPressed: () {
              setState(() {
                _showArchived = !_showArchived;
                if (_showArchived) {
                  _showSearch = false;
                  _searchController.clear();
                  ref.read(sessionSearchQueryProvider.notifier).state = '';
                }
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
              ref.invalidate(searchedSessionsProvider);
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
          // Show usage bar at top when server is connected
          return Column(
            children: [
              const UsageBar(),
              if (_showSearch) _buildSearchBar(isDark),
              Expanded(child: _buildChatList(context, ref, isDark, serverUrl)),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _buildErrorState(context, isDark, e),
      ),
      floatingActionButton: null,
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
    // Pending approval sessions show the approval dialog instead
    if (session.isPendingApproval && session.pairingRequestId != null) {
      _showApprovalDialog(context, session);
      return;
    }

    // Pending initialization sessions show the config sheet for activation
    if (session.isPendingInitialization) {
      SessionConfigSheet.show(context, session).then((saved) {
        if (saved == true) {
          ref.invalidate(chatSessionsProvider);
        }
      });
      return;
    }

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

  void _showApprovalDialog(BuildContext context, ChatSession session) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    var selectedTrust = TrustLevel.vault;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? BrandColors.nightSurfaceElevated : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: Spacing.lg,
            right: Spacing.lg,
            top: Spacing.lg,
            bottom: MediaQuery.of(context).viewInsets.bottom + Spacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  Icon(
                    session.source == ChatSource.telegram
                        ? Icons.send
                        : Icons.gamepad,
                    color: session.source == ChatSource.telegram
                        ? const Color(0xFF0088CC)
                        : const Color(0xFF5865F2),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: Text(
                      'Approve ${session.displayTitle}?',
                      style: TextStyle(
                        fontSize: TypographyTokens.titleMedium,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? BrandColors.nightText
                            : BrandColors.charcoal,
                      ),
                    ),
                  ),
                ],
              ),

              // First message preview
              if (session.firstMessage != null) ...[
                const SizedBox(height: Spacing.md),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: isDark
                        ? BrandColors.nightSurface
                        : BrandColors.cream,
                    borderRadius: Radii.card,
                  ),
                  child: Text(
                    session.firstMessage!,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodyMedium,
                      fontStyle: FontStyle.italic,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],

              // Trust level picker
              const SizedBox(height: Spacing.lg),
              Text(
                'Trust Level',
                style: TextStyle(
                  fontSize: TypographyTokens.labelMedium,
                  fontWeight: FontWeight.w500,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
              const SizedBox(height: Spacing.sm),
              ...TrustLevel.values.map((tl) => RadioListTile<TrustLevel>(
                    title: Text(
                      tl.displayName,
                      style: TextStyle(
                        color: isDark
                            ? BrandColors.nightText
                            : BrandColors.charcoal,
                      ),
                    ),
                    subtitle: Text(
                      tl.description,
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                    ),
                    value: tl,
                    groupValue: selectedTrust,
                    dense: true,
                    activeColor: isDark
                        ? BrandColors.nightTurquoise
                        : BrandColors.turquoise,
                    onChanged: (val) {
                      if (val != null) {
                        setSheetState(() => selectedTrust = val);
                      }
                    },
                  )),

              // Action buttons
              const SizedBox(height: Spacing.lg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _denyPairing(session.pairingRequestId!);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: BrandColors.error,
                        side: BorderSide(color: BrandColors.error),
                      ),
                      child: const Text('Deny'),
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _approvePairing(
                          session.pairingRequestId!,
                          selectedTrust.name,
                        );
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: isDark
                            ? BrandColors.nightForest
                            : BrandColors.forest,
                      ),
                      child: const Text('Approve'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _approvePairing(String requestId, String trustLevel) async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      final response = await http.post(
        Uri.parse('$serverUrl/api/bots/pairing/$requestId/approve'),
        headers: {
          'Content-Type': 'application/json',
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
        body: json.encode({'trust_level': trustLevel}),
      );

      if (mounted) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('User approved'),
              backgroundColor: BrandColors.forest,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Approval failed: ${response.statusCode}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
        // Refresh sessions list
        ref.invalidate(chatSessionsProvider);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Approval failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  Future<void> _denyPairing(String requestId) async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();
      final apiKey = await ref.read(apiKeyProvider.future);

      await http.post(
        Uri.parse('$serverUrl/api/bots/pairing/$requestId/deny'),
        headers: {
          if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        },
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Request denied'),
            backgroundColor: BrandColors.driftwood,
          ),
        );
        // Refresh sessions list
        ref.invalidate(chatSessionsProvider);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deny failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
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

  Widget _buildSearchBar(bool isDark) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.xs),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        style: TextStyle(
          fontSize: TypographyTokens.bodyMedium,
          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
        ),
        decoration: InputDecoration(
          hintText: 'Search conversations...',
          hintStyle: TextStyle(
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 20,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    ref.read(sessionSearchQueryProvider.notifier).state = '';
                  },
                )
              : null,
          filled: true,
          fillColor: isDark
              ? BrandColors.nightSurfaceElevated
              : BrandColors.stone.withValues(alpha: 0.3),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          isDense: true,
        ),
        onChanged: (value) {
          ref.read(sessionSearchQueryProvider.notifier).state = value;
          setState(() {}); // Update clear button visibility
        },
      ),
    );
  }

  Widget _buildChatList(BuildContext context, WidgetRef ref, bool isDark, String serverUrl) {
    // Watch the appropriate provider based on archive toggle and search state
    final searchQuery = ref.watch(sessionSearchQueryProvider);
    final AsyncValue<List<ChatSession>> sessionsAsync;
    if (_showArchived) {
      sessionsAsync = ref.watch(archivedSessionsProvider);
    } else if (searchQuery.isNotEmpty) {
      sessionsAsync = ref.watch(searchedSessionsProvider);
    } else {
      sessionsAsync = ref.watch(chatSessionsProvider);
    }

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
          child: DateGroupedSessionList(
            sessions: sessions,
            onTap: (session) => _openSession(context, session),
            isDark: isDark,
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
