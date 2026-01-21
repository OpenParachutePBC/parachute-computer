import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/typed_error.dart';

/// Card widget for displaying typed errors with recovery actions.
///
/// Shows error details with actionable recovery buttons. On desktop,
/// keyboard shortcuts are available for quick recovery actions.
class ErrorRecoveryCard extends StatelessWidget {
  final TypedError error;
  final VoidCallback? onRetry;
  final VoidCallback? onSettings;
  final VoidCallback? onNewSession;
  final VoidCallback? onDismiss;

  const ErrorRecoveryCard({
    super.key,
    required this.error,
    this.onRetry,
    this.onSettings,
    this.onNewSession,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Determine error severity for styling
    final isAuthError = error.isBillingError;
    final isRetryable = error.canRetry;

    // Color based on severity
    final cardColor = isAuthError
        ? colorScheme.errorContainer.withValues(alpha: 0.3)
        : colorScheme.surfaceContainerHighest;
    final iconColor = isAuthError
        ? colorScheme.error
        : colorScheme.onSurfaceVariant;
    final titleColor = isAuthError
        ? colorScheme.error
        : colorScheme.onSurface;

    return KeyboardListener(
      focusNode: FocusNode(),
      autofocus: false,
      onKeyEvent: (event) => _handleKeyEvent(event, context),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: cardColor,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header with icon and title
              Row(
                children: [
                  Icon(
                    _getIconForError(error.code),
                    size: 24,
                    color: iconColor,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      error.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: titleColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (onDismiss != null)
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: onDismiss,
                      tooltip: 'Dismiss',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ],
              ),
              const SizedBox(height: 8),

              // Error message
              Text(
                error.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),

              // Retry delay hint
              if (isRetryable && error.retryDelayMs != null) ...[
                const SizedBox(height: 4),
                Text(
                  'Will retry in ${(error.retryDelayMs! / 1000).round()} seconds...',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],

              // Recovery actions
              if (error.actions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: error.actions.map((action) {
                    return _buildActionButton(context, action);
                  }).toList(),
                ),
              ],

              // Original error details (collapsed by default)
              if (error.originalError != null) ...[
                const SizedBox(height: 12),
                _buildDetailsExpander(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton(BuildContext context, RecoveryAction action) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final callback = _getCallbackForAction(action.action);
    final isEnabled = callback != null;

    // Primary action gets filled style
    final isPrimary = action == error.primaryAction;

    return isPrimary
        ? FilledButton.icon(
            onPressed: isEnabled ? callback : null,
            icon: Icon(_getIconForAction(action.action), size: 18),
            label: Text(_buildActionLabel(action)),
          )
        : OutlinedButton.icon(
            onPressed: isEnabled ? callback : null,
            icon: Icon(_getIconForAction(action.action), size: 18),
            label: Text(_buildActionLabel(action)),
            style: OutlinedButton.styleFrom(
              foregroundColor: colorScheme.onSurfaceVariant,
            ),
          );
  }

  String _buildActionLabel(RecoveryAction action) {
    // Include keyboard shortcut hint on desktop
    return '${action.label} (${action.key.toUpperCase()})';
  }

  Widget _buildDetailsExpander(BuildContext context) {
    final theme = Theme.of(context);

    return ExpansionTile(
      title: Text(
        'Technical Details',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(top: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            error.originalError ?? '',
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  void _handleKeyEvent(KeyEvent event, BuildContext context) {
    if (event is! KeyDownEvent) return;

    final key = event.character?.toLowerCase();
    if (key == null) return;

    for (final action in error.actions) {
      if (action.key.toLowerCase() == key) {
        final callback = _getCallbackForAction(action.action);
        callback?.call();
        break;
      }
    }
  }

  VoidCallback? _getCallbackForAction(RecoveryActionType type) {
    switch (type) {
      case RecoveryActionType.retry:
        return onRetry;
      case RecoveryActionType.settings:
        return onSettings;
      case RecoveryActionType.reauth:
        return onSettings; // Reauth typically goes to settings
      case RecoveryActionType.newSession:
        return onNewSession;
      case RecoveryActionType.dismiss:
        return onDismiss;
    }
  }

  IconData _getIconForError(ErrorCode code) {
    switch (code) {
      case ErrorCode.invalidApiKey:
      case ErrorCode.invalidCredentials:
      case ErrorCode.expiredToken:
        return Icons.key_off;
      case ErrorCode.billingError:
        return Icons.payment;
      case ErrorCode.rateLimited:
        return Icons.speed;
      case ErrorCode.serviceError:
      case ErrorCode.serviceUnavailable:
        return Icons.cloud_off;
      case ErrorCode.contextExceeded:
        return Icons.data_usage;
      case ErrorCode.networkError:
        return Icons.wifi_off;
      case ErrorCode.mcpConnectionFailed:
      case ErrorCode.mcpToolError:
        return Icons.extension_off;
      case ErrorCode.toolExecutionFailed:
        return Icons.build_circle;
      case ErrorCode.transcriptionFailed:
        return Icons.mic_off;
      case ErrorCode.sessionNotFound:
      case ErrorCode.sessionUnavailable:
        return Icons.history_toggle_off;
      case ErrorCode.unknownError:
        return Icons.error_outline;
    }
  }

  IconData _getIconForAction(RecoveryActionType type) {
    switch (type) {
      case RecoveryActionType.retry:
        return Icons.refresh;
      case RecoveryActionType.settings:
        return Icons.settings;
      case RecoveryActionType.reauth:
        return Icons.login;
      case RecoveryActionType.newSession:
        return Icons.add_comment;
      case RecoveryActionType.dismiss:
        return Icons.close;
    }
  }
}

/// Simplified error display for inline use (e.g., in message stream).
class InlineErrorBadge extends StatelessWidget {
  final TypedError error;
  final VoidCallback? onTap;

  const InlineErrorBadge({
    super.key,
    required this.error,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Material(
      color: colorScheme.errorContainer.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 16,
                color: colorScheme.error,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  error.title,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (error.canRetry) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.refresh,
                  size: 14,
                  color: colorScheme.error.withValues(alpha: 0.7),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
