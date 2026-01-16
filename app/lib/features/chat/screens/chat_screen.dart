import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/widgets/error_boundary.dart';
import 'package:parachute/core/services/logging_service.dart';
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
import '../widgets/session_info_sheet.dart';
import '../widgets/context_settings_sheet.dart';
import '../widgets/curator_session_viewer_sheet.dart';
import '../widgets/user_question_card.dart';
import '../../settings/screens/settings_screen.dart';

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

  const ChatScreen({
    super.key,
    this.initialMessage,
    this.initialContext,
    this.autoRun = false,
    this.autoRunMessage,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final ScrollController _scrollController = ScrollController();
  String? _pendingInitialContext;
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
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: Motion.standard,
          curve: Motion.settling,
        );
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
        );

    // Clear pending context after first message
    _pendingInitialContext = null;

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
      child: Scaffold(
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
          title: _buildTitle(context, isDark, currentSessionId),
          actions: [
            // Refresh button (for when streaming reconnection isn't working)
            if (chatState.sessionId != null && !chatState.isStreaming)
              IconButton(
                onPressed: () {
                  ref.read(chatMessagesProvider.notifier).refreshSession();
                },
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'Refresh session',
              ),
            // Working directory indicator/picker
            if (chatState.workingDirectory != null)
              Tooltip(
                message: chatState.workingDirectory!,
                child: TextButton.icon(
                  // Only allow changing before first message
                  onPressed: chatState.messages.isEmpty ? _showDirectoryPicker : null,
                  icon: Icon(
                    Icons.folder_outlined,
                    size: 18,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                  label: Text(
                    chatState.workingDirectory!.split('/').last,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? BrandColors.nightForest : BrandColors.forest,
                    ),
                  ),
                ),
              )
            else if (chatState.messages.isEmpty)
              // Only show picker button for new chats without a directory set
              IconButton(
                onPressed: _showDirectoryPicker,
                icon: const Icon(Icons.folder_outlined),
                tooltip: 'Set working directory',
              ),
            // Model indicator (shows which model is being used)
            if (chatState.model != null)
              Tooltip(
                message: chatState.model!,
                child: Container(
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
                  ),
                ),
              ),
            // Context settings button (toggle context files, reload CLAUDE.md)
            IconButton(
              onPressed: () => _showContextSettingsSheet(context),
              icon: Icon(
                Icons.tune,
                size: 20,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
              ),
              tooltip: 'Context settings',
            ),
            // Session info button (shows prompt metadata and session details)
            if (chatState.sessionId != null || chatState.promptMetadata != null)
              IconButton(
                onPressed: () => _showSessionInfoSheet(context),
                icon: Icon(
                  Icons.info_outline,
                  size: 20,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
                ),
                tooltip: 'Session info',
              ),
            // Curator activity button (shows background curator status)
            if (chatState.sessionId != null)
              IconButton(
                onPressed: () => _showCuratorSheet(context),
                icon: Icon(
                  Icons.auto_fix_high,
                  size: 20,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.charcoal,
                ),
                tooltip: 'Curator activity',
              ),
            // More actions menu (archive, delete)
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
      body: Column(
        children: [
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
                        // Increase cache extent to pre-build items off-screen
                        // This reduces jank when scrolling by having more items ready
                        cacheExtent: 500,
                        // Let MessageBubble handle its own RepaintBoundary
                        addRepaintBoundaries: false,
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

          // Input field - disabled when viewing archived sessions (use Resume button)
          ChatInput(
            onSend: _handleSend,
            onStop: _handleStop,
            enabled: !chatState.isStreaming && !chatState.isViewingArchived,
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
    ),
    );
  }

  Widget _buildTitle(BuildContext context, bool isDark, String? sessionId) {
    final chatState = ref.watch(chatMessagesProvider);
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
          ],
        ),
      ),
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

  /// Show the session info sheet with prompt metadata
  void _showSessionInfoSheet(BuildContext context) {
    final chatState = ref.read(chatMessagesProvider);
    SessionInfoSheet.show(
      context,
      sessionId: chatState.sessionId,
      model: chatState.model,
      workingDirectory: chatState.workingDirectory,
      promptMetadata: chatState.promptMetadata,
      selectedContexts: chatState.selectedContexts,
    );
  }

  /// Show context settings sheet for mid-session context management
  void _showContextSettingsSheet(BuildContext context) {
    final chatState = ref.read(chatMessagesProvider);
    ContextSettingsSheet.show(
      context,
      workingDirectory: chatState.workingDirectory,
      promptMetadata: chatState.promptMetadata,
      selectedContexts: chatState.selectedContexts,
      onContextsChanged: (contexts) {
        ref.read(chatMessagesProvider.notifier).setSelectedContexts(contexts);
      },
      onReloadClaudeMd: () {
        ref.read(chatMessagesProvider.notifier).markClaudeMdForReload();
      },
    );
  }

  /// Show curator session viewer sheet
  void _showCuratorSheet(BuildContext context) {
    final chatState = ref.read(chatMessagesProvider);
    if (chatState.sessionId != null) {
      CuratorSessionViewerSheet.show(context, chatState.sessionId!);
    }
  }

  /// Handle menu actions (archive, delete)
  Future<void> _handleMenuAction(String action, String sessionId) async {
    switch (action) {
      case 'archive':
        // Capture the provider function before navigating to avoid accessing
        // ref after the widget is disposed
        final archiveFunc = ref.read(archiveSessionProvider);
        if (mounted) {
          Navigator.of(context).pop(); // Go back to hub
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
          Navigator.of(context).pop(); // Go back to hub
          await Future.delayed(const Duration(milliseconds: 100));
          await deleteFunc(sessionId);
        }
        break;
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
    );
  }

  /// Resume an archived session - unarchive and enable input
  Future<void> _resumeSession(ChatSession session) async {
    // Unarchive the session on the server
    try {
      await ref.read(unarchiveSessionProvider)(session.id);
    } catch (e) {
      debugPrint('[ChatScreen] Failed to unarchive session: $e');
      // Continue anyway - the local state change is more important
    }

    // Clear the "viewing archived" state so the input becomes enabled
    // The user can now type and send messages to resume the conversation
    ref.read(chatMessagesProvider.notifier).enableSessionInput(session);

    // Refresh sessions list to reflect the unarchived state
    ref.invalidate(chatSessionsProvider);
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

