import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Service for communicating with the Parachute Computer server.
///
/// Provides:
/// - Daily agent management and transcript retrieval
/// - Module management
/// - Session persistence
class ComputerService {
  static final ComputerService _instance = ComputerService._internal();
  factory ComputerService() => _instance;
  ComputerService._internal();

  // Use same key as app_state_provider.dart ServerUrlNotifier for consistency
  static const String _serverUrlKey = 'parachute_server_url';
  static const String _apiKeyKey = 'parachute_api_key';
  static const String _defaultServerUrl = 'http://localhost:3333';

  String? _serverUrl;
  String? _apiKey;
  bool _isInitialized = false;

  /// Get the configured server URL
  Future<String> getServerUrl() async {
    if (!_isInitialized) {
      await initialize();
    }
    return _serverUrl!;
  }

  /// Get HTTP headers including auth if configured
  Future<Map<String, String>> _getHeaders({bool json = false}) async {
    if (!_isInitialized) {
      await initialize();
    }
    final headers = <String, String>{};
    if (json) {
      headers['Content-Type'] = 'application/json';
    }
    if (_apiKey != null && _apiKey!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_apiKey';
    }
    return headers;
  }

  /// Initialize the service
  Future<void> initialize() async {
    if (_isInitialized) return;

    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString(_serverUrlKey) ?? _defaultServerUrl;
    _apiKey = prefs.getString(_apiKeyKey);
    _isInitialized = true;
    // Security: Only log presence of API key, not the key itself
    debugPrint('[ComputerService] Initialized with URL: $_serverUrl, hasApiKey: ${_apiKey != null && _apiKey!.isNotEmpty}');
  }

