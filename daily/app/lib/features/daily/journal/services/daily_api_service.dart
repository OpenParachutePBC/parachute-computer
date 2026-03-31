import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/entry_metadata.dart' show TranscriptionStatus;
import '../models/journal_entry.dart';

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
  // Registration — ensure required tags/tools exist on server
  // ===========================================================================

  /// Register the app's required tags and tools with the server.
  ///
  /// Called on connect to ensure the server has the daily-note and card
  /// tag definitions and any builtin tools the app expects.
  Future<bool> registerApp() async {
    final uri = Uri.parse('$baseUrl/api/register');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final response = await _client.post(
        uri,
        headers: _headers,
        body: jsonEncode({
          'app': 'parachute-daily',
          'tags': [
            {
              'name': 'daily-note',
              'display_name': 'Daily Note',
              'description': 'A journal entry — text, voice, or handwriting',
              'schema': [
                {'name': 'entry_type', 'type': 'select', 'options': ['text', 'voice', 'handwriting'], 'default': 'text'},
                {'name': 'audio_url', 'type': 'text', 'description': 'URL or path to audio file'},
                {'name': 'duration_seconds', 'type': 'number'},
                {'name': 'transcription_status', 'type': 'select', 'options': ['pending', 'processing', 'complete', 'failed']},
                {'name': 'cleanup_status', 'type': 'select', 'options': ['pending', 'processing', 'complete', 'failed']},
                {'name': 'date', 'type': 'date', 'description': 'Journal date (YYYY-MM-DD)'},
              ],
            },
            {
              'name': 'card',
              'display_name': 'Card',
              'description': 'An AI-generated output — reflection, summary, briefing',
              'schema': [
                {'name': 'card_type', 'type': 'select', 'options': ['reflection', 'summary', 'briefing', 'default']},
                {'name': 'read_at', 'type': 'datetime', 'description': 'When the user read this card'},
                {'name': 'date', 'type': 'date', 'description': 'Date this card covers'},
              ],
            },
          ],
        }),
      ).timeout(_timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        onReachabilityChanged?.call(true);
        debugPrint('[DailyApiService] App registered successfully');
        return true;
      }
      debugPrint('[DailyApiService] registerApp ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[DailyApiService] registerApp error: $e');
      onReachabilityChanged?.call(false);
      return false;
    }
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
