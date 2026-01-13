import 'package:flutter/foundation.dart';
import 'logging_service.dart';

/// Performance measurement service
/// Stub implementation - full version pending migration
class PerformanceService {
  static final PerformanceService _instance = PerformanceService._internal();
  factory PerformanceService() => _instance;
  PerformanceService._internal();

  /// Start a trace (alias)
  PerformanceTrace trace(String name, {Map<String, dynamic>? metadata}) {
    return startTrace(name, metadata: metadata);
  }

  /// Start a trace
  PerformanceTrace startTrace(String name, {Map<String, dynamic>? metadata}) {
    return PerformanceTrace.start(name, metadata: metadata);
  }

  /// Measure async operation
  Future<T> measureAsync<T>(String name, Future<T> Function() operation) async {
    final trace = startTrace(name);
    try {
      return await operation();
    } finally {
      trace.end();
    }
  }
}

/// Global performance service instance
final perf = PerformanceService();
