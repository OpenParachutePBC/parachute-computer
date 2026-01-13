import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Service for communicating with the Parachute Base server.
///
/// The Base server provides:
/// - AI curator functionality (daily reflections, chat summaries)
/// - Module management
/// - Session persistence
class BaseServerService {
  static final BaseServerService _instance = BaseServerService._internal();
  factory BaseServerService() => _instance;
  BaseServerService._internal();

  // Use same key as app_state_provider.dart ServerUrlNotifier for consistency
  static const String _serverUrlKey = 'parachute_server_url';
  static const String _defaultServerUrl = 'http://localhost:3333';

  String? _serverUrl;
  bool _isInitialized = false;

  /// Get the configured server URL
  Future<String> getServerUrl() async {
    if (!_isInitialized) {
      await initialize();
    }
    return _serverUrl!;
  }

  /// Initialize the service
  Future<void> initialize() async {
    if (_isInitialized) return;

    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString(_serverUrlKey) ?? _defaultServerUrl;
    _isInitialized = true;
    debugPrint('[BaseServerService] Initialized with URL: $_serverUrl');
  }

  /// Set a custom server URL
  Future<void> setServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, url);
    _serverUrl = url;
    debugPrint('[BaseServerService] Server URL updated to: $url');
  }

  /// Reset to default server URL
  Future<void> resetServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serverUrlKey);
    _serverUrl = _defaultServerUrl;
    debugPrint('[BaseServerService] Server URL reset to default: $_serverUrl');
  }

  // ============================================================
  // Health & Connectivity
  // ============================================================

  /// Check if the server is reachable
  Future<bool> isServerReachable() async {
    try {
      final response = await http
          .get(Uri.parse('${await getServerUrl()}/api/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[BaseServerService] Server not reachable: $e');
      return false;
    }
  }

  /// Get detailed health status
  Future<Map<String, dynamic>?> getHealthStatus() async {
    try {
      final response = await http
          .get(Uri.parse('${await getServerUrl()}/api/health?detailed=true'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('[BaseServerService] Error getting health status: $e');
      return null;
    }
  }

  // ============================================================
  // Daily Curator
  // ============================================================

  /// Get the daily curator status
  ///
  /// Returns information about:
  /// - Whether curator has run today
  /// - Last run time
  /// - Session continuity info
  Future<DailyCuratorStatus?> getDailyCuratorStatus() async {
    try {
      final response = await http
          .get(Uri.parse('${await getServerUrl()}/modules/daily/curator'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return DailyCuratorStatus.fromJson(data);
      }
      debugPrint('[BaseServerService] Curator status error: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[BaseServerService] Error getting curator status: $e');
      return null;
    }
  }

  /// Trigger the daily curator to generate a reflection
  ///
  /// Parameters:
  /// - [date]: Optional date in YYYY-MM-DD format (defaults to today)
  /// - [force]: Force run even if already processed
  ///
  /// Returns the result of the curator run.
  Future<CuratorRunResult> triggerDailyCurator({
    String? date,
    bool force = false,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (date != null) body['date'] = date;
      if (force) body['force'] = true;

      final response = await http
          .post(
            Uri.parse('${await getServerUrl()}/modules/daily/curate'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 120)); // Curator can take a while

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return CuratorRunResult.fromJson(data);
      } else {
        final error = _parseError(response);
        return CuratorRunResult.error(error);
      }
    } on SocketException catch (e) {
      return CuratorRunResult.error('Server not reachable: $e');
    } on http.ClientException catch (e) {
      return CuratorRunResult.error('Connection error: $e');
    } catch (e) {
      return CuratorRunResult.error('Error triggering curator: $e');
    }
  }

  /// Get the curator's conversation transcript
  ///
  /// Returns the recent messages from the curator's long-running session,
  /// including tool calls and responses.
  Future<CuratorTranscript?> getCuratorTranscript({int limit = 50}) async {
    try {
      final response = await http
          .get(Uri.parse('${await getServerUrl()}/modules/daily/curator/transcript?limit=$limit'))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return CuratorTranscript.fromJson(data);
      }
      debugPrint('[BaseServerService] Transcript error: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[BaseServerService] Error getting transcript: $e');
      return null;
    }
  }

  String _parseError(http.Response response) {
    try {
      final data = json.decode(response.body) as Map<String, dynamic>;
      return data['detail'] as String? ?? 'Unknown error (${response.statusCode})';
    } catch (_) {
      return 'Error ${response.statusCode}: ${response.body}';
    }
  }
}

// ============================================================
// Models
// ============================================================

/// Status of the daily curator
class DailyCuratorStatus {
  final bool hasCurator;
  final bool hasTodayReflection;
  final String? todayReflectionPath;
  final Map<String, dynamic>? state;
  final String? message;

  DailyCuratorStatus({
    required this.hasCurator,
    required this.hasTodayReflection,
    this.todayReflectionPath,
    this.state,
    this.message,
  });

  factory DailyCuratorStatus.fromJson(Map<String, dynamic> json) {
    return DailyCuratorStatus(
      hasCurator: json['hasCurator'] as bool? ?? false,
      hasTodayReflection: json['hasTodayReflection'] as bool? ?? false,
      todayReflectionPath: json['todayReflectionPath'] as String?,
      state: json['state'] as Map<String, dynamic>?,
      message: json['message'] as String?,
    );
  }

  /// Get the last run time from state
  DateTime? get lastRunAt {
    if (state == null) return null;
    final lastRun = state!['last_run_at'] as String?;
    if (lastRun == null) return null;
    return DateTime.tryParse(lastRun);
  }

  /// Get the session ID for continuity
  String? get sessionId => state?['session_id'] as String?;

  /// Get the run count
  int get runCount => state?['run_count'] as int? ?? 0;
}

/// Result of a curator run
class CuratorRunResult {
  final bool success;
  final String? reflectionPath;
  final String? message;
  final String? error;
  final bool skipped;
  final String? skipReason;

  CuratorRunResult({
    required this.success,
    this.reflectionPath,
    this.message,
    this.error,
    this.skipped = false,
    this.skipReason,
  });

  factory CuratorRunResult.fromJson(Map<String, dynamic> json) {
    return CuratorRunResult(
      success: json['success'] as bool? ?? false,
      reflectionPath: json['reflection_path'] as String?,
      message: json['message'] as String?,
      skipped: json['skipped'] as bool? ?? false,
      skipReason: json['skip_reason'] as String?,
    );
  }

  factory CuratorRunResult.error(String errorMessage) {
    return CuratorRunResult(
      success: false,
      error: errorMessage,
    );
  }
}

/// Curator conversation transcript
class CuratorTranscript {
  final bool hasTranscript;
  final String? sessionId;
  final int totalMessages;
  final List<TranscriptMessage> messages;
  final String? message;

  CuratorTranscript({
    required this.hasTranscript,
    this.sessionId,
    this.totalMessages = 0,
    this.messages = const [],
    this.message,
  });

  factory CuratorTranscript.fromJson(Map<String, dynamic> json) {
    final messagesList = json['messages'] as List<dynamic>? ?? [];
    return CuratorTranscript(
      hasTranscript: json['hasTranscript'] as bool? ?? false,
      sessionId: json['sessionId'] as String?,
      totalMessages: json['totalMessages'] as int? ?? 0,
      messages: messagesList
          .map((m) => TranscriptMessage.fromJson(m as Map<String, dynamic>))
          .toList(),
      message: json['message'] as String?,
    );
  }
}

/// A single message in the curator transcript
class TranscriptMessage {
  final String type;
  final String? timestamp;
  final String? content;
  final List<TranscriptBlock>? blocks;
  final String? model;

  TranscriptMessage({
    required this.type,
    this.timestamp,
    this.content,
    this.blocks,
    this.model,
  });

  factory TranscriptMessage.fromJson(Map<String, dynamic> json) {
    final blocksList = json['blocks'] as List<dynamic>?;
    return TranscriptMessage(
      type: json['type'] as String? ?? 'unknown',
      timestamp: json['timestamp'] as String?,
      content: json['content'] as String?,
      blocks: blocksList
          ?.map((b) => TranscriptBlock.fromJson(b as Map<String, dynamic>))
          .toList(),
      model: json['model'] as String?,
    );
  }

  bool get isAssistant => type == 'assistant';
  bool get isUser => type == 'user';
}

/// A content block in a transcript message
class TranscriptBlock {
  final String type;
  final String? text;
  final String? name;
  final String? input;
  final String? toolUseId;

  TranscriptBlock({
    required this.type,
    this.text,
    this.name,
    this.input,
    this.toolUseId,
  });

  factory TranscriptBlock.fromJson(Map<String, dynamic> json) {
    return TranscriptBlock(
      type: json['type'] as String? ?? 'unknown',
      text: json['text'] as String?,
      name: json['name'] as String?,
      input: json['input'] as String?,
      toolUseId: json['tool_use_id'] as String?,
    );
  }

  bool get isText => type == 'text';
  bool get isToolUse => type == 'tool_use';
  bool get isToolResult => type == 'tool_result';
}
