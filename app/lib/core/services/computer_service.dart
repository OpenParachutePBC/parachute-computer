import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

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
  static const String _defaultServerUrl = AppConfig.defaultServerUrl;

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

  static const _secureStorage = FlutterSecureStorage();

  /// Initialize the service
  Future<void> initialize() async {
    if (_isInitialized) return;

    final prefs = await SharedPreferences.getInstance();
    _serverUrl = prefs.getString(_serverUrlKey) ?? _defaultServerUrl;

    // Read API key from secure storage (migrated from SharedPreferences
    // by ApiKeyNotifier in app_state_provider.dart)
    _apiKey = await _secureStorage.read(key: _apiKeyKey);

    // Fallback: check SharedPreferences for pre-migration keys
    if (_apiKey == null || _apiKey!.isEmpty) {
      final legacyKey = prefs.getString(_apiKeyKey);
      if (legacyKey != null && legacyKey.isNotEmpty) {
        _apiKey = legacyKey;
      }
    }

    _isInitialized = true;
    // Security: Only log presence of API key, not the key itself
    debugPrint(
      '[ComputerService] Initialized with URL: $_serverUrl, hasApiKey: ${_apiKey != null && _apiKey!.isNotEmpty}',
    );
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
  Future<AgentTranscript?> getAgentTranscript(
    String agentName, {
    int limit = 50,
  }) async {
    try {
      final url =
          '${await getServerUrl()}/api/daily/agents/$agentName/transcript?limit=$limit';
      debugPrint('[ComputerService] Fetching agent transcript from: $url');

      final response = await http
          .get(Uri.parse(url), headers: await _getHeaders())
          .timeout(const Duration(seconds: 15));

      debugPrint(
        '[ComputerService] Agent transcript response: ${response.statusCode}',
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        debugPrint(
          '[ComputerService] Agent transcript data: hasTranscript=${data['hasTranscript']}, messages=${(data['messages'] as List?)?.length ?? 0}',
        );
        return AgentTranscript.fromJson(data);
      }
      debugPrint(
        '[ComputerService] Agent transcript error: ${response.statusCode} - ${response.body}',
      );
      return null;
    } catch (e) {
      debugPrint('[ComputerService] Error getting agent transcript: $e');
      return null;
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

/// How an Agent handles conversation state across runs.
enum MemoryMode {
  /// Resume prior SDK session — agent remembers previous runs.
  persistent,
  /// New session each run — no memory of prior runs.
  fresh;

  static MemoryMode fromString(String? value) => switch (value) {
        'fresh' => MemoryMode.fresh,
        _ => MemoryMode.persistent,
      };

  String toJson() => name;
}

/// Configuration for a daily agent (Agent node from the graph database).
class DailyAgentInfo {
  final String name;
  final String displayName;
  final String description;
  final String systemPrompt;
  final List<String> tools;
  final String trustLevel;
  final bool scheduleEnabled;
  final String scheduleTime;
  final String? lastRunAt;
  final String? lastProcessedDate;
  final int runCount;

  /// Event that triggers this Agent (e.g. "note.transcription_complete").
  /// Empty string means this is a scheduled (day-scoped) Agent.
  final String triggerEvent;

  /// JSON filter for matching entries on the trigger event.
  final Map<String, dynamic>? triggerFilter;

  /// How this Agent handles conversation state across runs.
  final MemoryMode memoryMode;

  /// Template version this agent was seeded/updated from (ISO date string).
  /// Null for user-created agents.
  final String? templateVersion;

  /// Whether the user has edited this builtin agent's config.
  final bool userModified;

  /// Whether a newer template version is available on the server.
  final bool updateAvailable;

  /// Whether this agent is a builtin that ships with Parachute.
  final bool isBuiltin;

  DailyAgentInfo({
    required this.name,
    required this.displayName,
    required this.description,
    this.systemPrompt = '',
    this.tools = const [],
    this.trustLevel = 'sandboxed',
    required this.scheduleEnabled,
    required this.scheduleTime,
    this.lastRunAt,
    this.lastProcessedDate,
    this.runCount = 0,
    this.triggerEvent = '',
    this.triggerFilter,
    this.memoryMode = MemoryMode.persistent,
    this.templateVersion,
    this.userModified = false,
    this.updateAvailable = false,
    this.isBuiltin = false,
  });

  /// Whether this Agent is event-driven (triggered) rather than scheduled.
  bool get isTriggered => triggerEvent.isNotEmpty;
}

/// Starter agent template returned by the templates endpoint.
class AgentTemplate {
  final String name;
  final String displayName;
  final String description;
  final String systemPrompt;
  final List<String> tools;
  final String scheduleTime;
  final String trustLevel;

  /// Event that triggers this Agent (e.g. "note.transcription_complete").
  /// Empty string means this is a scheduled (day-scoped) template.
  final String triggerEvent;

  /// JSON filter for matching entries on the trigger event.
  final Map<String, dynamic>? triggerFilter;

  /// How this template's Agent handles conversation state across runs.
  final MemoryMode memoryMode;

  const AgentTemplate({
    required this.name,
    required this.displayName,
    required this.description,
    required this.systemPrompt,
    required this.tools,
    this.scheduleTime = '21:00',
    this.trustLevel = 'sandboxed',
    this.triggerEvent = '',
    this.triggerFilter,
    this.memoryMode = MemoryMode.persistent,
  });

  /// Whether this template is for an event-driven (triggered) Agent.
  bool get isTriggered => triggerEvent.isNotEmpty;

  factory AgentTemplate.fromJson(Map<String, dynamic> json) {
    final rawTools = json['tools'];
    List<String> tools = [];
    if (rawTools is List) {
      tools = rawTools.cast<String>();
    }
    return AgentTemplate(
      name: json['name'] as String? ?? '',
      displayName:
          json['display_name'] as String? ?? json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String? ?? '',
      tools: tools,
      scheduleTime: json['schedule_time'] as String? ?? '21:00',
      trustLevel: json['trust_level'] as String? ?? 'sandboxed',
      triggerEvent: json['trigger_event'] as String? ?? '',
      triggerFilter: parseTriggerFilter(json['trigger_filter']),
      memoryMode: MemoryMode.fromString(json['memory_mode'] as String?),
    );
  }
}

/// Parse a trigger_filter value from JSON string or map.
///
/// Shared by [AgentTemplate.fromJson] and [DailyApiService.fetchAgents].
Map<String, dynamic>? parseTriggerFilter(dynamic raw) {
  if (raw is Map) return Map<String, dynamic>.from(raw);
  if (raw is String && raw.isNotEmpty) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
    } catch (e) {
      debugPrint('[parseTriggerFilter] failed to parse: $e');
    }
  }
  return null;
}

/// Record of a triggered Agent having run on a specific entry.
class AgentActivity {
  final String agentName;
  final String displayName;
  final String status;
  final String ranAt;
  final String sessionId;

  const AgentActivity({
    required this.agentName,
    required this.displayName,
    required this.status,
    required this.ranAt,
    this.sessionId = '',
  });

  factory AgentActivity.fromJson(Map<String, dynamic> json) => AgentActivity(
        // TODO(cleanup): remove caller_name fallback after v1.0 deploy
        agentName: json['agent_name'] as String? ?? json['caller_name'] as String? ?? '',
        displayName: json['display_name'] as String? ?? '',
        status: json['status'] as String? ?? '',
        ranAt: json['ran_at'] as String? ?? '',
        sessionId: json['session_id'] as String? ?? '',
      );
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
      success:
          status == 'completed' ||
          status == 'completed_no_output' ||
          status == 'skipped',
      status: status,
      outputPath: json['output_path'] as String?,
      error: json['error'] as String?,
      journalDate: json['journal_date'] as String?,
      outputDate: json['output_date'] as String?,
    );
  }
}

