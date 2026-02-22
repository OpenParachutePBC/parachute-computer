import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/widgets/error_boundary.dart';
import 'package:parachute/core/widgets/error_snackbar.dart';
import 'package:parachute/core/services/logging_service.dart';
import 'package:parachute/core/errors/app_error.dart';
import '../models/attachment.dart';
import '../models/chat_session.dart';
import '../providers/chat_providers.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_input.dart';
import '../widgets/session_selector.dart';
import '../widgets/connection_status_banner.dart';
import '../widgets/resume_marker.dart';
import '../widgets/session_resume_banner.dart';
import '../widgets/directory_picker.dart';
import '../widgets/unified_session_settings.dart';
import '../widgets/user_question_card.dart';
import '../../settings/models/trust_level.dart';
import '../../settings/screens/settings_screen.dart';
import '../models/workspace.dart';
import '../providers/workspace_providers.dart' show activeWorkspaceProvider, workspacesProvider;

/// Main chat screen for AI conversations
///
/// Supports:
/// - Streaming responses with real-time text and tool call display
/// - Session switching via bottom sheet
/// - Agent selection
/// - Initial context (e.g., from recording transcript)
/// - Auto-run mode for standalone agents
class ChatScreen extends ConsumerStatefulWidget {
  /// Optional initial message to pre-fill
  final String? initialMessage;

  /// Optional context to include with first message (e.g., recording transcript)
  final String? initialContext;

  /// If true, automatically sends [autoRunMessage] on screen load
  final bool autoRun;

  /// Message to auto-send when [autoRun] is true
  final String? autoRunMessage;

  /// Agent type for new sessions (e.g., 'orchestrator', 'vault-agent')
  final String? agentType;

  /// Path to agent definition file (e.g., 'Daily/.agents/orchestrator.md')
  final String? agentPath;

  /// Trust level override (full, vault, sandboxed). Null = module default.
  final String? trustLevel;

  /// When true, renders without Scaffold/AppBar for embedding in panel layouts.
  final bool embeddedMode;

