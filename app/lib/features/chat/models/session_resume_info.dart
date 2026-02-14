/// Information about how a session was resumed
///
/// The backend tracks whether a session was resumed via the SDK's
/// native session resumption, via context injection (re-sending prior
/// messages), or started fresh.
class SessionResumeInfo {
  /// How the session was resumed
  /// - 'sdk_resume': SDK native session resumption (fastest)
  /// - 'context_injection': Prior messages injected into new session
  /// - 'new': Fresh session with no prior context
  final String method;

  /// Whether the SDK session ID was found and valid
  final bool sdkSessionValid;

  /// Whether we attempted to resume via SDK
  final bool sdkResumeAttempted;

  /// Whether SDK resume was attempted but failed
  final bool sdkResumeFailed;

  /// Whether context was injected from prior messages
  final bool contextInjected;

  /// Number of prior messages that were injected
  final int messagesInjected;

  /// Estimated token count of injected context
  final int tokensEstimate;

  /// Number of messages in the session before this turn
  final int previousMessageCount;

  /// Whether session was loaded from disk
  final bool loadedFromDisk;

  /// Whether session was in memory cache
  final bool cacheHit;

  const SessionResumeInfo({
    required this.method,
    this.sdkSessionValid = false,
    this.sdkResumeAttempted = false,
    this.sdkResumeFailed = false,
    this.contextInjected = false,
    this.messagesInjected = 0,
    this.tokensEstimate = 0,
    this.previousMessageCount = 0,
    this.loadedFromDisk = false,
    this.cacheHit = false,
  });

  factory SessionResumeInfo.fromJson(Map<String, dynamic> json) {
    return SessionResumeInfo(
      method: json['method'] as String? ?? 'unknown',
      sdkSessionValid: json['sdkSessionValid'] as bool? ?? false,
      sdkResumeAttempted: json['sdkResumeAttempted'] as bool? ?? false,
      sdkResumeFailed: json['sdkResumeFailed'] as bool? ?? false,
      contextInjected: json['contextInjected'] as bool? ?? false,
      messagesInjected: json['messagesInjected'] as int? ?? 0,
      tokensEstimate: json['tokensEstimate'] as int? ?? 0,
      previousMessageCount: json['previousMessageCount'] as int? ?? 0,
      loadedFromDisk: json['loadedFromDisk'] as bool? ?? false,
      cacheHit: json['cacheHit'] as bool? ?? false,
    );
  }

  /// Whether this session was continued from prior context
  /// (either SDK resume or context injection)
  bool get wasContinued => method == 'sdk_resume' || method == 'context_injection';

  /// Whether SDK resume failed and we fell back to context injection
  bool get usedFallback => sdkResumeFailed && contextInjected;

  /// Whether this is a completely new session with no prior context
  bool get isNew => method == 'new';

  /// Human-readable description of how the session was resumed
  String get description {
    switch (method) {
      case 'sdk_resume':
        return 'Session resumed';
      case 'context_injection':
        final msgCount = messagesInjected > 0 ? ' ($messagesInjected messages)' : '';
        return 'Context rebuilt$msgCount';
      case 'new':
        return 'New session';
      default:
        return 'Unknown';
    }
  }

  /// Short status text for display
  String get statusText {
    switch (method) {
      case 'sdk_resume':
        return 'Resumed';
      case 'context_injection':
        if (sdkResumeFailed) {
          return 'Rebuilt';
        }
        return 'Context loaded';
      case 'new':
        return 'New';
      default:
        return '';
    }
  }

  @override
  String toString() {
    return 'SessionResumeInfo(method: $method, sdkSessionValid: $sdkSessionValid, '
        'sdkResumeFailed: $sdkResumeFailed, contextInjected: $contextInjected, '
        'messagesInjected: $messagesInjected)';
  }
}
