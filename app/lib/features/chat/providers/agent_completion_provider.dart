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
  final int unreadCount;
  final AgentCompletionEvent? latestEvent;

  const AgentCompletionState({
    this.unreadCount = 0,
    this.latestEvent,
  });

  AgentCompletionState copyWith({
    int? unreadCount,
    AgentCompletionEvent? latestEvent,
  }) {
    return AgentCompletionState(
      unreadCount: unreadCount ?? this.unreadCount,
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

    final currentSessionId = ref.read(currentSessionIdProvider);
    final isViewingSession = isOnChatTab && currentSessionId == sessionId;

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
      // App is backgrounded — fire OS notification
      _fireOsNotification(displayTitle, sessionId);
      // Also increment badge for when they return
      state = AgentCompletionState(
        unreadCount: state.unreadCount + 1,
        latestEvent: event,
      );
    } else if (!isOnChatTab) {
      // On a different tab — badge + toast
      state = AgentCompletionState(
        unreadCount: state.unreadCount + 1,
        latestEvent: event,
      );
    } else {
      // On chat tab but different session — toast only
      state = AgentCompletionState(
        unreadCount: state.unreadCount,
        latestEvent: event,
      );
    }
  }

  /// Clear unread count (called when user switches to Chat tab).
  void clearUnread() {
    if (state.unreadCount > 0) {
      state = AgentCompletionState(
        unreadCount: 0,
        latestEvent: state.latestEvent,
      );
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