  const ChatScreen({
    super.key,
    this.initialMessage,
    this.initialContext,
    this.autoRun = false,
    this.autoRunMessage,
    this.agentType,
    this.agentPath,
    this.trustLevel,
    this.embeddedMode = false,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  String? _pendingInitialContext;
  String? _pendingAgentType;
  String? _pendingAgentPath;
  String? _pendingTrustLevel;
  bool _hasAutoRun = false;
  bool _resumeBannerDismissed = false;

  /// Track if user is scrolled away from bottom (to show scroll-to-bottom FAB)
  bool _showScrollToBottomFab = false;

  /// Controlled listener subscription for chat messages
  ProviderSubscription<ChatMessagesState>? _chatMessagesSubscription;

  @override
  void initState() {
    super.initState();
    _pendingInitialContext = widget.initialContext;
    _pendingAgentType = widget.agentType;
    _pendingAgentPath = widget.agentPath;
    _pendingTrustLevel = widget.trustLevel;

    // Listen to scroll position to show/hide scroll-to-bottom FAB
    _scrollController.addListener(_onScroll);

    // Schedule auto-run after first frame
    if (widget.autoRun && widget.autoRunMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _performAutoRun();
      });
    }

    // Scroll to bottom after first frame if messages are loaded
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottomInstant();
      // Set up the chat messages listener after first frame
      // Using listenManual gives us control over the subscription lifecycle
      _setupChatMessagesListener();
    });
  }

  /// Set up a controlled listener for chat messages changes
  void _setupChatMessagesListener() {
    // Cancel any existing subscription
    _chatMessagesSubscription?.close();

    _chatMessagesSubscription = ref.listenManual(
      chatMessagesProvider,
      (previous, next) {
        if (!mounted) return;

        final prevCount = previous?.messages.length ?? 0;
        final nextCount = next.messages.length;

        if (nextCount != prevCount) {
          // If loading a session (0 -> many messages), scroll instantly
          // Otherwise animate for streaming/new messages
          if (prevCount == 0 && nextCount > 1) {
            _scrollToBottomInstant();
          } else {
            _scrollToBottom();
          }
        }

        // Reset resume banner when session changes
        if (previous?.sessionId != next.sessionId) {
          setState(() {
            _resumeBannerDismissed = false;
          });
        }

        // Show session recovery dialog when session is unavailable
        if (next.sessionUnavailable != null && previous?.sessionUnavailable == null) {
          _showSessionRecoveryDialog(next.sessionUnavailable!);
        }
      },
      fireImmediately: false,
    );
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    // Show FAB if scrolled more than 200 pixels from bottom
    final isNearBottom = position.maxScrollExtent - position.pixels < 200;
    final shouldShowFab = !isNearBottom;

    // Only call setState if the value actually changed
    if (_showScrollToBottomFab != shouldShowFab) {
      setState(() {
        _showScrollToBottomFab = shouldShowFab;
      });
    }
  }

  void _performAutoRun() {
    if (_hasAutoRun) return;
    _hasAutoRun = true;
    _handleSend(widget.autoRunMessage!, []);
  }

  @override
  void dispose() {
    // Close the chat messages subscription before disposing
    // This prevents _dependents.isEmpty assertion errors
    _chatMessagesSubscription?.close();
    _chatMessagesSubscription = null;

    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: Motion.standard,
            curve: Motion.settling,
          );
        }
      });
    }
  }

  /// Scroll to bottom instantly (no animation) - for initial load
  void _scrollToBottomInstant() {
    // Use post-frame callbacks to ensure layout is complete
    // Reduced from 5 to 2 attempts to minimize frame overhead
    int attempts = 0;
    const maxAttempts = 2;

    void tryScroll() {
      if (!mounted) return;
      attempts++;

      if (_scrollController.hasClients) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(maxExtent);

        // Schedule one more check in case content is still loading
        if (attempts < maxAttempts) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scrollController.hasClients) {
              final newMaxExtent = _scrollController.position.maxScrollExtent;
              // If max extent changed, scroll again
              if (newMaxExtent > maxExtent) {
                _scrollController.jumpTo(newMaxExtent);
              }
            }
          });
        }
      } else if (attempts < maxAttempts) {
        // Retry on next frame if not ready yet
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) tryScroll();
        });
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) tryScroll();
    });
  }

  void _handleSend(String message, [List<ChatAttachment>? attachments]) {
    final chatState = ref.read(chatMessagesProvider);

    // Debug: trace context selection
    debugPrint('[ChatScreen] _handleSend - messages.isEmpty: ${chatState.messages.isEmpty}');
    debugPrint('[ChatScreen] _handleSend - sessionId: ${chatState.sessionId}');
    debugPrint('[ChatScreen] _handleSend - selectedContexts: ${chatState.selectedContexts}');
    debugPrint('[ChatScreen] _handleSend - contextsExplicitlySet: ${chatState.contextsExplicitlySet}');

    // Contexts are handled by ChatMessagesNotifier.sendMessage() based on:
    // - contexts param (if passed)
    // - chatState.selectedContexts (if contextsExplicitlySet is true)
    // - server defaults (otherwise)

    ref.read(chatMessagesProvider.notifier).sendMessage(
          message: message,
          initialContext: _pendingInitialContext,
          attachments: attachments,
          agentType: _pendingAgentType,
          agentPath: _pendingAgentPath,
          trustLevel: _pendingTrustLevel,
          workspaceId: ref.read(activeWorkspaceProvider),
        );

    // Clear pending context, agentType, agentPath, and trustLevel after first message
    _pendingInitialContext = null;
    _pendingAgentType = null;
    _pendingAgentPath = null;
    _pendingTrustLevel = null;

    _scrollToBottom();
  }

  void _handleStop() {
    ref.read(chatMessagesProvider.notifier).abortStream();
  }

  Future<void> _showDirectoryPicker() async {
    final chatState = ref.read(chatMessagesProvider);
    final currentPath = chatState.workingDirectory;

    final selectedPath = await showDirectoryPicker(
      context,
      initialPath: currentPath,
    );

    // null means canceled, any other value (including empty string) is a selection
    if (selectedPath != null && mounted) {
      ref.read(chatMessagesProvider.notifier).setWorkingDirectory(
            selectedPath.isEmpty ? null : selectedPath,
          );
    }
  }

  void _showSessionRecoveryDialog(SessionUnavailableInfo info) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          title: const Text('Session Recovery'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(info.message),
              if (info.hasMarkdownHistory) ...[
                const SizedBox(height: 12),
                Text(
                  '${info.messageCount} messages available from history.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                ref.read(chatMessagesProvider.notifier).dismissSessionUnavailable();
              },
              child: const Text('Cancel'),
            ),
            if (info.hasMarkdownHistory)
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  ref.read(chatMessagesProvider.notifier).recoverSession('inject_context');
                },
                child: const Text('Continue with History'),
              ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                ref.read(chatMessagesProvider.notifier).recoverSession('fresh_start');
              },
              child: const Text('Start Fresh'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chatState = ref.watch(chatMessagesProvider);
    final currentSessionId = ref.watch(currentSessionIdProvider);

    // NOTE: Auto-scroll listener is set up via listenManual in initState
    // This avoids _dependents.isEmpty assertion errors during disposal

    // Wrap in error boundary to catch rendering errors
    return ScreenErrorBoundary(
      onError: (error, stack) {
        logger.createLogger('ChatScreen').error(
          'Chat screen error',
          error: error,
          stackTrace: stack,
        );
      },
      child: widget.embeddedMode
          ? _buildBody(context, isDark, chatState)
          : Scaffold(
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
        floatingActionButton: _showScrollToBottomFab
            ? Padding(
                padding: const EdgeInsets.only(bottom: 80), // Above the input field
                child: FloatingActionButton.small(
                  onPressed: _scrollToBottom,
                  backgroundColor: isDark
                      ? BrandColors.nightSurfaceElevated
                      : BrandColors.softWhite,
                  foregroundColor: isDark
                      ? BrandColors.nightForest
                      : BrandColors.forest,
                  elevation: 4,
                  child: const Icon(Icons.keyboard_arrow_down),
                ),
              )
            : null,
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        appBar: AppBar(
          backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
          surfaceTintColor: Colors.transparent,
          title: _buildTitle(context, isDark, currentSessionId, chatState),
          actions: [
            // Working directory picker (only for new chats)
            if (chatState.workingDirectory == null && chatState.messages.isEmpty)
              IconButton(
                onPressed: _showDirectoryPicker,
                icon: const Icon(Icons.folder_outlined, size: 20),
                tooltip: 'Set working directory',
              ),
            // Unified session settings
            if (chatState.sessionId != null)
              IconButton(
                onPressed: () => _showUnifiedSettings(context),
                icon: Icon(
                  Icons.settings_outlined,
                  size: 20,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
                ),
                tooltip: 'Session settings',
              ),
            // More actions menu (archive, delete, refresh)
            if (chatState.sessionId != null)
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_vert,
                  size: 20,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
                ),
                tooltip: 'More actions',
                onSelected: (value) => _handleMenuAction(value, chatState.sessionId!),
                itemBuilder: (context) => [
                  if (!chatState.isStreaming)
                    const PopupMenuItem(
                      value: 'refresh',
                      child: Row(
                        children: [
                          Icon(Icons.refresh, size: 20),
                          SizedBox(width: Spacing.sm),
                          Text('Refresh'),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'archive',
                    child: Row(
                      children: [
                        Icon(
                          Icons.archive_outlined,
                          size: 20,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                        const SizedBox(width: Spacing.sm),
                        const Text('Archive'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: BrandColors.error,
                        ),
                        const SizedBox(width: Spacing.sm),
                        Text(
                          'Delete',
                          style: TextStyle(color: BrandColors.error),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            const SizedBox(width: Spacing.xs),
          ],
      ),
      body: _buildBody(context, isDark, chatState),
    ),
    );
  }

  /// Builds a compact toolbar for embedded (tablet/desktop) mode where there's no AppBar.
  Widget _buildEmbeddedToolbar(BuildContext context, bool isDark, ChatMessagesState chatState) {
    final currentSessionId = ref.watch(currentSessionIdProvider);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        border: Border(
          bottom: BorderSide(
            color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.stone.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          // Session title (tappable to switch sessions)
          Expanded(
            child: _buildTitle(context, isDark, currentSessionId, chatState),
          ),

          // Badges (constrained to avoid overflow)
          Flexible(
            flex: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Agent badge
                if (chatState.promptMetadata?.agentName != null &&
                    chatState.promptMetadata!.agentName != 'Vault Agent')
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Container(
                      margin: const EdgeInsets.only(right: Spacing.xs),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xxs,
                      ),
                      decoration: BoxDecoration(
                        color: BrandColors.turquoise.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.smart_toy, size: 12, color: BrandColors.turquoise),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              _getAgentBadge(chatState.promptMetadata!.agentName!),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: BrandColors.turquoise,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Model badge
                if (chatState.model != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Container(
                      margin: const EdgeInsets.only(right: Spacing.xs),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.sm,
                        vertical: Spacing.xxs,
                      ),
                      decoration: BoxDecoration(
                        color: _getModelColor(chatState.model!).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _getModelBadge(chatState.model!),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: _getModelColor(chatState.model!),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),

                // Working directory indicator
                if (chatState.workingDirectory != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Tooltip(
                      message: chatState.workingDirectory!,
                      child: InkWell(
                        onTap: chatState.messages.isEmpty ? _showDirectoryPicker : null,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.folder_outlined,
                                size: 16,
                                color: isDark ? BrandColors.nightForest : BrandColors.forest,
                              ),
                              const SizedBox(width: 2),
                              Flexible(
                                child: Text(
                                  chatState.workingDirectory!.split('/').last,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Unified session settings (trust, workspace, context, info)
          if (chatState.sessionId != null)
            IconButton(
              onPressed: () => _showUnifiedSettings(context),
              icon: Icon(Icons.settings_outlined, size: 18),
              tooltip: 'Session settings',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
            ),

          // More actions menu (archive, delete)
          if (chatState.sessionId != null)
            PopupMenuButton<String>(
              icon: Icon(
                Icons.more_vert,
                size: 18,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
              ),
              tooltip: 'More actions',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onSelected: (value) => _handleMenuAction(value, chatState.sessionId!),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'archive',
                  child: Row(
                    children: [
                      Icon(
                        Icons.archive_outlined,
                        size: 20,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                      const SizedBox(width: Spacing.sm),
                      const Text('Archive'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, size: 20, color: BrandColors.error),
                      const SizedBox(width: Spacing.sm),
                      Text('Delete', style: TextStyle(color: BrandColors.error)),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, bool isDark, ChatMessagesState chatState) {
    return ColoredBox(
      color: isDark ? BrandColors.nightSurface : BrandColors.cream,
      child: Column(
        children: [
          // Embedded toolbar for tablet/desktop mode (replaces AppBar)
          if (widget.embeddedMode)
            _buildEmbeddedToolbar(context, isDark, chatState),

          // Connection status banner (shows when server unreachable)
          ConnectionStatusBanner(
            onSettings: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),

          // Session resume banner (shows when context was rebuilt)
          if (chatState.sessionResumeInfo != null && !_resumeBannerDismissed)
            SessionResumeBanner(
              resumeInfo: chatState.sessionResumeInfo!,
              onDismiss: () {
                setState(() {
                  _resumeBannerDismissed = true;
                });
              },
            ),

          // Context banner (if initial context provided)
          if (_pendingInitialContext != null)
            _buildContextBanner(context, isDark),

          // Messages list
          Expanded(
            child: chatState.isLoading
                ? _buildLoadingState(isDark)
                : chatState.messages.isEmpty
                    ? _buildEmptyStateOrContinuation(context, isDark, chatState)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(Spacing.md),
                        cacheExtent: 500,
                        addRepaintBoundaries: true,
                        // Keep items alive when scrolled off-screen (works with AutomaticKeepAliveClientMixin)
                        addAutomaticKeepAlives: true,
                        itemCount: chatState.messages.length +
                            (chatState.isContinuation ? 1 : 0) +
                            (chatState.hasEarlierSegments ? 1 : 0),
                        itemBuilder: (context, index) {
                          // Show "load earlier" at the very top if there are earlier segments
                          if (chatState.hasEarlierSegments && index == 0) {
                            return _buildLoadEarlierSegmentsButton(isDark, chatState);
                          }

                          // Adjust index for the load-earlier button
                          final adjustedIndex = chatState.hasEarlierSegments ? index - 1 : index;

                          // Show resume marker at the top if this is a continuation
                          if (chatState.isContinuation && adjustedIndex == 0) {
                            return ResumeMarker(
                              key: const ValueKey('resume_marker'),
                              originalSession: chatState.continuedFromSession!,
                              priorMessages: chatState.priorMessages,
                            );
                          }
                          final msgIndex = chatState.isContinuation ? adjustedIndex - 1 : adjustedIndex;
                          final message = chatState.messages[msgIndex];
                          return MessageBubble(
                            key: ValueKey(message.id),
                            message: message,
                          );
                        },
                      ),
          ),

          // Error banner
          if (chatState.error != null)
            _buildErrorBanner(context, isDark, chatState.error!),

          // Resume button for archived sessions
          if (chatState.isViewingArchived)
            _buildContinueButton(context, isDark, chatState),

          // User question card (when Claude is asking via AskUserQuestion)
          if (chatState.pendingUserQuestion != null)
            _buildUserQuestionCard(chatState.pendingUserQuestion!),

          // Input field - disabled when viewing archived sessions
          ChatInput(
            onSend: _handleSend,
            onStop: _handleStop,
            enabled: !chatState.isViewingArchived,
            isStreaming: chatState.isStreaming,
            initialText: widget.initialMessage,
            hintText: _pendingInitialContext != null
                ? 'Ask about this recording...'
                : chatState.isViewingArchived
                    ? 'Click Resume to continue this conversation'
                    : 'Message your vault...',
          ),
        ],
      ),
    );
  }

  Widget _buildTitle(BuildContext context, bool isDark, String? sessionId, ChatMessagesState chatState) {
    final sessionTitle = chatState.sessionTitle;

    // Determine title text
    String titleText;
    if (sessionId == null) {
      titleText = 'Parachute Chat';
    } else if (sessionTitle != null && sessionTitle.isNotEmpty) {
      titleText = sessionTitle;
    } else {
      titleText = 'Parachute Chat';
    }

    return GestureDetector(
      onTap: () => SessionSelector.show(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 20,
            color: isDark ? BrandColors.nightForest : BrandColors.forest,
          ),
          const SizedBox(width: Spacing.sm),
          Flexible(
            child: Text(
              titleText,
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.w600,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(
            Icons.arrow_drop_down,
            size: 20,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ],
      ),
    );
  }


  /// Build loading state shown during session switch
  Widget _buildLoadingState(bool isDark) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(
            strokeWidth: 2,
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          ),
          const SizedBox(height: Spacing.md),
          Text(
            'Loading session...',
            style: TextStyle(
              fontSize: TypographyTokens.bodyMedium,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ],
      ),
    );
  }

  /// Build button to load earlier segments (shown when conversation history is truncated)
  Widget _buildLoadEarlierSegmentsButton(bool isDark, ChatMessagesState chatState) {
    // Find the first unloaded segment that we can load
    final unloadedSegments = chatState.transcriptSegments
        .where((s) => !s.loaded && s.index < chatState.transcriptSegmentCount - 1)
        .toList();

    if (unloadedSegments.isEmpty) {
      return const SizedBox.shrink();
    }

    // Get the most recent unloaded segment (closest to current content)
    final nextSegment = unloadedSegments.last;
    final segmentCount = unloadedSegments.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Center(
        child: InkWell(
          onTap: () {
            ref.read(chatMessagesProvider.notifier).loadSegment(nextSegment.index);
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightSurfaceElevated
                  : BrandColors.forestMist.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.stone.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.history,
                  size: 16,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(width: Spacing.xs),
                Flexible(
                  child: Text(
                    segmentCount > 1
                        ? 'Load earlier messages ($segmentCount segments)'
                        : 'Load earlier messages',
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      fontWeight: FontWeight.w500,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (nextSegment.preview != null) ...[
                  const SizedBox(width: Spacing.sm),
                  Flexible(
                    child: Text(
                      '• ${nextSegment.preview}',
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyStateOrContinuation(
    BuildContext context,
    bool isDark,
    ChatMessagesState chatState,
  ) {
    // If this is a continuation, show the resume marker with a prompt to continue
    if (chatState.isContinuation) {
      return ListView(
        controller: _scrollController,
        padding: const EdgeInsets.all(Spacing.md),
        children: [
          ResumeMarker(
            originalSession: chatState.continuedFromSession!,
            priorMessages: chatState.priorMessages,
          ),
          const SizedBox(height: Spacing.xl),
          Center(
            child: Column(
              children: [
                Icon(
                  Icons.chat_outlined,
                  size: 32,
                  color: isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
                const SizedBox(height: Spacing.md),
                Text(
                  'Continue the conversation',
                  style: TextStyle(
                    fontSize: TypographyTokens.titleMedium,
                    fontWeight: FontWeight.w600,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  'Send a message to pick up where you left off',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodyMedium,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return _buildEmptyState(context, isDark);
  }

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    return SingleChildScrollView(
      child: Center(
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
              'Ask questions about your vault, get help with ideas,\nor explore your thoughts.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: TypographyTokens.bodyMedium,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
                height: TypographyTokens.lineHeightRelaxed,
              ),
            ),
            const SizedBox(height: Spacing.xl),
            // Quick suggestion chips
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              alignment: WrapAlignment.center,
              children: [
                _SuggestionChip(
                  label: 'Summarize my recent notes',
                  onTap: () => _handleSend('Summarize my recent notes', []),
                ),
                _SuggestionChip(
                  label: 'What did I capture today?',
                  onTap: () => _handleSend('What did I capture today?', []),
                ),
              ],
            ),
            const SizedBox(height: Spacing.xl),
            // Workspace selector for new chats
            _buildWorkspaceSelector(isDark),
            const SizedBox(height: Spacing.md),
            // Trust level selector for new chats
            _buildTrustLevelSelector(isDark),
            const SizedBox(height: Spacing.md),
            // Working directory indicator
            _buildWorkingDirectoryIndicator(isDark),
          ],
        ),
      ),
    ),
  );
}

  Widget _buildWorkspaceSelector(bool isDark) {
    final workspacesAsync = ref.watch(workspacesProvider);
    final activeSlug = ref.watch(activeWorkspaceProvider);

    return workspacesAsync.when(
      data: (workspaces) {
        if (workspaces.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            Text(
              'Workspace',
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                fontWeight: FontWeight.w500,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: 0,
              runSpacing: Spacing.xs,
              alignment: WrapAlignment.center,
              children: [
                _buildWorkspaceChip(null, 'None', activeSlug == null, isDark),
                ...workspaces.map((w) =>
                  _buildWorkspaceChip(w, w.name, activeSlug == w.slug, isDark),
                ),
              ],
            ),
          ],
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildWorkspaceChip(Workspace? workspace, String label, bool isSelected, bool isDark) {
    final color = isDark ? BrandColors.nightForest : BrandColors.forest;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: GestureDetector(
        onTap: () {
          ref.read(activeWorkspaceProvider.notifier).state = workspace?.slug;
          if (workspace != null) {
            // Set default trust from workspace (user can still change freely)
            if (_pendingTrustLevel == null) {
              final wsTrust = TrustLevel.fromString(workspace.defaultTrustLevel);
              setState(() {
                _pendingTrustLevel = wsTrust == TrustLevel.direct ? null : wsTrust.name;
              });
            }
            // Auto-fill working directory
            if (workspace.workingDirectory != null) {
              ref.read(chatMessagesProvider.notifier).setWorkingDirectory(workspace.workingDirectory);
            }
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isSelected
                ? color.withValues(alpha: 0.15)
                : (isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.stone.withValues(alpha: 0.2)),
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(
              color: isSelected ? color : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                workspace == null ? Icons.do_not_disturb_alt : Icons.workspaces_outlined,
                size: 13,
                color: isSelected ? color : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: isSelected ? color : (isDark ? BrandColors.nightText : BrandColors.charcoal),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrustLevelSelector(bool isDark) {
    final currentLevel = _pendingTrustLevel != null
        ? TrustLevel.fromString(_pendingTrustLevel)
        : TrustLevel.direct;

    return Column(
      children: [
        Text(
          'Execution Mode',
          style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            fontWeight: FontWeight.w500,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: 0,
          runSpacing: Spacing.xs,
          children: TrustLevel.values.map((tl) {
            final isSelected = currentLevel == tl;
            final color = tl.iconColor(isDark);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Tooltip(
                message: tl.description,
                child: GestureDetector(
                  onTap: () => setState(() {
                    _pendingTrustLevel = tl == TrustLevel.direct ? null : tl.name;
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? color.withValues(alpha: 0.15)
                          : (isDark
                              ? BrandColors.nightSurfaceElevated
                              : BrandColors.stone.withValues(alpha: 0.2)),
                      borderRadius: BorderRadius.circular(Radii.sm),
                      border: Border.all(
                        color: isSelected ? color : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(tl.icon, size: 13, color: isSelected ? color : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)),
                        const SizedBox(width: 4),
                        Text(
                          tl.displayName,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: isSelected ? color : (isDark ? BrandColors.nightText : BrandColors.charcoal),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        // Description text for selected trust level
        const SizedBox(height: Spacing.xs),
        Text(
          currentLevel.description,
          style: TextStyle(
            fontSize: 10,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        // Sandbox config panel (shown when Sandboxed is selected)
        if (currentLevel == TrustLevel.sandboxed)
          _buildSandboxConfigPanel(isDark),
      ],
    );
  }

  Widget _buildSandboxConfigPanel(bool isDark) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: Container(
        margin: const EdgeInsets.only(top: Spacing.sm),
        padding: const EdgeInsets.all(Spacing.sm),
        decoration: BoxDecoration(
          color: isDark
              ? BrandColors.nightSurface
              : Colors.blue.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: Colors.blue.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Docker status
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.amber,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'Docker required for full isolation',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Resource info
            Text(
              '512MB memory, 1 CPU core',
              style: TextStyle(
                fontSize: 10,
                color: isDark
                    ? BrandColors.nightTextSecondary.withValues(alpha: 0.7)
                    : BrandColors.driftwood.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkingDirectoryIndicator(bool isDark) {
    final chatState = ref.watch(chatMessagesProvider);
    final wd = chatState.workingDirectory;
    final color = isDark ? BrandColors.nightForest : BrandColors.forest;

    return GestureDetector(
      onTap: _showDirectoryPicker,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_outlined,
            size: 14,
            color: wd != null ? color : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
          ),
          const SizedBox(width: 4),
          Text(
            wd != null ? wd.split('/').last : 'Vault root',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: wd != null ? color : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.edit_outlined,
            size: 11,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ],
      ),
    );
  }

  Widget _buildContextBanner(BuildContext context, bool isDark) {
    return Container(
      margin: const EdgeInsets.all(Spacing.md),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightTurquoise.withValues(alpha: 0.1)
            : BrandColors.turquoiseMist,
        borderRadius: Radii.card,
        border: Border.all(
          color: isDark
              ? BrandColors.nightTurquoise.withValues(alpha: 0.3)
              : BrandColors.turquoiseLight,
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.description_outlined,
            size: 20,
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              'Recording context attached',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color:
                    isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep,
              ),
            ),
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _pendingInitialContext = null;
              });
            },
            icon: Icon(
              Icons.close,
              size: 18,
              color:
                  isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep,
            ),
            constraints: const BoxConstraints(),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  Widget _buildContinueButton(
    BuildContext context,
    bool isDark,
    ChatMessagesState chatState,
  ) {
    final session = chatState.viewingSession!;

    // Determine the status text based on session type
    final statusText = session.isImported
        ? 'Imported from ${session.source.displayName}'
        : 'Archived chat';
    final statusIcon = session.isImported ? Icons.history : Icons.archive_outlined;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightForest.withValues(alpha: 0.1)
            : BrandColors.forestMist,
        border: Border(
          top: BorderSide(
            color: isDark
                ? BrandColors.nightForest.withValues(alpha: 0.2)
                : BrandColors.forest.withValues(alpha: 0.2),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(
            statusIcon,
            size: 16,
            color: isDark ? BrandColors.nightForest : BrandColors.forest,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              statusText,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: () => _resumeSession(session),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('Resume'),
            style: FilledButton.styleFrom(
              backgroundColor:
                  isDark ? BrandColors.nightForest : BrandColors.forest,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.md,
                vertical: Spacing.sm,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, bool isDark, String error) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: Spacing.md),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: BrandColors.errorLight,
        borderRadius: Radii.badge,
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: BrandColors.error,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              error,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: BrandColors.error,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Get a short badge label from a model name
  /// e.g., "claude-opus-4-5-20250514" -> "Opus 4.5"
  String _getModelBadge(String model) {
    final lower = model.toLowerCase();
    if (lower.contains('opus')) {
      if (lower.contains('4-5') || lower.contains('4.5')) {
        return 'Opus 4.5';
      }
      return 'Opus';
    } else if (lower.contains('sonnet')) {
      if (lower.contains('4')) {
        return 'Sonnet 4';
      }
      return 'Sonnet';
    } else if (lower.contains('haiku')) {
      if (lower.contains('3-5') || lower.contains('3.5')) {
        return 'Haiku 3.5';
      }
      return 'Haiku';
    }
    // Fallback: try to extract something meaningful
    if (model.length > 15) {
      // Extract first meaningful part
      final parts = model.split('-');
      if (parts.length > 1) {
        return parts[1].substring(0, 1).toUpperCase() + parts[1].substring(1);
      }
    }
    return model;
  }

  /// Get the color associated with a model
  Color _getModelColor(String model) {
    final lower = model.toLowerCase();
    if (lower.contains('opus')) {
      return const Color(0xFF9333EA); // Purple for Opus
    } else if (lower.contains('sonnet')) {
      return const Color(0xFF3B82F6); // Blue for Sonnet
    } else if (lower.contains('haiku')) {
      return const Color(0xFF14B8A6); // Teal for Haiku
    }
    return BrandColors.forest; // Default
  }

  /// Get a short badge label from an agent name
  /// e.g., "Daily Orchestrator" -> "Orchestrator", "reflection" -> "Reflection"
  String _getAgentBadge(String agentName) {
    // For known agent types, return short names
    final lower = agentName.toLowerCase();
    if (lower.contains('orchestrator')) {
      return 'Orchestrator';
    } else if (lower.contains('reflection')) {
      return 'Reflection';
    } else if (lower.contains('vault')) {
      return 'Vault';
    }
    // For other agents, capitalize first letter of each word and truncate
    final words = agentName.split(RegExp(r'[-_\s]+'));
    if (words.length > 1) {
      // Return last significant word capitalized
      final lastWord = words.last;
      return lastWord.isNotEmpty
          ? '${lastWord[0].toUpperCase()}${lastWord.substring(1)}'
          : agentName;
    }
    // Single word - capitalize
    return agentName.isNotEmpty
        ? '${agentName[0].toUpperCase()}${agentName.substring(1)}'
        : agentName;
  }

  /// Show the unified session settings sheet
  void _showUnifiedSettings(BuildContext context) {
    final chatState = ref.read(chatMessagesProvider);
    if (chatState.sessionId == null) return;

    // Try to find the full session from the sessions list
    final sessionsAsync = ref.read(chatSessionsProvider);
    ChatSession? currentSession;
    sessionsAsync.whenData((sessions) {
      currentSession =
          sessions.where((s) => s.id == chatState.sessionId).firstOrNull;
    });

    final session = currentSession ??
        ChatSession(
          id: chatState.sessionId!,
          createdAt: DateTime.now(),
          title: chatState.sessionTitle,
          trustLevel: chatState.trustLevel,
        );

    UnifiedSessionSettings.show(
      context,
      session: session,
      model: chatState.model,
      workingDirectory: chatState.workingDirectory,
      promptMetadata: chatState.promptMetadata,
      selectedContexts: chatState.selectedContexts,
      onReloadClaudeMd: () {
        ref.read(chatMessagesProvider.notifier).markClaudeMdForReload();
      },
      onConfigSaved: () {
        ref.read(chatMessagesProvider.notifier).refreshSession();
        ref.invalidate(chatSessionsProvider);
      },
    );
  }

  /// Handle menu actions (archive, delete, refresh)
  Future<void> _handleMenuAction(String action, String sessionId) async {
    switch (action) {
      case 'refresh':
        ref.read(chatMessagesProvider.notifier).refreshSession();
        break;
      case 'archive':
        // Capture the provider function before navigating to avoid accessing
        // ref after the widget is disposed
        final archiveFunc = ref.read(archiveSessionProvider);
        if (mounted) {
          _navigateBackFromSession();
        }
        // Small delay to let the navigation complete before invalidating providers
        await Future.delayed(const Duration(milliseconds: 100));
        await archiveFunc(sessionId);
        break;
      case 'delete':
        final confirmed = await _confirmDeleteSession();
        if (confirmed && mounted) {
          // Capture the provider function before navigating
          final deleteFunc = ref.read(deleteSessionProvider);
          _navigateBackFromSession();
          await Future.delayed(const Duration(milliseconds: 100));
          await deleteFunc(sessionId);
        }
        break;
    }
  }

  /// Navigate back from the current session.
  ///
  /// In mobile mode (ChatScreen was pushed), pop the Navigator.
  /// In embedded mode (tablet/desktop), clear the session selection so
  /// ChatContentPanel shows the empty state — popping would remove the
  /// root ChatShell route and crash.
  void _navigateBackFromSession() {
    if (widget.embeddedMode) {
      ref.read(currentSessionIdProvider.notifier).state = null;
      ref.read(newChatModeProvider.notifier).state = false;
      ref.read(chatMessagesProvider.notifier).clearSession();
    } else {
      Navigator.of(context).pop();
    }
  }

  /// Show delete confirmation dialog
  Future<bool> _confirmDeleteSession() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete conversation?'),
        content: const Text(
          'This will permanently delete this conversation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: BrandColors.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Build the user question card when Claude asks a question
  Widget _buildUserQuestionCard(Map<String, dynamic> questionData) {
    final requestId = questionData['requestId'] as String? ?? '';
    final sessionId = questionData['sessionId'] as String? ?? '';
    final questionsJson = questionData['questions'] as List<dynamic>? ?? [];

    // Parse the questions
    final questions = questionsJson
        .map((q) => UserQuestion.fromJson(q as Map<String, dynamic>))
        .toList();

    if (questions.isEmpty) {
      return const SizedBox.shrink();
    }

    return UserQuestionCard(
      requestId: requestId,
      sessionId: sessionId,
      questions: questions,
      onAnswer: (answers) async {
        return await ref.read(chatMessagesProvider.notifier).answerQuestion(answers);
      },
      onDismiss: () {
        // Send empty answers to unblock the server-side Future, then clear UI
        ref.read(chatMessagesProvider.notifier).answerQuestion({});
        ref.read(chatMessagesProvider.notifier).dismissPendingQuestion();
      },
    );
  }

  /// Resume an archived session - unarchive and enable input
  Future<void> _resumeSession(ChatSession session) async {
    try {
      await ref.read(unarchiveSessionProvider)(session.id);
      // Only enable input on successful unarchive
      ref.read(chatMessagesProvider.notifier).enableSessionInput(session);
    } on AppError catch (e) {
      debugPrint('[ChatScreen] Failed to unarchive session: $e');
      if (mounted) showAppError(context, e);
      // Session stays in read-only state
    } catch (e) {
      debugPrint('[ChatScreen] Unexpected error unarchiving session: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resume session: $e')),
        );
      }
    }
  }
}

class _SuggestionChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _SuggestionChip({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

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

