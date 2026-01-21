import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Provider for the DeepLinkService singleton
final deepLinkServiceProvider = Provider<DeepLinkService>((ref) {
  final service = DeepLinkService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Stream provider for deep link events
final deepLinkStreamProvider = StreamProvider<DeepLinkTarget>((ref) {
  final service = ref.watch(deepLinkServiceProvider);
  return service.deepLinks;
});

/// Provider for pending deep link navigation data.
///
/// When a deep link is received, this holds the target until the relevant
/// screen consumes it. Screens should read and clear this in their initState.
final pendingDeepLinkProvider = StateProvider<DeepLinkTarget?>((ref) => null);

/// Represents a parsed deep link target.
///
/// Deep links follow the pattern:
/// - `parachute://daily` - Open Daily tab
/// - `parachute://daily/2025-01-19` - Open specific date
/// - `parachute://daily/entry/para:abc123` - Jump to specific entry
/// - `parachute://chat` - Open Chat tab
/// - `parachute://chat/{session_id}` - Open specific session
/// - `parachute://chat/{session_id}?message=5` - Open session at message index
/// - `parachute://chat/new` - Start new chat
/// - `parachute://chat/new?context=projects/parachute` - New chat with context folder
/// - `parachute://chat/new?prompt=Help%20me&send=true` - New chat with auto-send prompt
/// - `parachute://vault` - Open Vault tab
/// - `parachute://vault/projects/parachute` - Open specific path
/// - `parachute://settings` - Open settings
/// - `parachute://action/skill-name` - Invoke a skill
class DeepLinkTarget {
  /// The tab to navigate to (daily, chat, vault, settings)
  final String? tab;

  /// For compound navigation (e.g., chat/session123)
  final String? path;

  /// Action to perform (e.g., new, skill)
  final String? action;

  /// Query parameters
  final Map<String, String> params;

  const DeepLinkTarget({
    this.tab,
    this.path,
    this.action,
    this.params = const {},
  });

  /// Whether this is a navigation to a specific tab
  bool get isTabNavigation => tab != null;

  /// Whether this is an action (not just navigation)
  bool get isAction => action != null;

  /// Get session ID from chat paths
  String? get sessionId {
    if (tab == 'chat' && path != null && path != 'new') {
      return path;
    }
    return null;
  }

  /// Get date from daily paths (e.g., "2025-01-19")
  String? get date {
    if (tab == 'daily' && path != null && !path!.startsWith('entry/')) {
      return path;
    }
    return null;
  }

  /// Get entry ID from daily paths (e.g., "para:abc123")
  String? get entryId {
    if (tab == 'daily' && path != null && path!.startsWith('entry/')) {
      return path!.substring(6); // Remove "entry/" prefix
    }
    return null;
  }

  /// Get message index for scrolling to specific message in chat
  int? get messageIndex {
    final msg = params['message'];
    return msg != null ? int.tryParse(msg) : null;
  }

  /// Get initial prompt for new chats (pre-fills input)
  String? get prompt => params['prompt'];

  /// Get context folder for new chats (relative to vault)
  String? get context => params['context'];

  /// Whether to send the prompt immediately (default: false)
  bool get autoSend => params['send'] == 'true';

  /// Whether this is a "new chat" deep link
  bool get isNewChat => tab == 'chat' && action == 'new';

  @override
  String toString() =>
      'DeepLinkTarget(tab: $tab, path: $path, action: $action, params: $params)';
}

/// Service for handling deep links to the app.
///
/// Supports the `parachute://` URL scheme for navigation and actions.
class DeepLinkService {
  /// Stream controller for deep link events
  final _deepLinkController = StreamController<DeepLinkTarget>.broadcast();

  /// Stream of deep link events for listeners to react to
  Stream<DeepLinkTarget> get deepLinks => _deepLinkController.stream;

  /// The last received deep link (for cold start handling)
  DeepLinkTarget? _initialLink;

  /// Get the initial deep link that launched the app (for cold start)
  DeepLinkTarget? get initialLink => _initialLink;

  /// App links instance for platform integration
  final _appLinks = AppLinks();

  /// Subscription to incoming links
  StreamSubscription<Uri>? _linkSubscription;

  /// Whether the service has been initialized
  bool _initialized = false;

  /// Initialize the deep link service.
  ///
  /// Call this once during app startup. Handles both:
  /// - Cold start: App launched via deep link
  /// - Warm start: App already running, receives deep link
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      // Check for initial link (cold start)
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        setInitialLink(initialUri.toString());
        // Also emit to stream so listeners can react
        handleDeepLink(initialUri.toString());
      }

      // Listen for incoming links (warm start)
      _linkSubscription = _appLinks.uriLinkStream.listen(
        (uri) {
          debugPrint('[DeepLinkService] Received link: $uri');
          handleDeepLink(uri.toString());
        },
        onError: (error) {
          debugPrint('[DeepLinkService] Link stream error: $error');
        },
      );

      debugPrint('[DeepLinkService] Initialized');
    } catch (e) {
      debugPrint('[DeepLinkService] Initialization error: $e');
    }
  }

  /// Parse a deep link URL into a structured target.
  ///
  /// Returns null if the URL is not a valid parachute:// link.
  DeepLinkTarget? parseDeepLink(String url) {
    try {
      final uri = Uri.parse(url);

      // Validate scheme
      if (uri.scheme != 'parachute') {
        return null;
      }

      // The host is the first path segment
      // e.g., parachute://daily/2025-01-19 → host='daily', path='/2025-01-19'
      final host = uri.host;
      final pathSegments =
          uri.pathSegments.where((s) => s.isNotEmpty).toList();

      // Parse query parameters
      final params = Map<String, String>.from(uri.queryParameters);

      // Handle different routes
      switch (host) {
        case 'daily':
          return DeepLinkTarget(
            tab: 'daily',
            path: pathSegments.isNotEmpty ? pathSegments.join('/') : null,
            params: params,
          );

        case 'chat':
          return DeepLinkTarget(
            tab: 'chat',
            path: pathSegments.isNotEmpty ? pathSegments.join('/') : null,
            action: pathSegments.firstOrNull == 'new' ? 'new' : null,
            params: params,
          );

        case 'vault':
          return DeepLinkTarget(
            tab: 'vault',
            path: pathSegments.isNotEmpty ? pathSegments.join('/') : null,
            params: params,
          );

        case 'settings':
          return DeepLinkTarget(
            tab: 'settings',
            path: pathSegments.isNotEmpty ? pathSegments.join('/') : null,
            params: params,
          );

        case 'action':
          // parachute://action/skill-name
          return DeepLinkTarget(
            action: pathSegments.isNotEmpty ? pathSegments.first : null,
            path:
                pathSegments.length > 1 ? pathSegments.sublist(1).join('/') : null,
            params: params,
          );

        default:
          debugPrint('[DeepLinkService] Unknown host: $host');
          return null;
      }
    } catch (e) {
      debugPrint('[DeepLinkService] Failed to parse deep link: $e');
      return null;
    }
  }

  /// Handle an incoming deep link URL.
  ///
  /// Parses the URL and broadcasts to listeners.
  void handleDeepLink(String url) {
    final target = parseDeepLink(url);
    if (target != null) {
      debugPrint('[DeepLinkService] Handling deep link: $target');
      _deepLinkController.add(target);
    }
  }

  /// Set the initial deep link (from cold start).
  void setInitialLink(String? url) {
    if (url != null) {
      _initialLink = parseDeepLink(url);
      if (_initialLink != null) {
        debugPrint('[DeepLinkService] Initial deep link: $_initialLink');
      }
    }
  }

  /// Build a deep link URL for a specific target.
  ///
  /// Utility for creating shareable links.
  static String buildUrl({
    required String tab,
    String? path,
    Map<String, String>? params,
  }) {
    final buffer = StringBuffer('parachute://$tab');
    if (path != null) {
      buffer.write('/$path');
    }
    if (params != null && params.isNotEmpty) {
      buffer.write('?');
      buffer.write(params.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&'));
    }
    return buffer.toString();
  }

  /// Build a deep link for a specific chat session.
  static String chatSessionUrl(String sessionId, {int? messageIndex}) =>
      buildUrl(
        tab: 'chat',
        path: sessionId,
        params: {
          if (messageIndex != null) 'message': messageIndex.toString(),
        },
      );

  /// Build a deep link for a new chat with optional context and prompt.
  ///
  /// - [prompt]: Pre-fills the input field
  /// - [context]: Context folder relative to vault (e.g., "projects/parachute")
  /// - [autoSend]: If true, sends the prompt immediately (default: false)
  static String newChatUrl({
    String? prompt,
    String? context,
    bool autoSend = false,
  }) =>
      buildUrl(
        tab: 'chat',
        path: 'new',
        params: {
          if (prompt != null) 'prompt': prompt,
          if (context != null) 'context': context,
          if (autoSend) 'send': 'true',
        },
      );

  /// Build a deep link for a specific journal date.
  static String dailyDateUrl(DateTime date) {
    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return buildUrl(tab: 'daily', path: dateStr);
  }

  /// Build a deep link for a specific journal entry.
  static String dailyEntryUrl(String entryId) =>
      buildUrl(tab: 'daily', path: 'entry/$entryId');

  /// Dispose of resources.
  void dispose() {
    _linkSubscription?.cancel();
    _deepLinkController.close();
  }
}
