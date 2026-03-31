import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/features/chat/providers/chat_session_providers.dart';
import 'package:parachute/features/daily/recorder/services/notification_service.dart';

// ============================================================
// App Lifecycle Tracking
// ============================================================

/// Tracks whether the app is in the foreground or background.
/// Updated from _TabShellState.didChangeAppLifecycleState().
final appLifecycleProvider = StateProvider<AppLifecycleState>((ref) {
  return AppLifecycleState.resumed; // Assume foreground on startup
});

// ============================================================
// Agent Completion Events
// ============================================================

/// A single agent completion event for toast display.
class AgentCompletionEvent {
  final String sessionId;
  final String title;
  final DateTime completedAt;

  const AgentCompletionEvent({
    required this.sessionId,
    required this.title,
    required this.completedAt,
  });
}

/// State for agent completion notifications.
class AgentCompletionState {
  final Set<String> unreadSessionIds;
  final AgentCompletionEvent? latestEvent;

  const AgentCompletionState({
    this.unreadSessionIds = const {},
    this.latestEvent,
  });

  AgentCompletionState copyWith({
    Set<String>? unreadSessionIds,
    AgentCompletionEvent? latestEvent,
  }) {
    return AgentCompletionState(
      unreadSessionIds: unreadSessionIds ?? this.unreadSessionIds,
      latestEvent: latestEvent ?? this.latestEvent,
    );
  }
}

/// Centralized notifier for agent completion notifications.
///
/// Receives completion events from DoneEvent handlers and decides which
/// surface(s) to fire based on app state:
/// - App backgrounded → OS notification
/// - On different tab → increment badge + show toast
/// - On chat tab, different session → show toast only
/// - Viewing that session → nothing
class AgentCompletionNotifier extends Notifier<AgentCompletionState> {
  @override
  AgentCompletionState build() {
    return const AgentCompletionState();
  }

  /// Called when an agent finishes responding.
  void onCompleted(String sessionId, String? title) {
    final displayTitle = (title != null && title.isNotEmpty) ? title : 'Chat';

    // Determine app state
    final lifecycle = ref.read(appLifecycleProvider);
    final isBackgrounded = lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.inactive ||
        lifecycle == AppLifecycleState.detached;

    final currentTab = ref.read(currentTabIndexProvider);
    final visibleTabs = ref.read(visibleTabsProvider);
    final isOnChatTab = currentTab < visibleTabs.length &&
        visibleTabs[currentTab] == AppTab.chat;

    final activeViewSessionId = ref.read(activeViewSessionIdProvider);
    final isViewingSession = isOnChatTab && activeViewSessionId == sessionId;

    debugPrint('[AgentCompletion] onCompleted: session=$sessionId, '
        'title="$displayTitle", backgrounded=$isBackgrounded, '
        'onChatTab=$isOnChatTab, viewingSession=$isViewingSession');

    // If viewing the completed session, no notification needed
    if (isViewingSession && !isBackgrounded) {
      return;
    }

    final event = AgentCompletionEvent(
      sessionId: sessionId,
      title: displayTitle,
      completedAt: DateTime.now(),
    );

    if (isBackgrounded) {
      _fireOsNotification(displayTitle, sessionId);
    }

    // Mark unread + set latest event (triggers toast via listener in main.dart)
    state = state.copyWith(
      unreadSessionIds: {...state.unreadSessionIds, sessionId},
      latestEvent: event,
    );
  }

  /// Mark a specific session as read (called when user opens that session).
  void markRead(String sessionId) {
    if (state.unreadSessionIds.contains(sessionId)) {
      final updated = Set<String>.of(state.unreadSessionIds)..remove(sessionId);
      state = state.copyWith(unreadSessionIds: updated);
    }
  }

  /// Fire an Android/iOS local notification.
  void _fireOsNotification(String title, String sessionId) {
    final notificationService = NotificationService();
    notificationService.showAgentCompleted(title, sessionId: sessionId);
  }
}

/// Provider for agent completion notifications.
final agentCompletionProvider =
    NotifierProvider<AgentCompletionNotifier, AgentCompletionState>(
  AgentCompletionNotifier.new,
);

// ============================================================
// Agent Question Events
// ============================================================

/// A single agent question event for toast/notification display.
class AgentQuestionEvent {
  final String sessionId;
  final String title;
  final DateTime askedAt;

  const AgentQuestionEvent({
    required this.sessionId,
    required this.title,
    required this.askedAt,
  });
}

/// Centralized notifier for agent question notifications.
///
/// Fires when AskUserQuestion arrives and the user isn't looking at the chat:
/// - Viewing that session → auto-scroll only (handled by chat_screen listener)
/// - Different session/tab → show toast "Claude has a question"
/// - App backgrounded → OS notification
class AgentQuestionNotifier extends Notifier<AgentQuestionEvent?> {
  @override
  AgentQuestionEvent? build() => null;

  /// Called when an AskUserQuestion event arrives during streaming.
  void onQuestion(String sessionId, String? title) {
    final displayTitle = (title != null && title.isNotEmpty) ? title : 'Chat';

    // Determine app state
    final lifecycle = ref.read(appLifecycleProvider);
    final isBackgrounded = lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.inactive ||
        lifecycle == AppLifecycleState.detached;

    final currentTab = ref.read(currentTabIndexProvider);
    final visibleTabs = ref.read(visibleTabsProvider);
    final isOnChatTab = currentTab < visibleTabs.length &&
        visibleTabs[currentTab] == AppTab.chat;

    final activeViewSessionId = ref.read(activeViewSessionIdProvider);
    final isViewingSession = isOnChatTab && activeViewSessionId == sessionId;

    debugPrint('[AgentQuestion] onQuestion: session=$sessionId, '
        'title="$displayTitle", backgrounded=$isBackgrounded, '
        'onChatTab=$isOnChatTab, viewingSession=$isViewingSession');

    final event = AgentQuestionEvent(
      sessionId: sessionId,
      title: displayTitle,
      askedAt: DateTime.now(),
    );

    if (isBackgrounded) {
      final notificationService = NotificationService();
      notificationService.showAgentQuestion(displayTitle, sessionId: sessionId);
    }

    // Always update state — the toast listener and chat_screen auto-scroll
    // listener will check whether to fire based on the event.
    state = event;
  }
}

/// Provider for agent question notifications.
final agentQuestionProvider =
    NotifierProvider<AgentQuestionNotifier, AgentQuestionEvent?>(
  AgentQuestionNotifier.new,
);
