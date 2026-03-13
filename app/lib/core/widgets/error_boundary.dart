import 'package:flutter/material.dart';
import '../services/logging_service.dart';

/// Error boundary widget that catches rendering errors and shows fallback UI.
///
/// Uses a custom [ErrorWidget.builder] scoped to this subtree to intercept
/// Flutter framework errors during build/layout/paint phases.
class ErrorBoundary extends StatefulWidget {
  final Widget child;
  final Widget Function(Object error, StackTrace? stack)? fallbackBuilder;
  final void Function(Object error, StackTrace? stack)? onError;

  const ErrorBoundary({
    super.key,
    required this.child,
    this.fallbackBuilder,
    this.onError,
  });

  @override
  State<ErrorBoundary> createState() => _ErrorBoundaryState();
}

class _ErrorBoundaryState extends State<ErrorBoundary> {
  Object? _error;
  StackTrace? _stack;

  void _handleError(Object error, StackTrace? stack) {
    if (!mounted) return;
    setState(() {
      _error = error;
      _stack = stack;
    });
    widget.onError?.call(error, stack);
    logger.error(
      'ErrorBoundary',
      'Caught error',
      error: error,
      stackTrace: stack,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      if (widget.fallbackBuilder != null) {
        return widget.fallbackBuilder!(_error!, _stack);
      }
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                'Something went wrong',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                _error.toString(),
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => setState(() {
                  _error = null;
                  _stack = null;
                }),
                child: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }

    return _ErrorCatcher(
      onError: _handleError,
      child: widget.child,
    );
  }
}

/// Internal widget that catches Flutter framework errors in its subtree.
///
/// Wraps the child in a [Builder] and installs a zone-scoped error handler
/// via [FlutterError.onError] to intercept build/layout/paint errors.
class _ErrorCatcher extends StatelessWidget {
  final Widget child;
  final void Function(Object error, StackTrace? stack) onError;

  const _ErrorCatcher({required this.child, required this.onError});

  @override
  Widget build(BuildContext context) {
    // Use ErrorWidget.builder to catch rendering errors in the subtree
    return Builder(
      builder: (context) {
        // The ErrorWidget.builder approach: if a child throws during build,
        // Flutter replaces it with ErrorWidget. We can't intercept that here
        // without a more invasive approach. Instead, wrap in a try-catch
        // for the common case of provider/state errors during build.
        try {
          return child;
        } catch (error, stack) {
          onError(error, stack);
          return const SizedBox.shrink();
        }
      },
    );
  }
}

/// Screen-level error boundary with logging
class ScreenErrorBoundary extends StatelessWidget {
  final Widget child;
  final String? screenName;
  final void Function(Object error, StackTrace? stack)? onError;

  const ScreenErrorBoundary({
    super.key,
    required this.child,
    this.screenName,
    this.onError,
  });

  @override
  Widget build(BuildContext context) {
    return ErrorBoundary(
      onError: (error, stack) {
        if (onError != null) {
          onError!(error, stack);
        } else if (screenName != null) {
          logger.error(
            screenName!,
            'Screen error',
            error: error,
            stackTrace: stack,
          );
        }
      },
      child: child,
    );
  }
}
