import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/entry_metadata.dart' show TranscriptionStatus;
import '../models/journal_entry.dart';
import '../models/agent_card.dart';
import 'package:parachute/core/services/computer_service.dart'
    show DailyAgentInfo, AgentRunResult, AgentRunInfo, AgentTemplate, AgentActivity, MemoryMode, parseTriggerFilter;

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
      createdAt: json['created_at'] as String? ?? '',
      content: json['content'] as String? ?? '',
      snippet: json['snippet'] as String? ?? '',
      matchCount: (json['match_count'] as num?)?.toInt() ?? 0,
      metadata: (json['metadata'] as Map<String, dynamic>?) ?? {},
    );
  }
}

/// HTTP client for the server Daily module API.
///
/// Mirrors the ChatService shape: baseUrl + optional apiKey + http.Client.
///
/// Endpoints:
///   GET  /api/daily/entries?date=YYYY-MM-DD  – list entries for a date
///   POST /api/daily/entries                  – create a new entry
class DailyApiService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  /// Optional callback for fast-fail / fast-recover health updates.
  ///
  /// Called with `true` on successful API response, `false` on network error.
  /// Used by the connectivity provider to immediately update reachability
  /// without waiting for the next periodic health check.
  void Function(bool reachable)? onReachabilityChanged;

  static const _timeout = Duration(seconds: 15);

  DailyApiService({required this.baseUrl, this.apiKey, this.onReachabilityChanged})
    : _client = http.Client();

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'User-Agent': 'Parachute-Daily/1.0',
    if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
  };

  /// Fetch entries for a specific date (YYYY-MM-DD).
  ///
  /// Returns `null` on network error — callers should fall back to their local
  /// cache when null, not treat it as an authoritative empty response.
  /// Returns `[]` when the server responds HTTP 200 with no entries — this IS
  /// authoritative: the date genuinely has nothing and the cache should be cleared.
  Future<List<JournalEntry>?> getEntries({required String date}) async {
    final uri = Uri.parse(
      '$baseUrl/api/daily/entries',
    ).replace(queryParameters: {'date': date, 'limit': '100'});
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
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> data = decoded['entries'] as List<dynamic>? ?? [];
      return data
          .map(
            (json) => JournalEntry.fromServerJson(json as Map<String, dynamic>),
          )
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
  ///
  /// Client-originated timestamps: if [createdAt] is provided (e.g. for
  /// offline entries being flushed), it is sent as `created_at` and the date
  /// is derived from it.  Otherwise the current time is used so the server
  /// always receives the moment the user actually wrote the entry.
  Future<JournalEntry?> createEntry({
    required String content,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
  }) async {
    final uri = Uri.parse('$baseUrl/api/daily/entries');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final ts = createdAt ?? DateTime.now();
      final enrichedMeta = <String, dynamic>{
        ...?metadata,
        'created_at': ts.toUtc().toIso8601String(),
        'date': _dateStr(ts),
      };
      final body = jsonEncode({
        'content': content,
        'metadata': enrichedMeta,
      });
      final response = await _client
          .post(uri, headers: _headers, body: body)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] POST entries ${response.statusCode}');
        return null;
      }

      onReachabilityChanged?.call(true);
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      // Server returns {id, path, created_at, brain_suggestions}.
      // Build the entry directly rather than routing through fromServerJson
      // on synthetic data — the server doesn't echo the full entry shape.
      return JournalEntry(
        id: decoded['id'] as String,
        title: metadata?['title'] as String? ?? '',
        content: content,
        type: JournalEntry.parseType(metadata?['type'] as String? ?? 'text'),
        createdAt: JournalEntry.parseDateTime(decoded['created_at'] as String?),
        audioPath: metadata?['audio_path'] as String?,
        imagePath: metadata?['image_path'] as String?,
        durationSeconds: metadata?['duration_seconds'] as int?,
      );
    } catch (e) {
      debugPrint('[DailyApiService] createEntry error: $e');
      onReachabilityChanged?.call(false);
      return null;
    }
  }

  /// Update content and/or metadata of an existing entry.
  ///
  /// Returns the updated [JournalEntry] on success, or null if offline / not found / error.
  Future<JournalEntry?> updateEntry(
    String entryId, {
    String? content,
    Map<String, dynamic>? metadata,
  }) async {
    final uri = Uri.parse('$baseUrl/api/daily/entries/$entryId');
    debugPrint('[DailyApiService] PATCH $uri');
    try {
      final body = jsonEncode({
        if (content != null) 'content': content,
        if (metadata != null) 'metadata': metadata,
      });
      final response = await _client
          .patch(uri, headers: _headers, body: body)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          '[DailyApiService] PATCH entries/$entryId ${response.statusCode}',
        );
        return null;
      }

      onReachabilityChanged?.call(true);
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return JournalEntry.fromServerJson(decoded);
    } catch (e) {
      debugPrint('[DailyApiService] updateEntry error: $e');
      onReachabilityChanged?.call(false);
      return null;
    }
  }

  /// Delete an entry. Returns true on success (including 404 — already gone).
  Future<bool> deleteEntry(String entryId) async {
    final uri = Uri.parse('$baseUrl/api/daily/entries/$entryId');
    debugPrint('[DailyApiService] DELETE $uri');
    try {
      final response = await _client
          .delete(uri, headers: _headers)
          .timeout(_timeout);

      if (response.statusCode == 404 ||
          response.statusCode == 204 ||
          (response.statusCode >= 200 && response.statusCode < 300)) {
        onReachabilityChanged?.call(true);
        return true;
      }
      debugPrint(
        '[DailyApiService] DELETE entries/$entryId ${response.statusCode}',
      );
      return false;
    } catch (e) {
      debugPrint('[DailyApiService] deleteEntry error: $e');
      onReachabilityChanged?.call(false);
      return false;
    }
  }

  /// Upload an audio file to the server.
  ///
  /// Returns the absolute server path to store in the entry, or null on failure.
  Future<String?> uploadAudio(File audioFile, {String? date}) async {
    final uri = Uri.parse('$baseUrl/api/daily/assets/upload');
    debugPrint('[DailyApiService] POST $uri (audio upload)');
    try {
      final dateStr = date ?? _dateStr(DateTime.now());
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('file', audioFile.path))
        ..fields['date'] = dateStr;
      if (apiKey != null && apiKey!.isNotEmpty) {
        request.headers['X-API-Key'] = apiKey!;
      }
      final streamed = await request.send().timeout(
        const Duration(seconds: 30),
      );
      if (streamed.statusCode == 201) {
        final body =
            jsonDecode(await streamed.stream.bytesToString())
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

  /// Get a single entry by ID.
  ///
  /// Returns the [JournalEntry] on success, or null if offline / not found.
  Future<JournalEntry?> getEntry(String entryId) async {
    final uri = Uri.parse('$baseUrl/api/daily/entries/$entryId');
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] GET entries/$entryId ${response.statusCode}');
        return null;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return JournalEntry.fromServerJson(decoded);
    } catch (e) {
      debugPrint('[DailyApiService] getEntry error: $e');
      return null;
    }
  }

  /// Upload audio for server-side transcription + LLM cleanup.
  ///
  /// Sends audio to `POST /api/daily/entries/voice`. The server creates the entry,
  /// transcribes via Parakeet MLX, and runs cleanup — all asynchronously.
  /// Returns the created [JournalEntry] (with transcription_status: processing).
  Future<JournalEntry?> uploadVoiceEntry({
    required File audioFile,
    required int durationSeconds,
    String? date,
    String? replaceEntryId,
  }) async {
    final uri = Uri.parse('$baseUrl/api/daily/entries/voice');
    debugPrint('[DailyApiService] POST $uri (voice entry upload${replaceEntryId != null ? ', replacing $replaceEntryId' : ''})');
    try {
      final dateStr = date ?? _dateStr(DateTime.now());
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('file', audioFile.path))
        ..fields['date'] = dateStr
        ..fields['duration_seconds'] = durationSeconds.toString();
      if (replaceEntryId != null) {
        request.fields['replace_entry_id'] = replaceEntryId;
      }
      if (apiKey != null && apiKey!.isNotEmpty) {
        request.headers['X-API-Key'] = apiKey!;
      }
      final streamed = await request.send().timeout(
        const Duration(seconds: 60),
      );
      if (streamed.statusCode == 201 || streamed.statusCode == 200) {
        final body = jsonDecode(
          await streamed.stream.bytesToString(),
        ) as Map<String, dynamic>;
        // Server returns {entry_id, status, audio_path} — different from entry JSON shape
        return JournalEntry(
          id: (body['entry_id'] ?? body['id']) as String,
          title: '',
          content: '',
          type: JournalEntryType.voice,
          createdAt: JournalEntry.parseDateTime(body['created_at'] as String?),
          audioPath: body['audio_path'] as String?,
          durationSeconds: durationSeconds,
          isPendingTranscription: true,
          serverTranscriptionStatus: TranscriptionStatus.processing,
        );
      }
      debugPrint(
        '[DailyApiService] uploadVoiceEntry ${streamed.statusCode}',
      );
      return null;
    } catch (e) {
      debugPrint('[DailyApiService] uploadVoiceEntry error: $e');
      return null;
    }
  }

  /// Trigger LLM cleanup on an existing entry's content.
  ///
  /// Returns true on success (cleanup started in background on server).
  Future<bool> cleanupEntry(String entryId) async {
    final uri = Uri.parse('$baseUrl/api/daily/entries/$entryId/cleanup');
    debugPrint('[DailyApiService] POST $uri (cleanup entry)');
    try {
      final response = await _client
          .post(uri, headers: _headers)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 200) {
        debugPrint('[DailyApiService] Cleanup started for $entryId');
        return true;
      }
      debugPrint('[DailyApiService] cleanupEntry ${response.statusCode}: ${response.body}');
      return false;
    } catch (e) {
      debugPrint('[DailyApiService] cleanupEntry error: $e');
      return false;
    }
  }

  /// Format a [DateTime] as a YYYY-MM-DD string in local time.
  static String _dateStr(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Keyword search across all entries.
  ///
  /// Returns empty list on error or when offline.
  Future<List<ApiSearchResult>> searchEntries(
    String query, {
    int limit = 30,
  }) async {
    if (query.trim().isEmpty) return [];
    final uri = Uri.parse(
      '$baseUrl/api/daily/entries/search',
    ).replace(queryParameters: {'q': query, 'limit': '$limit'});
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] search ${response.statusCode}');
        return [];
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> data = decoded['results'] as List<dynamic>? ?? [];
      return data
          .map((json) => ApiSearchResult.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] searchEntries error: $e');
      return [];
    }
  }

  /// Get markdown import status: how many .md files exist and how many are imported.
  Future<Map<String, dynamic>?> getImportStatus() async {
    final uri = Uri.parse('$baseUrl/api/daily/import/status');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[DailyApiService] getImportStatus error: $e');
      return null;
    }
  }

  /// Flexible journal import from any directory + format.
  ///
  /// [format]: "parachute" | "obsidian" | "logseq" | "plain"
  /// [dryRun]: if true, parse but don't write to graph — returns preview.
  Future<Map<String, dynamic>?> flexibleImport({
    required String sourceDir,
    required String format,
    bool dryRun = false,
    String? dateFrom,
    String? dateTo,
  }) async {
    final uri = Uri.parse('$baseUrl/api/daily/import/flexible');
    try {
      final body = jsonEncode({
        'source_dir': sourceDir,
        'format': format,
        'dry_run': dryRun,
        if (dateFrom != null) 'date_from': dateFrom,
        if (dateTo != null) 'date_to': dateTo,
      });
      final response = await _client
          .post(uri, headers: _headers, body: body)
          .timeout(const Duration(minutes: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          '[DailyApiService] flexibleImport ${response.statusCode}: ${response.body}',
        );
        return null;
      }
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[DailyApiService] flexibleImport error: $e');
      return null;
    }
  }

  /// Trigger markdown-to-graph import. Returns result summary or null on error.
  Future<Map<String, dynamic>?> triggerImport() async {
    final uri = Uri.parse('$baseUrl/api/daily/import');
    try {
      final response = await _client
          .post(uri, headers: _headers)
          .timeout(const Duration(minutes: 2));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[DailyApiService] triggerImport error: $e');
      return null;
    }
  }

  /// Fetch all Card nodes for a specific date (YYYY-MM-DD).
  ///
  /// Returns an empty list on error or if the server is unreachable.
  Future<List<AgentCard>> fetchCards(String date) async {
    final uri = Uri.parse(
      '$baseUrl/api/daily/cards',
    ).replace(queryParameters: {'date': date});
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] fetchCards ${response.statusCode}');
        return [];
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> data = decoded['cards'] as List<dynamic>? ?? [];
      return data
          .map((j) => AgentCard.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] fetchCards error: $e');
      return [];
    }
  }

  /// Fetch all unread Card nodes within a 7-day window.
  ///
  /// Returns an empty list on error or if the server is unreachable.
  Future<List<AgentCard>> fetchUnreadCards() async {
    final uri = Uri.parse('$baseUrl/api/daily/cards/unread');
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] fetchUnreadCards ${response.statusCode}');
        return [];
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> data = decoded['cards'] as List<dynamic>? ?? [];
      return data
          .map((j) => AgentCard.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] fetchUnreadCards error: $e');
      return [];
    }
  }

  /// Mark a card as read by setting its read_at timestamp.
  ///
  /// Returns true on success, false on error.
  Future<bool> markCardRead(String cardId) async {
    final uri = Uri.parse('$baseUrl/api/daily/cards/$cardId/read');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final response = await _client
          .post(uri, headers: _headers)
          .timeout(_timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('[DailyApiService] markCardRead error: $e');
      return false;
    }
  }

  /// Fetch all configured Agent nodes from the server.
  ///
  /// Returns an empty list on error or if the server is unreachable.
  /// Fetch all agents from Tool + Trigger graph (new universal primitive).
  ///
  /// Fetches Tools (mode=agent|transform) and Triggers in parallel, then
  /// joins them into [DailyAgentInfo] objects for backward-compatible UI.
  Future<List<DailyAgentInfo>> fetchAgents() async {
    final toolsUri = Uri.parse('$baseUrl/api/daily/tools');
    final triggersUri = Uri.parse('$baseUrl/api/daily/triggers');
    debugPrint('[DailyApiService] GET $toolsUri + $triggersUri');
    try {
      // Fetch tools and triggers in parallel
      final results = await Future.wait([
        _client.get(toolsUri, headers: _headers).timeout(_timeout),
        _client.get(triggersUri, headers: _headers).timeout(_timeout),
      ]);
      final toolsResponse = results[0];
      final triggersResponse = results[1];

      if (toolsResponse.statusCode < 200 || toolsResponse.statusCode >= 300) {
        debugPrint('[DailyApiService] fetchTools ${toolsResponse.statusCode}');
        return [];
      }

      final toolsDecoded =
          jsonDecode(toolsResponse.body) as Map<String, dynamic>;
      final List<dynamic> toolsData =
          toolsDecoded['tools'] as List<dynamic>? ?? [];

      // Build trigger lookup: tool_name → trigger data
      final Map<String, Map<String, dynamic>> triggerByTool = {};
      if (triggersResponse.statusCode >= 200 &&
          triggersResponse.statusCode < 300) {
        final triggersDecoded =
            jsonDecode(triggersResponse.body) as Map<String, dynamic>;
        final List<dynamic> triggersData =
            triggersDecoded['triggers'] as List<dynamic>? ?? [];
        for (final raw in triggersData) {
          final t = raw as Map<String, dynamic>;
          final invokes = t['invokes_tool'] as String? ?? '';
          if (invokes.isNotEmpty) {
            triggerByTool[invokes] = t;
          }
        }
      }

      // Filter to agent/transform mode tools and build DailyAgentInfo
      return toolsData
          .where((raw) {
            final mode = (raw as Map<String, dynamic>)['mode'] as String? ?? '';
            return mode == 'agent' || mode == 'transform';
          })
          .map((raw) {
            final j = raw as Map<String, dynamic>;
            final trigger = triggerByTool[j['name'] as String? ?? ''];

            // Derive schedule/trigger info from associated Trigger node
            bool scheduleEnabled = false;
            String scheduleTime = '03:00';
            String triggerEvent = '';
            Map<String, dynamic>? triggerFilter;

            if (trigger != null) {
              final triggerType = trigger['type'] as String? ?? '';
              final triggerEnabled =
                  trigger['enabled']?.toString().toLowerCase() == 'true';
              if (triggerType == 'schedule') {
                scheduleEnabled = triggerEnabled;
                scheduleTime = trigger['schedule_time'] as String? ?? '03:00';
              } else if (triggerType == 'event') {
                triggerEvent = trigger['event'] as String? ?? '';
                triggerFilter = parseTriggerFilter(trigger['event_filter']);
              }
            }

            // Parse can_call / scope_keys for tool list
            List<String> tools = [];
            final rawCanCall = j['can_call'];
            if (rawCanCall is String && rawCanCall.isNotEmpty) {
              try {
                final parsed = jsonDecode(rawCanCall);
                if (parsed is List) {
                  tools = parsed
                      .map((c) => (c is Map ? c['name'] as String? : c?.toString()) ?? '')
                      .where((s) => s.isNotEmpty)
                      .toList();
                }
              } catch (_) {}
            } else if (rawCanCall is List) {
              tools = rawCanCall
                  .map((c) => (c is Map ? c['name'] as String? : c?.toString()) ?? '')
                  .where((s) => s.isNotEmpty)
                  .toList();
            }

            return DailyAgentInfo(
              name: j['name'] as String? ?? '',
              displayName:
                  j['display_name'] as String? ?? j['name'] as String? ?? '',
              description: j['description'] as String? ?? '',
              systemPrompt: j['system_prompt'] as String? ?? '',
              tools: tools,
              trustLevel: j['trust_level'] as String? ?? 'sandboxed',
              scheduleEnabled: scheduleEnabled,
              scheduleTime: scheduleTime,
              lastRunAt: j['last_run_at'] as String?,
              lastProcessedDate: j['last_processed_date'] as String?,
              runCount: (j['run_count'] as num?)?.toInt() ?? 0,
              triggerEvent: triggerEvent,
              triggerFilter: triggerFilter,
              memoryMode: MemoryMode.fromString(j['memory_mode'] as String?),
              templateVersion: j['template_version'] as String?,
              userModified: j['user_modified'] == true ||
                  j['user_modified']?.toString().toLowerCase() == 'true',
              updateAvailable: j['update_available'] == true,
              isBuiltin: j['is_builtin'] == true,
              containerSlug: j['container_slug'] as String? ?? '',
            );
          })
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] fetchAgents error: $e');
      return [];
    }
  }

  /// Fetch the latest run for a tool/agent (used to detect recent failures).
  Future<AgentRunInfo?> fetchLatestAgentRun(String agentName) async {
    final uri = Uri.parse('$baseUrl/api/daily/tools/$agentName/runs/latest');
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode == 404) return null;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] fetchLatestAgentRun ${response.statusCode}');
        return null;
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return AgentRunInfo.fromJson(decoded);
    } catch (e) {
      debugPrint('[DailyApiService] fetchLatestAgentRun error: $e');
      return null;
    }
  }

  /// Fetch starter Agent templates for onboarding.
  ///
  /// Returns typed [AgentTemplate] objects parsed from the server response.
  Future<List<AgentTemplate>> fetchTemplates() async {
    final uri = Uri.parse('$baseUrl/api/daily/tools/templates');
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] fetchTemplates ${response.statusCode}');
        return [];
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> data = decoded['templates'] as List<dynamic>? ?? [];
      return data
          .map((json) => AgentTemplate.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] fetchTemplates error: $e');
      return [];
    }
  }

  /// Create a new Tool node on the server.
  ///
  /// [body] has the same shape as the Tool graph node fields.
  /// Returns the created tool data on success, or null on error.
  Future<Map<String, dynamic>?> createAgent(Map<String, dynamic> body) async {
    final uri = Uri.parse('$baseUrl/api/daily/tools');
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

  /// Delete a Tool node. Returns true on success.
  Future<bool> deleteAgent(String name) async {
    final uri = Uri.parse('$baseUrl/api/daily/tools/$name');
    debugPrint('[DailyApiService] DELETE $uri');
    try {
      final response = await _client
          .delete(uri, headers: _headers)
          .timeout(_timeout);
      return response.statusCode == 204 ||
          (response.statusCode >= 200 && response.statusCode < 300);
    } catch (e) {
      debugPrint('[DailyApiService] deleteAgent error: $e');
      return false;
    }
  }

  /// Trigger a tool run (202 Accepted — runs in background).
  ///
  /// Returns an [AgentRunResult] with status "started"/"triggered" on success.
  Future<AgentRunResult> triggerAgentRun(
    String agentName, {
    String? date,
  }) async {
    // Use /tools/{name}/run for agent/transform tools, fall back to cards endpoint
    final scope = <String, dynamic>{};
    if (date != null) scope['date'] = date;
    final uri = Uri.parse('$baseUrl/api/daily/tools/$agentName/run');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final response = await _client
          .post(uri, headers: _headers, body: jsonEncode({'scope': scope}))
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return AgentRunResult(success: true, status: 'started');
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

  /// Update fields on an existing Tool node.
  ///
  /// [fields] is a map of field names to new values, e.g.
  /// `{'system_prompt': '...', 'memory_mode': 'fresh'}`.
  /// Returns true on success.
  Future<bool> updateAgent(String name, Map<String, dynamic> fields) async {
    final uri = Uri.parse('$baseUrl/api/daily/tools/$name');
    debugPrint('[DailyApiService] PUT $uri $fields');
    try {
      final response = await _client
          .put(uri, headers: _headers, body: jsonEncode(fields))
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      debugPrint('[DailyApiService] updateAgent ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[DailyApiService] updateAgent error: $e');
      return false;
    }
  }

  /// Reset an Agent's session so the next run starts fresh.
  ///
  /// Returns true on success.
  Future<bool> resetAgent(String name) async {
    final uri = Uri.parse('$baseUrl/api/daily/tools/$name/reset');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final response = await _client
          .post(uri, headers: _headers)
          .timeout(_timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('[DailyApiService] resetAgent error: $e');
      return false;
    }
  }

  /// Reset a builtin agent to its latest template defaults.
  ///
  /// Returns true on success.
  Future<bool> resetAgentToTemplate(String name) async {
    final uri = Uri.parse('$baseUrl/api/daily/tools/$name/reset-to-template');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final response = await _client
          .post(uri, headers: _headers)
          .timeout(_timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('[DailyApiService] resetAgentToTemplate error: $e');
      return false;
    }
  }

  /// Reload the server scheduler configuration.
  ///
  /// Call after toggling schedule_enabled or changing schedule_time.
  Future<bool> reloadScheduler() async {
    final uri = Uri.parse('$baseUrl/api/scheduler/reload');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final response = await _client
          .post(uri, headers: _headers)
          .timeout(_timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('[DailyApiService] reloadScheduler error: $e');
      return false;
    }
  }

  /// Trigger a Tool on a specific entry (for event-driven tools).
  ///
  /// Returns the result from the server, or null on error.
  Future<Map<String, dynamic>?> triggerAgentOnEntry(
    String agentName,
    String entryId,
  ) async {
    final uri = Uri.parse('$baseUrl/api/daily/tools/$agentName/run');
    debugPrint('[DailyApiService] POST $uri (entry_id=$entryId)');
    try {
      final response = await _client
          .post(uri, headers: _headers, body: jsonEncode({'scope': {'entry_id': entryId}}))
          .timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      debugPrint(
        '[DailyApiService] triggerAgentOnEntry ${response.statusCode}',
      );
      return null;
    } catch (e) {
      debugPrint('[DailyApiService] triggerAgentOnEntry error: $e');
      return null;
    }
  }

  /// Fetch Agent activity (AgentRun nodes) for a specific entry.
  ///
  /// Returns a list of [AgentActivity] records, or empty list on error.
  Future<List<AgentActivity>> fetchAgentActivity(
    String entryId,
  ) async {
    final uri = Uri.parse(
      '$baseUrl/api/daily/entries/$entryId/agent-activity',
    );
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint(
          '[DailyApiService] fetchAgentActivity ${response.statusCode}',
        );
        return [];
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> data = decoded['activity'] as List<dynamic>? ?? [];
      return data
          .map((j) => AgentActivity.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] fetchAgentActivity error: $e');
      return [];
    }
  }

  void dispose() => _client.close();
}
