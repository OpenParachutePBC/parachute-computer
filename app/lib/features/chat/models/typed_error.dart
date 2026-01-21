/// Error codes for programmatic handling.
///
/// These map to specific error scenarios and enable targeted recovery actions.
enum ErrorCode {
  // Authentication errors
  invalidApiKey,
  invalidCredentials,
  expiredToken,

  // Billing errors
  billingError,

  // Rate limiting
  rateLimited,

  // Service errors
  serviceError,
  serviceUnavailable,
  contextExceeded,

  // Network errors
  networkError,

  // MCP errors
  mcpConnectionFailed,
  mcpToolError,

  // Tool errors
  toolExecutionFailed,

  // Transcription errors
  transcriptionFailed,

  // Session errors
  sessionNotFound,
  sessionUnavailable,

  // Generic
  unknownError,
}

/// Extension to parse ErrorCode from string
extension ErrorCodeExtension on ErrorCode {
  String get value {
    switch (this) {
      case ErrorCode.invalidApiKey:
        return 'invalid_api_key';
      case ErrorCode.invalidCredentials:
        return 'invalid_credentials';
      case ErrorCode.expiredToken:
        return 'expired_token';
      case ErrorCode.billingError:
        return 'billing_error';
      case ErrorCode.rateLimited:
        return 'rate_limited';
      case ErrorCode.serviceError:
        return 'service_error';
      case ErrorCode.serviceUnavailable:
        return 'service_unavailable';
      case ErrorCode.contextExceeded:
        return 'context_exceeded';
      case ErrorCode.networkError:
        return 'network_error';
      case ErrorCode.mcpConnectionFailed:
        return 'mcp_connection_failed';
      case ErrorCode.mcpToolError:
        return 'mcp_tool_error';
      case ErrorCode.toolExecutionFailed:
        return 'tool_execution_failed';
      case ErrorCode.transcriptionFailed:
        return 'transcription_failed';
      case ErrorCode.sessionNotFound:
        return 'session_not_found';
      case ErrorCode.sessionUnavailable:
        return 'session_unavailable';
      case ErrorCode.unknownError:
        return 'unknown_error';
    }
  }

  static ErrorCode fromString(String? value) {
    switch (value) {
      case 'invalid_api_key':
        return ErrorCode.invalidApiKey;
      case 'invalid_credentials':
        return ErrorCode.invalidCredentials;
      case 'expired_token':
        return ErrorCode.expiredToken;
      case 'billing_error':
        return ErrorCode.billingError;
      case 'rate_limited':
        return ErrorCode.rateLimited;
      case 'service_error':
        return ErrorCode.serviceError;
      case 'service_unavailable':
        return ErrorCode.serviceUnavailable;
      case 'context_exceeded':
        return ErrorCode.contextExceeded;
      case 'network_error':
        return ErrorCode.networkError;
      case 'mcp_connection_failed':
        return ErrorCode.mcpConnectionFailed;
      case 'mcp_tool_error':
        return ErrorCode.mcpToolError;
      case 'tool_execution_failed':
        return ErrorCode.toolExecutionFailed;
      case 'transcription_failed':
        return ErrorCode.transcriptionFailed;
      case 'session_not_found':
        return ErrorCode.sessionNotFound;
      case 'session_unavailable':
        return ErrorCode.sessionUnavailable;
      default:
        return ErrorCode.unknownError;
    }
  }
}

/// Action types for error recovery
enum RecoveryActionType {
  retry,
  settings,
  reauth,
  dismiss,
  newSession,
}

/// Extension to parse RecoveryActionType from string
extension RecoveryActionTypeExtension on RecoveryActionType {
  String get value {
    switch (this) {
      case RecoveryActionType.retry:
        return 'retry';
      case RecoveryActionType.settings:
        return 'settings';
      case RecoveryActionType.reauth:
        return 'reauth';
      case RecoveryActionType.dismiss:
        return 'dismiss';
      case RecoveryActionType.newSession:
        return 'new_session';
    }
  }

  static RecoveryActionType fromString(String? value) {
    switch (value) {
      case 'retry':
        return RecoveryActionType.retry;
      case 'settings':
        return RecoveryActionType.settings;
      case 'reauth':
        return RecoveryActionType.reauth;
      case 'dismiss':
        return RecoveryActionType.dismiss;
      case 'new_session':
        return RecoveryActionType.newSession;
      default:
        return RecoveryActionType.dismiss;
    }
  }
}

/// A suggested recovery action for an error.
class RecoveryAction {
  /// Keyboard shortcut (single letter)
  final String key;

  /// Description of the action
  final String label;

  /// Action type for handling
  final RecoveryActionType action;

  const RecoveryAction({
    required this.key,
    required this.label,
    required this.action,
  });

  factory RecoveryAction.fromJson(Map<String, dynamic> json) {
    return RecoveryAction(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      action: RecoveryActionTypeExtension.fromString(json['action'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'action': action.value,
      };
}

/// A structured error with user-friendly info and recovery suggestions.
///
/// Provides richer error information than simple error strings, including:
/// - Error code for programmatic handling
/// - User-friendly title and message
/// - Suggested recovery actions with keyboard shortcuts
/// - Retry capability information
class TypedError {
  /// Error code for programmatic handling
  final ErrorCode code;

  /// User-friendly error title
  final String title;

  /// Detailed error message
  final String message;

  /// Suggested recovery actions
  final List<RecoveryAction> actions;

  /// Whether retry is possible
  final bool canRetry;

  /// Suggested retry delay in milliseconds
  final int? retryDelayMs;

  /// Original error message for debugging
  final String? originalError;

  /// Session ID if associated with a session
  final String? sessionId;

  const TypedError({
    required this.code,
    required this.title,
    required this.message,
    this.actions = const [],
    this.canRetry = false,
    this.retryDelayMs,
    this.originalError,
    this.sessionId,
  });

  factory TypedError.fromJson(Map<String, dynamic> json) {
    final actionsJson = json['actions'] as List<dynamic>? ?? [];
    return TypedError(
      code: ErrorCodeExtension.fromString(json['code'] as String?),
      title: json['title'] as String? ?? 'Error',
      message: json['message'] as String? ?? 'An error occurred',
      actions: actionsJson
          .map((a) => RecoveryAction.fromJson(a as Map<String, dynamic>))
          .toList(),
      canRetry: json['canRetry'] as bool? ?? false,
      retryDelayMs: json['retryDelayMs'] as int?,
      originalError: json['originalError'] as String?,
      sessionId: json['sessionId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'code': code.value,
        'title': title,
        'message': message,
        'actions': actions.map((a) => a.toJson()).toList(),
        'canRetry': canRetry,
        if (retryDelayMs != null) 'retryDelayMs': retryDelayMs,
        if (originalError != null) 'originalError': originalError,
        if (sessionId != null) 'sessionId': sessionId,
      };

  /// Whether this is a billing/auth error that blocks usage
  bool get isBillingError => code == ErrorCode.billingError ||
      code == ErrorCode.invalidApiKey ||
      code == ErrorCode.expiredToken;

  /// Whether this error can be automatically retried
  bool get canAutoRetry => canRetry && retryDelayMs != null;

  /// Get the primary recovery action (first in list)
  RecoveryAction? get primaryAction => actions.isNotEmpty ? actions.first : null;

  /// Check if a specific recovery action type is available
  bool hasAction(RecoveryActionType type) =>
      actions.any((a) => a.action == type);
}
