import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:parachute/core/models/thing.dart';
import '../models/entry_metadata.dart' show TranscriptionStatus;
import '../models/journal_entry.dart';
import '../models/agent_card.dart';
import '../models/daily_agent_models.dart'
    show DailyAgentInfo, AgentRunResult, AgentRunInfo, AgentTemplate, AgentActivity, AgentTranscript, MemoryMode, parseTriggerFilter;

/// Raw search result from the server API.
///
/// `SimpleTextSearchService` converts these to [SimpleSearchResult] objects
/// for display. Keeping the conversion in the search service avoids a
/// circular import between the API service and the search service.
class ApiSearchResult {
  final String id;
  final String createdAt;
  final String content;
  final String snippet;
  final int matchCount;
  final Map<String, dynamic> metadata;

  const ApiSearchResult({
    required this.id,
    required this.createdAt,
    required this.content,
    required this.snippet,
    required this.matchCount,
    required this.metadata,
  });

  factory ApiSearchResult.fromJson(Map<String, dynamic> json) {
    return ApiSearchResult(
      id: json['id'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? json['createdAt'] as String? ?? '',
      content: json['content'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
      matchCount: (json['match_count'] as num?)?.toInt() ?? 0,
      metadata: (json['metadata'] as Map<String, dynamic>?) ?? {},
    );
  }
}

/// HTTP client for the v2 Daily graph API server.
///
/// Translates between the app's JournalEntry/AgentCard models and the
/// v2 graph API's Thing/Tag model. All endpoints are under /api/ on
/// the server at [baseUrl].
///
/// Key mappings:
///   Journal entries = Things tagged "daily-note"
///   Agent cards     = Things tagged "card"
///   Agent/tools     = Tools table
class DailyApiService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  /// Optional callback for fast-fail / fast-recover health updates.
  void Function(bool reachable)? onReachabilityChanged;

  static const _timeout = Duration(seconds: 15);

  DailyApiService({required this.baseUrl, this.apiKey, this.onReachabilityChanged})
    : _client = http.Client();

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'User-Agent': 'Parachute-Daily/1.0',
    if (apiKey != null && apiKey!.isNotEmpty) 'Authorization': 'Bearer $apiKey',
  };

  // ===========================================================================
  // Journal Entry CRUD — backed by Things with "daily-note" tag
  // ===========================================================================

