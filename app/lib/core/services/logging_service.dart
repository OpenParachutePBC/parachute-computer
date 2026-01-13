import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Log level enumeration
enum LogLevel {
  debug(0, 'DEBUG'),
  info(1, 'INFO'),
  warning(2, 'WARN'),
  error(3, 'ERROR');

  final int value;
  final String label;

  const LogLevel(this.value, this.label);
}

/// A single log entry with timestamp and metadata
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String tag;
  final String message;
  final Map<String, dynamic>? data;
  final Object? error;
  final StackTrace? stackTrace;

  LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
    this.data,
    this.error,
    this.stackTrace,
  });

  String get formatted {
    final levelStr = level.label.padRight(5);
    final timeStr = timestamp.toIso8601String().substring(11, 23); // HH:mm:ss.SSS
    final dataStr = data != null ? ' $data' : '';
    final errorStr = error != null ? '\n  Error: $error' : '';
    final stackStr = stackTrace != null ? '\n  Stack: $stackTrace' : '';
    return '[$timeStr] $levelStr [$tag] $message$dataStr$errorStr$stackStr';
  }

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.label,
    'tag': tag,
    'message': message,
    if (data != null) 'data': data,
    if (error != null) 'error': error.toString(),
  };
}

/// Centralized logging service with:
/// - Rolling in-memory buffer (last 1000 entries)
/// - Local file logging (flushed periodically)
/// - Component-specific logger factory
class LoggingService {
  static final LoggingService _instance = LoggingService._internal();
  factory LoggingService() => _instance;
  LoggingService._internal();

  /// Maximum entries to keep in memory
  static const int maxBufferSize = 1000;

  /// How often to flush logs to file
  static const Duration flushInterval = Duration(minutes: 5);

  /// Maximum log file size before rotation (1MB)
  static const int maxLogFileSize = 1024 * 1024;

  /// Number of old log files to keep
  static const int maxLogFiles = 5;

  /// Minimum log level to record (can be changed at runtime)
  LogLevel minLevel = kDebugMode ? LogLevel.debug : LogLevel.info;

  /// In-memory log buffer (circular)
  final Queue<LogEntry> _buffer = Queue<LogEntry>();

  /// File for local logging
  File? _logFile;

  /// Timer for periodic file flush
  Timer? _flushTimer;

  /// Pending logs to write to file
  final List<LogEntry> _pendingFileWrites = [];

  /// Whether to also print to debug console
  bool printToConsole = kDebugMode;

  /// Create a component-specific logger
  ComponentLogger createLogger(String component) {
    return ComponentLogger._(this, component);
  }

  /// Initialize the logging service
  Future<void> initialize({
    String? sentryDsn, // Kept for API compatibility, ignored
    String? environment,
    String? release,
  }) async {
    // Initialize local file logging
    await _initializeFileLogging();

    // Start periodic flush timer
    _flushTimer = Timer.periodic(flushInterval, (_) => flushToFile());

    info('LoggingService', 'Logging service initialized (file logging only)');
  }

