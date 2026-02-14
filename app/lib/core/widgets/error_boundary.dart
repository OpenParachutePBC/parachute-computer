import 'package:flutter/material.dart';
import '../services/logging_service.dart';

/// Error boundary widget that catches errors and shows fallback UI
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

  @override
  void initState() {
    super.initState();
  }

  void _handleError(Object error, StackTrace stack) {
    setState(() {
      _error = error;
      _stack = stack;
    });
    widget.onError?.call(error, stack);
    logger.error('ErrorBoundary', 'Caught error', error: error, stackTrace: stack);
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
    return widget.child;
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
          logger.error(screenName!, 'Screen error', error: error, stackTrace: stack);
        }
      },
      child: child,
    );
  }
}