  /// Set a custom server URL
  Future<void> setServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, url);
    _serverUrl = url;
    debugPrint('[ComputerService] Server URL updated to: $url');
  }

  /// Reset to default server URL
  Future<void> resetServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serverUrlKey);
    _serverUrl = _defaultServerUrl;
    debugPrint('[ComputerService] Server URL reset to default: $_serverUrl');
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
      debugPrint('[ComputerService] Server not reachable: $e');
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
      debugPrint('[ComputerService] Error getting health status: $e');
      return null;
    }
  }

  /// Get the server's vault path
  ///
  /// Fetches the vault path from the server's health endpoint.
  /// This is the canonical source of truth for where files live.
  /// In Parachute Computer mode, the app should use this path directly
  /// instead of maintaining a separate vault path setting.
  Future<String?> getServerVaultPath() async {
    final health = await getHealthStatus();
    if (health == null) return null;

    final vault = health['vault'] as Map<String, dynamic>?;
    if (vault == null) return null;

    return vault['path'] as String?;
  }

  // ============================================================
  // Daily Agent Transcripts
  // ============================================================

  /// Get a daily agent's conversation transcript
  ///
  /// Returns the recent messages from the agent's session,
  /// including tool calls and responses.
  Future<AgentTranscript?> getAgentTranscript(String agentName, {int limit = 50}) async {
    try {
      final url = '${await getServerUrl()}/api/modules/daily/agents/$agentName/transcript?limit=$limit';
      debugPrint('[ComputerService] Fetching agent transcript from: $url');

      final response = await http
          .get(Uri.parse(url), headers: await _getHeaders())
          .timeout(const Duration(seconds: 15));

      debugPrint('[ComputerService] Agent transcript response: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        debugPrint('[ComputerService] Agent transcript data: hasTranscript=${data['hasTranscript']}, messages=${(data['messages'] as List?)?.length ?? 0}');
        return AgentTranscript.fromJson(data);
      }
      debugPrint('[ComputerService] Agent transcript error: ${response.statusCode} - ${response.body}');
      return null;
    } catch (e) {
      debugPrint('[ComputerService] Error getting agent transcript: $e');
      return null;
    }
  }

  // ============================================================
  // Daily Agents
  // ============================================================

  /// Get the list of configured daily agents
  ///
  /// Returns all agents discovered in Daily/.agents/ with their
  /// configuration and state.
  Future<List<DailyAgentInfo>?> getDailyAgents() async {
    try {
      final response = await http
          .get(Uri.parse('${await getServerUrl()}/api/modules/daily/agents'),
              headers: await _getHeaders())
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final agentsList = data['agents'] as List<dynamic>? ?? [];
        return agentsList
            .map((a) => DailyAgentInfo.fromJson(a as Map<String, dynamic>))
            .toList();
      }
      debugPrint('[ComputerService] Get agents error: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[ComputerService] Error getting daily agents: $e');
      return null;
    }
  }

  /// Get details for a specific daily agent
  Future<DailyAgentInfo?> getDailyAgent(String agentName) async {
    try {
      final response = await http
          .get(Uri.parse('${await getServerUrl()}/api/modules/daily/agents/$agentName'),
              headers: await _getHeaders())
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return DailyAgentInfo.fromJson(data);
      }
      debugPrint('[ComputerService] Get agent error: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[ComputerService] Error getting agent $agentName: $e');
      return null;
    }
  }

  /// Trigger a daily agent to run
  ///
  /// Parameters:
  /// - [agentName]: Name of the agent (e.g., "reflections", "content-scout")
  /// - [date]: Optional date in YYYY-MM-DD format (defaults to yesterday)
  /// - [force]: Force run even if already processed
  Future<AgentRunResult> triggerDailyAgent(
    String agentName, {
    String? date,
    bool force = false,
  }) async {
    try {
      final body = <String, dynamic>{};
      if (date != null) body['date'] = date;
      if (force) body['force'] = true;

      final response = await http
          .post(
            Uri.parse('${await getServerUrl()}/api/modules/daily/agents/$agentName/run'),
            headers: await _getHeaders(json: true),
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 180)); // Agents can take a while

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return AgentRunResult.fromJson(data);
      } else {
        final error = _parseError(response);
        return AgentRunResult(success: false, status: 'error', error: error);
      }
    } on SocketException catch (e) {
      return AgentRunResult(success: false, status: 'error', error: 'Server not reachable: $e');
    } on http.ClientException catch (e) {
      return AgentRunResult(success: false, status: 'error', error: 'Connection error: $e');
    } catch (e) {
      return AgentRunResult(success: false, status: 'error', error: 'Error triggering agent: $e');
    }
  }

  /// Get status of all daily agents for a specific date
  ///
  /// Returns which agents have outputs available on the server for the date.
  /// This enables the "morning flow" UX where the app can quickly check
  /// what agent outputs are available and pull any that are missing locally.
  Future<DailyAgentsStatusResult?> getDailyAgentsStatus({String? date}) async {
    try {
      final queryParams = <String, String>{};
      if (date != null) queryParams['date'] = date;

      final uri = Uri.parse('${await getServerUrl()}/api/modules/daily/agents/status')
          .replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);

      final response = await http
          .get(uri, headers: await _getHeaders())
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        return DailyAgentsStatusResult.fromJson(data);
      }
      return null;
    } catch (e) {
      debugPrint('[ComputerService] Error getting agent status: $e');
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

/// Agent conversation transcript
class AgentTranscript {
  final bool hasTranscript;
  final String? sessionId;
  final int totalMessages;
  final List<TranscriptMessage> messages;
  final String? message;

  AgentTranscript({
    required this.hasTranscript,
    this.sessionId,
    this.totalMessages = 0,
    this.messages = const [],
    this.message,
  });

  factory AgentTranscript.fromJson(Map<String, dynamic> json) {
    final messagesList = json['messages'] as List<dynamic>? ?? [];
    return AgentTranscript(
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

/// A single message in an agent transcript
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

// ============================================================
// Daily Agent Models
// ============================================================

/// Configuration for a daily agent
class DailyAgentInfo {
  final String name;
  final String displayName;
  final String description;
  final bool scheduleEnabled;
  final String scheduleTime;
  final String outputPath;
  final String? lastRunAt;
  final String? lastProcessedDate;
  final int runCount;

  DailyAgentInfo({
    required this.name,
    required this.displayName,
    required this.description,
    required this.scheduleEnabled,
    required this.scheduleTime,
    required this.outputPath,
    this.lastRunAt,
    this.lastProcessedDate,
    this.runCount = 0,
  });

  factory DailyAgentInfo.fromJson(Map<String, dynamic> json) {
    final schedule = json['schedule'] as Map<String, dynamic>? ?? {};
    final state = json['state'] as Map<String, dynamic>? ?? {};

    return DailyAgentInfo(
      name: json['name'] as String? ?? '',
      displayName: json['displayName'] as String? ?? json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      scheduleEnabled: schedule['enabled'] as bool? ?? true,
      scheduleTime: schedule['time'] as String? ?? '03:00',
      outputPath: json['outputPath'] as String? ?? '',
      lastRunAt: state['lastRunAt'] as String?,
      lastProcessedDate: state['lastProcessedDate'] as String?,
      runCount: state['runCount'] as int? ?? 0,
    );
  }

  /// Get the output directory name from the output path (e.g., "reflections" from "Daily/reflections/{date}.md")
  String get outputDirectory {
    final parts = outputPath.split('/');
    if (parts.length >= 2) {
      return parts[1];
    }
    return name;
  }
}

/// Result of triggering a daily agent
class AgentRunResult {
  final bool success;
  final String status;
  final String? outputPath;
  final String? error;
  final String? journalDate;
  final String? outputDate;

  AgentRunResult({
    required this.success,
    required this.status,
    this.outputPath,
    this.error,
    this.journalDate,
    this.outputDate,
  });

  factory AgentRunResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as String? ?? 'unknown';
    return AgentRunResult(
      success: status == 'completed' || status == 'completed_no_output' || status == 'skipped',
      status: status,
      outputPath: json['output_path'] as String?,
      error: json['error'] as String?,
      journalDate: json['journal_date'] as String?,
      outputDate: json['output_date'] as String?,
    );
  }
}

/// Result of checking daily agents status for a date
class DailyAgentsStatusResult {
  final String date;
  final List<AgentStatusInfo> agents;

  DailyAgentsStatusResult({
    required this.date,
    required this.agents,
  });

  factory DailyAgentsStatusResult.fromJson(Map<String, dynamic> json) {
    final agentsList = json['agents'] as List<dynamic>? ?? [];
    return DailyAgentsStatusResult(
      date: json['date'] as String? ?? '',
      agents: agentsList
          .map((a) => AgentStatusInfo.fromJson(a as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Get agents that have outputs available
  List<AgentStatusInfo> get availableAgents =>
      agents.where((a) => a.hasOutput).toList();

  /// Check if a specific agent has output for this date
  bool hasOutputFor(String agentName) =>
      agents.any((a) => a.name == agentName && a.hasOutput);

  /// Get output path for a specific agent
  String? getOutputPath(String agentName) =>
      agents.where((a) => a.name == agentName).firstOrNull?.outputPath;
}

/// Status info for a single agent
class AgentStatusInfo {
  final String name;
  final String displayName;
  final bool hasOutput;
  final String? outputPath;
  final String? lastRunAt;
  final String? lastProcessedDate;

  AgentStatusInfo({
    required this.name,
    required this.displayName,
    required this.hasOutput,
    this.outputPath,
    this.lastRunAt,
    this.lastProcessedDate,
  });

  factory AgentStatusInfo.fromJson(Map<String, dynamic> json) {
    return AgentStatusInfo(
      name: json['name'] as String? ?? '',
      displayName: json['displayName'] as String? ?? json['name'] as String? ?? '',
      hasOutput: json['hasOutput'] as bool? ?? false,
      outputPath: json['outputPath'] as String?,
      lastRunAt: json['lastRunAt'] as String?,
      lastProcessedDate: json['lastProcessedDate'] as String?,
    );
  }
}