  /// Fetch entries for a specific date (YYYY-MM-DD).
  ///
  /// Returns `null` on network error — callers should fall back to their local
  /// cache when null, not treat it as an authoritative empty response.
  /// Returns `[]` when the server responds HTTP 200 with no entries — this IS
  /// authoritative: the date genuinely has nothing and the cache should be cleared.
  Future<List<JournalEntry>?> getEntries({required String date}) async {
    final uri = Uri.parse('$baseUrl/api/things').replace(
      queryParameters: {'tag': 'daily-note', 'date': date, 'limit': '100'},
    );
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] GET entries ${response.statusCode}');
        return null;
      }

      onReachabilityChanged?.call(true);
      final data = jsonDecode(response.body) as List<dynamic>;
      return data
          .map((json) => _thingToEntry(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] getEntries error (offline?): $e');
      onReachabilityChanged?.call(false);
      return null;
    }
  }

  /// Create a new entry on the server.
  ///
  /// Returns the created [JournalEntry] on success, or null if offline / error.
  Future<JournalEntry?> createEntry({
    required String content,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
  }) async {
    final uri = Uri.parse('$baseUrl/api/things');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final ts = createdAt ?? DateTime.now();
      final entryType = metadata?['type'] as String? ?? 'text';
      final date = metadata?['date'] as String? ?? _dateStr(ts);

      // Build daily-note tag field values from metadata
      final tagFields = <String, dynamic>{
        'entry_type': entryType,
        'date': date,
        if (metadata?['audio_path'] != null)
          'audio_url': metadata!['audio_path'],
        if (metadata?['duration_seconds'] != null)
          'duration_seconds': metadata!['duration_seconds'],
        if (metadata?['transcription_status'] != null)
          'transcription_status': metadata!['transcription_status'],
        if (metadata?['cleanup_status'] != null)
          'cleanup_status': metadata!['cleanup_status'],
      };

      final body = jsonEncode({
        'content': content,
        'tags': {'daily-note': tagFields},
        'created_by': 'user',
      });
      final response = await _client
          .post(uri, headers: _headers, body: body)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] POST things ${response.statusCode}');
        return null;
      }

      onReachabilityChanged?.call(true);
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return _thingToEntry(decoded);
    } catch (e) {
      debugPrint('[DailyApiService] createEntry error: $e');
      onReachabilityChanged?.call(false);
      return null;
    }
  }

  /// Update content and/or metadata of an existing entry.
  Future<JournalEntry?> updateEntry(
    String entryId, {
    String? content,
    Map<String, dynamic>? metadata,
  }) async {
    final uri = Uri.parse('$baseUrl/api/things/$entryId');
    debugPrint('[DailyApiService] PATCH $uri');
    try {
      final patchBody = <String, dynamic>{};
      if (content != null) patchBody['content'] = content;
      if (metadata != null) {
        // Translate metadata keys to daily-note tag fields
        final tagFields = <String, dynamic>{};
        if (metadata.containsKey('title')) tagFields['title'] = metadata['title'];
        if (metadata.containsKey('type')) tagFields['entry_type'] = metadata['type'];
        if (metadata.containsKey('audio_path')) tagFields['audio_url'] = metadata['audio_path'];
        if (tagFields.isNotEmpty) {
          patchBody['tags'] = {'daily-note': tagFields};
        }
      }

      final response = await _client
          .patch(uri, headers: _headers, body: jsonEncode(patchBody))
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] PATCH things/$entryId ${response.statusCode}');
        return null;
      }

      onReachabilityChanged?.call(true);
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return _thingToEntry(decoded);
    } catch (e) {
      debugPrint('[DailyApiService] updateEntry error: $e');
      onReachabilityChanged?.call(false);
      return null;
    }
  }

  /// Delete an entry. Returns true on success (including 404 — already gone).
  Future<bool> deleteEntry(String entryId) async {
    final uri = Uri.parse('$baseUrl/api/things/$entryId');
    debugPrint('[DailyApiService] DELETE $uri');
    try {
      final response = await _client
          .delete(uri, headers: _headers)
          .timeout(_timeout);

      if (response.statusCode == 404 ||
          response.statusCode == 200 ||
          (response.statusCode >= 200 && response.statusCode < 300)) {
        onReachabilityChanged?.call(true);
        return true;
      }
      debugPrint('[DailyApiService] DELETE things/$entryId ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[DailyApiService] deleteEntry error: $e');
      onReachabilityChanged?.call(false);
      return false;
    }
  }

  /// Get a single entry by ID.
  Future<JournalEntry?> getEntry(String entryId) async {
    final uri = Uri.parse('$baseUrl/api/things/$entryId');
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] GET things/$entryId ${response.statusCode}');
        return null;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return _thingToEntry(decoded);
    } catch (e) {
      debugPrint('[DailyApiService] getEntry error: $e');
      return null;
    }
  }

  // ===========================================================================
  // Audio & Voice
  // ===========================================================================

  /// Upload an audio file to the server.
  ///
  /// Returns the relative storage path, or null on failure.
  Future<String?> uploadAudio(File audioFile, {String? date}) async {
    final uri = Uri.parse('$baseUrl/api/storage/upload');
    debugPrint('[DailyApiService] POST $uri (audio upload)');
    try {
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('file', audioFile.path));
      if (apiKey != null && apiKey!.isNotEmpty) {
        request.headers['Authorization'] = 'Bearer $apiKey';
      }
      final streamed = await request.send().timeout(
        const Duration(seconds: 30),
      );
      if (streamed.statusCode == 201) {
        final body = jsonDecode(await streamed.stream.bytesToString())
            as Map<String, dynamic>;
        return body['path'] as String?;
      }
      debugPrint('[DailyApiService] uploadAudio ${streamed.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[DailyApiService] uploadAudio error: $e');
      return null;
    }
  }

  /// Upload audio for server-side transcription + LLM cleanup.
  ///
  /// In v2, this uploads the audio file and creates a Thing with pending
  /// transcription status. Server-side transcription is not yet implemented
  /// in the v2 server — this creates the entry for local transcription flow.
  Future<JournalEntry?> uploadVoiceEntry({
    required File audioFile,
    required int durationSeconds,
    String? date,
    String? replaceEntryId,
  }) async {
    // Upload audio first
    final audioPath = await uploadAudio(audioFile, date: date);
    if (audioPath == null) return null;

    final dateStr = date ?? _dateStr(DateTime.now());

    // If replacing, delete old entry
    if (replaceEntryId != null) {
      await deleteEntry(replaceEntryId);
    }

    // Create a Thing with daily-note tag and pending transcription
    return createEntry(
      content: '',
      metadata: {
        'type': 'voice',
        'date': dateStr,
        'audio_path': audioPath,
        'duration_seconds': durationSeconds,
        'transcription_status': 'processing',
      },
    );
  }

  /// Trigger LLM cleanup on an existing entry's content.
  ///
  /// Not yet supported in v2 server — returns false.
  Future<bool> cleanupEntry(String entryId) async {
    debugPrint('[DailyApiService] cleanupEntry: not yet supported in v2');
    return false;
  }

  // ===========================================================================
  // Search
  // ===========================================================================

  /// Keyword search across all entries.
  ///
  /// Returns empty list on error or when offline.
  Future<List<ApiSearchResult>> searchEntries(
    String query, {
    int limit = 30,
  }) async {
    if (query.trim().isEmpty) return [];
    final uri = Uri.parse('$baseUrl/api/search').replace(
      queryParameters: {'q': query, 'tag': 'daily-note', 'limit': '$limit'},
    );
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] search ${response.statusCode}');
        return [];
      }

      final data = jsonDecode(response.body) as List<dynamic>;
      return data
          .map((json) => _thingToSearchResult(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] searchEntries error: $e');
      return [];
    }
  }

  // ===========================================================================
  // Import — not yet supported in v2
  // ===========================================================================

  Future<Map<String, dynamic>?> getImportStatus() async {
    debugPrint('[DailyApiService] getImportStatus: not yet supported in v2');
    return null;
  }

  Future<Map<String, dynamic>?> flexibleImport({
    required String sourceDir,
    required String format,
    bool dryRun = false,
    String? dateFrom,
    String? dateTo,
  }) async {
    debugPrint('[DailyApiService] flexibleImport: not yet supported in v2');
    return null;
  }

  Future<Map<String, dynamic>?> triggerImport() async {
    debugPrint('[DailyApiService] triggerImport: not yet supported in v2');
    return null;
  }

  // ===========================================================================
  // Cards (Agent Outputs) — backed by Things with "card" tag
  // ===========================================================================

  /// Fetch all Card Things for a specific date (YYYY-MM-DD).
  Future<List<AgentCard>> fetchCards(String date) async {
    final uri = Uri.parse('$baseUrl/api/things').replace(
      queryParameters: {'tag': 'card', 'date': date},
    );
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] fetchCards ${response.statusCode}');
        return [];
      }
      final data = jsonDecode(response.body) as List<dynamic>;
      return data
          .map((j) => _thingToCard(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] fetchCards error: $e');
      return [];
    }
  }

  /// Fetch all unread Card Things within a 7-day window.
  ///
  /// The v2 server doesn't have a dedicated unread endpoint — we fetch recent
  /// cards and filter client-side.
  Future<List<AgentCard>> fetchUnreadCards() async {
    // Fetch cards from the last 7 days
    final now = DateTime.now();
    final results = <AgentCard>[];
    for (int i = 0; i < 7; i++) {
      final date = now.subtract(Duration(days: i));
      final dateStr = _dateStr(date);
      final cards = await fetchCards(dateStr);
      results.addAll(cards.where((c) => c.isUnread));
    }
    return results;
  }

  /// Mark a card as read by updating its card tag field.
  Future<bool> markCardRead(String cardId) async {
    final uri = Uri.parse('$baseUrl/api/things/$cardId');
    debugPrint('[DailyApiService] PATCH $uri (mark read)');
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final response = await _client.patch(
        uri,
        headers: _headers,
        body: jsonEncode({
          'tags': {'card': {'read_at': now}},
        }),
      ).timeout(_timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('[DailyApiService] markCardRead error: $e');
      return false;
    }
  }

  // ===========================================================================
  // Agents / Tools — backed by the tools table
  // ===========================================================================

  /// Fetch all agents (tools published by daily).
  Future<List<DailyAgentInfo>> fetchAgents() async {
    final uri = Uri.parse('$baseUrl/api/tools').replace(
      queryParameters: {'published_by': 'parachute-daily'},
    );
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] fetchAgents ${response.statusCode}');
        return [];
      }

      final data = jsonDecode(response.body) as List<dynamic>;
      return data
          .map((j) => _toolToAgentInfo(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] fetchAgents error: $e');
      return [];
    }
  }

  /// Fetch the latest run for a tool/agent.
  Future<AgentRunInfo?> fetchLatestAgentRun(String agentName) async {
    // Not yet supported in v2
    return null;
  }

  /// Fetch starter Agent templates for onboarding.
  ///
  /// In v2, templates don't exist as a server concept yet.
  /// Return empty list — agent management is deferred.
  Future<List<AgentTemplate>> fetchTemplates() async {
    return [];
  }

  /// Create a new Tool on the server.
  Future<Map<String, dynamic>?> createAgent(Map<String, dynamic> body) async {
    final uri = Uri.parse('$baseUrl/api/tools');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final response = await _client
          .post(uri, headers: _headers, body: jsonEncode(body))
          .timeout(_timeout);
      if (response.statusCode == 201 ||
          (response.statusCode >= 200 && response.statusCode < 300)) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      debugPrint('[DailyApiService] createAgent ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[DailyApiService] createAgent error: $e');
      return null;
    }
  }

  /// Delete a Tool. Returns true on success.
  Future<bool> deleteAgent(String name) async {
    // v2 tools route doesn't have DELETE yet — stub
    debugPrint('[DailyApiService] deleteAgent: not yet supported in v2');
    return false;
  }

  /// Trigger a tool run via the execute endpoint.
  Future<AgentRunResult> triggerAgentRun(
    String agentName, {
    String? date,
  }) async {
    final uri = Uri.parse('$baseUrl/api/tools/$agentName/execute');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final scope = <String, dynamic>{};
      if (date != null) scope['date'] = date;
      final response = await _client
          .post(uri, headers: _headers, body: jsonEncode(scope))
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return const AgentRunResult(success: true, status: 'started');
      }
      debugPrint('[DailyApiService] triggerAgentRun ${response.statusCode}');
      return AgentRunResult(
        success: false,
        status: 'error',
        error: 'Server returned ${response.statusCode}',
      );
    } catch (e) {
      debugPrint('[DailyApiService] triggerAgentRun error: $e');
      return AgentRunResult(
        success: false,
        status: 'error',
        error: e.toString(),
      );
    }
  }

  /// Update fields on an existing Tool.
  Future<bool> updateAgent(String name, Map<String, dynamic> fields) async {
    // v2 tools route doesn't have PATCH yet — stub
    debugPrint('[DailyApiService] updateAgent: not yet fully supported in v2');
    return false;
  }

  /// Reset an Agent's session.
  Future<bool> resetAgent(String name) async {
    debugPrint('[DailyApiService] resetAgent: not yet supported in v2');
    return false;
  }

  /// Reset a builtin agent to its latest template defaults.
  Future<bool> resetAgentToTemplate(String name) async {
    debugPrint('[DailyApiService] resetAgentToTemplate: not yet supported in v2');
    return false;
  }

  /// Reload the server scheduler configuration.
  Future<bool> reloadScheduler() async {
    debugPrint('[DailyApiService] reloadScheduler: not yet supported in v2');
    return false;
  }

  /// Trigger a Tool on a specific entry.
  Future<Map<String, dynamic>?> triggerAgentOnEntry(
    String agentName,
    String entryId,
  ) async {
    final uri = Uri.parse('$baseUrl/api/tools/$agentName/execute');
    debugPrint('[DailyApiService] POST $uri (entry_id=$entryId)');
    try {
      final response = await _client
          .post(uri, headers: _headers, body: jsonEncode({'entry_id': entryId}))
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      debugPrint('[DailyApiService] triggerAgentOnEntry ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[DailyApiService] triggerAgentOnEntry error: $e');
      return null;
    }
  }

  /// Fetch Agent activity for a specific entry.
  ///
  /// Not yet supported in v2 — returns empty list.
  Future<List<AgentActivity>> fetchAgentActivity(String entryId) async {
    return [];
  }

  /// Fetch the conversation transcript for an agent's most recent session.
  ///
  /// Not yet supported in v2.
  Future<AgentTranscript?> getAgentTranscript(
    String agentName, {
    int limit = 50,
  }) async {
    return const AgentTranscript(message: 'Transcripts not yet available in v2.');
  }

  void dispose() => _client.close();

  // ===========================================================================
  // Translation helpers — v2 Thing → app models
  // ===========================================================================

  /// Convert a Thing JSON (from v2 graph API) to a [JournalEntry].
  ///
  /// The Thing has tags: [{tagName: "daily-note", fieldValues: {...}}].
  /// We extract the daily-note tag fields to populate JournalEntry properties.
  static JournalEntry _thingToEntry(Map<String, dynamic> json) {
    final tags = json['tags'] as List<dynamic>? ?? [];
    Map<String, dynamic> noteFields = {};
    for (final tag in tags) {
      final tagMap = tag as Map<String, dynamic>;
      if (tagMap['tagName'] == 'daily-note') {
        noteFields = (tagMap['fieldValues'] as Map<String, dynamic>?) ?? {};
        break;
      }
    }

    final entryType = noteFields['entry_type'] as String? ?? 'text';
    final transcriptionStr = noteFields['transcription_status'] as String?;
    final transcriptionStatus = transcriptionStr != null
        ? TranscriptionStatus.values.cast<TranscriptionStatus?>().firstWhere(
            (s) => s?.name == transcriptionStr,
            orElse: () => null,
          )
        : null;

    return JournalEntry(
      id: json['id'] as String,
      title: noteFields['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      type: JournalEntry.parseType(entryType),
      createdAt: JournalEntry.parseDateTime(json['createdAt'] as String?),
      audioPath: noteFields['audio_url'] as String?,
      durationSeconds: _parseInt(noteFields['duration_seconds']),
      isPendingTranscription:
          transcriptionStatus == TranscriptionStatus.processing,
      serverTranscriptionStatus: transcriptionStatus,
    );
  }

  /// Convert a Thing JSON (tagged "card") to an [AgentCard].
  static AgentCard _thingToCard(Map<String, dynamic> json) {
    final tags = json['tags'] as List<dynamic>? ?? [];
    Map<String, dynamic> cardFields = {};
    for (final tag in tags) {
      final tagMap = tag as Map<String, dynamic>;
      if (tagMap['tagName'] == 'card') {
        cardFields = (tagMap['fieldValues'] as Map<String, dynamic>?) ?? {};
        break;
      }
    }

    return AgentCard(
      cardId: json['id'] as String? ?? '',
      agentName: json['createdBy'] as String? ?? '',
      displayName: json['createdBy'] as String? ?? '',
      cardType: cardFields['card_type'] as String? ?? 'default',
      content: json['content'] as String? ?? '',
      status: 'done',
      generatedAt: json['createdAt'] as String?,
      date: cardFields['date'] as String? ?? '',
      readAt: cardFields['read_at'] as String?,
    );
  }

  /// Convert a Tool JSON to a [DailyAgentInfo].
  static DailyAgentInfo _toolToAgentInfo(Map<String, dynamic> json) {
    return DailyAgentInfo(
      name: json['name'] as String? ?? '',
      displayName: json['displayName'] as String? ?? json['display_name'] as String? ?? json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
    );
  }

  /// Convert a Thing JSON (from search results) to an [ApiSearchResult].
  static ApiSearchResult _thingToSearchResult(Map<String, dynamic> json) {
    final tags = json['tags'] as List<dynamic>? ?? [];
    Map<String, dynamic> noteFields = {};
    for (final tag in tags) {
      final tagMap = tag as Map<String, dynamic>;
      if (tagMap['tagName'] == 'daily-note') {
        noteFields = (tagMap['fieldValues'] as Map<String, dynamic>?) ?? {};
        break;
      }
    }

    final content = json['content'] as String? ?? '';
    return ApiSearchResult(
      id: json['id'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      content: content,
      snippet: content.length > 200 ? '${content.substring(0, 200)}...' : content,
      matchCount: 1,
      metadata: noteFields,
    );
  }

  /// Format a [DateTime] as a YYYY-MM-DD string in local time.
  static String _dateStr(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Safely parse an int from various types.
  static int? _parseInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