  Future<void> _initializeFileLogging() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final logsDir = Directory('${directory.path}/logs');
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }

      final today = DateTime.now().toIso8601String().substring(0, 10);
      _logFile = File('${logsDir.path}/parachute_$today.log');

      // Rotate old logs if needed
      await _rotateLogsIfNeeded(logsDir);

      debugPrint('[LoggingService] File logging initialized: ${_logFile!.path}');
    } catch (e) {
      debugPrint('[LoggingService] Failed to initialize file logging: $e');
    }
  }

  Future<void> _rotateLogsIfNeeded(Directory logsDir) async {
    try {
      final logFiles = await logsDir
          .list()
          .where((f) => f is File && f.path.endsWith('.log'))
          .cast<File>()
          .toList();

      // Sort by modification time (newest first)
      logFiles.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );

      // Delete old files beyond the limit
      if (logFiles.length > maxLogFiles) {
        for (var i = maxLogFiles; i < logFiles.length; i++) {
          await logFiles[i].delete();
          debugPrint('[LoggingService] Deleted old log file: ${logFiles[i].path}');
        }
      }

      // Check if current log file is too large
      if (_logFile != null && await _logFile!.exists()) {
        final size = await _logFile!.length();
        if (size > maxLogFileSize) {
          // Rename current file with timestamp
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final newPath = _logFile!.path.replaceAll('.log', '_$timestamp.log');
          await _logFile!.rename(newPath);
          _logFile = File(_logFile!.path); // Create new file
        }
      }
    } catch (e) {
      debugPrint('[LoggingService] Error rotating logs: $e');
    }
  }

  /// Log a message at the specified level
  void log(
    LogLevel level,
    String tag,
    String message, {
    Map<String, dynamic>? data,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (level.value < minLevel.value) return;

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
      data: data,
      error: error,
      stackTrace: stackTrace,
    );

    // Add to in-memory buffer
    _buffer.add(entry);
    while (_buffer.length > maxBufferSize) {
      _buffer.removeFirst();
    }

    // Add to pending file writes
    _pendingFileWrites.add(entry);

    // Print to console in debug mode
    if (printToConsole) {
      debugPrint(entry.formatted);
      if (stackTrace != null && level == LogLevel.error) {
        debugPrint(stackTrace.toString());
      }
    }
  }

  /// Convenience methods for each log level
  void debug(String tag, String message, {Map<String, dynamic>? data}) =>
      log(LogLevel.debug, tag, message, data: data);

  void info(String tag, String message, {Map<String, dynamic>? data}) =>
      log(LogLevel.info, tag, message, data: data);

  void warning(String tag, String message, {Object? error, Map<String, dynamic>? data}) =>
      log(LogLevel.warning, tag, message, error: error, data: data);

  void error(
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
  }) => log(LogLevel.error, tag, message, error: error, stackTrace: stackTrace, data: data);

  /// Capture an exception (logs locally)
  Future<void> captureException(
    Object exception, {
    StackTrace? stackTrace,
    String? tag,
    Map<String, dynamic>? extras,
  }) async {
    error(
      tag ?? 'Exception',
      exception.toString(),
      error: exception,
      stackTrace: stackTrace,
      data: extras,
    );
  }

  /// Flush pending logs to file
  Future<void> flushToFile() async {
    if (_pendingFileWrites.isEmpty || _logFile == null) return;

    try {
      final entries = List<LogEntry>.from(_pendingFileWrites);
      _pendingFileWrites.clear();

      final content = '${entries.map((e) => e.formatted).join('\n')}\n';
      await _logFile!.writeAsString(content, mode: FileMode.append);
    } catch (e) {
      debugPrint('[LoggingService] Failed to flush logs to file: $e');
    }
  }

  /// Get recent logs (for debugging UI or crash reports)
  List<LogEntry> getRecentLogs({
    int count = 100,
    LogLevel? level,
    String? tag,
    DateTime? since,
  }) {
    var entries = _buffer.toList();

    if (level != null) {
      entries = entries.where((e) => e.level.value >= level.value).toList();
    }
    if (tag != null) {
      entries = entries.where((e) => e.tag == tag).toList();
    }
    if (since != null) {
      entries = entries.where((e) => e.timestamp.isAfter(since)).toList();
    }

    // Return most recent entries
    if (entries.length > count) {
      entries = entries.sublist(entries.length - count);
    }

    return entries;
  }

  /// Get log statistics
  Map<String, dynamic> getStats() {
    final byLevel = <String, int>{};
    final byTag = <String, int>{};

    for (final entry in _buffer) {
      byLevel[entry.level.label] = (byLevel[entry.level.label] ?? 0) + 1;
      byTag[entry.tag] = (byTag[entry.tag] ?? 0) + 1;
    }

    return {
      'totalEntries': _buffer.length,
      'maxBufferSize': maxBufferSize,
      'byLevel': byLevel,
      'byTag': byTag,
      'oldestEntry': _buffer.isNotEmpty ? _buffer.first.timestamp.toIso8601String() : null,
      'newestEntry': _buffer.isNotEmpty ? _buffer.last.timestamp.toIso8601String() : null,
    };
  }

  /// Get path to current log file
  String? get logFilePath => _logFile?.path;

  /// Get all log file paths
  Future<List<String>> getLogFilePaths() async {
    try {
      final directory = await getApplicationSupportDirectory();
      final logsDir = Directory('${directory.path}/logs');
      if (!await logsDir.exists()) return [];

      final files = await logsDir
          .list()
          .where((f) => f is File && f.path.endsWith('.log'))
          .map((f) => f.path)
          .toList();

      files.sort((a, b) => b.compareTo(a)); // Newest first
      return files;
    } catch (e) {
      return [];
    }
  }

  /// Clear all log entries
  void clear() {
    _buffer.clear();
    _pendingFileWrites.clear();
  }

  /// Clean up resources
  Future<void> dispose() async {
    _flushTimer?.cancel();
    await flushToFile();
  }
}

/// Component-specific logger for convenient logging
class ComponentLogger {
  final LoggingService _service;
  final String component;

  ComponentLogger._(this._service, this.component);

  void debug(String message, {Map<String, dynamic>? data}) {
    _service.log(LogLevel.debug, component, message, data: data);
  }

  void info(String message, {Map<String, dynamic>? data}) {
    _service.log(LogLevel.info, component, message, data: data);
  }

  void warn(String message, {Map<String, dynamic>? data, Object? error}) {
    _service.log(LogLevel.warning, component, message, data: data, error: error);
  }

  void error(
    String message, {
    Map<String, dynamic>? data,
    Object? error,
    StackTrace? stackTrace,
  }) {
    _service.log(
      LogLevel.error,
      component,
      message,
      data: data,
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// Global logging instance for convenience
final logger = LoggingService();

/// Performance tracer for measuring execution time
class PerformanceTrace {
  final String name;
  final Stopwatch _stopwatch;
  final Map<String, dynamic>? metadata;
  bool _ended = false;

  PerformanceTrace._(this.name, this.metadata) : _stopwatch = Stopwatch()..start();

  /// Start a new performance trace
  static PerformanceTrace start(String name, {Map<String, dynamic>? metadata}) {
    return PerformanceTrace._(name, metadata);
  }

  /// End the trace and log the duration
  /// Returns the elapsed milliseconds
  int end({Map<String, dynamic>? additionalData}) {
    if (_ended) return _stopwatch.elapsedMilliseconds;
    _ended = true;
    _stopwatch.stop();

    final ms = _stopwatch.elapsedMilliseconds;
    final data = {
      'durationMs': ms,
      if (metadata != null) ...metadata!,
      if (additionalData != null) ...additionalData,
    };

    // Log as warning if > 16ms (will cause frame drops), debug otherwise
    final level = ms > 16 ? LogLevel.warning : LogLevel.debug;
    logger.log(level, 'Perf', name, data: data);

    return ms;
  }

  /// Get elapsed time without ending the trace
  int get elapsedMs => _stopwatch.elapsedMilliseconds;
}

/// Throttle class to limit how often a function can be called
class Throttle {
  final Duration interval;
  DateTime? _lastCall;

  Throttle(this.interval);

  /// Returns true if enough time has passed since last call
  bool shouldProceed() {
    final now = DateTime.now();
    if (_lastCall == null || now.difference(_lastCall!) >= interval) {
      _lastCall = now;
      return true;
    }
    return false;
  }

  /// Reset the throttle
  void reset() {
    _lastCall = null;
  }
}
