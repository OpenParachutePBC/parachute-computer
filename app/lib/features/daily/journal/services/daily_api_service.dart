import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  static const _timeout = Duration(seconds: 15);

  DailyApiService({required this.baseUrl, this.apiKey}) : _client = http.Client();

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'User-Agent': 'Parachute-Daily/1.0',
    if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
  };

  /// Fetch entries for a specific date (YYYY-MM-DD).
  ///
  /// Returns an empty list on network error so callers can show pending-only UI.
  Future<List<JournalEntry>> getEntries({required String date}) async {
    final uri = Uri.parse('$baseUrl/api/daily/entries').replace(
      queryParameters: {'date': date, 'limit': '100'},
    );
    debugPrint('[DailyApiService] GET $uri');
    try {
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] GET entries ${response.statusCode}');
        return [];
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> data = decoded['entries'] as List<dynamic>? ?? [];
      return data
          .map((json) => JournalEntry.fromServerJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[DailyApiService] getEntries error: $e');
      return [];
    }
  }

  /// Create a new entry on the server.
  ///
  /// Returns the created [JournalEntry] on success, or null if offline / error.
  Future<JournalEntry?> createEntry({
    required String content,
    Map<String, dynamic>? metadata,
  }) async {
    final uri = Uri.parse('$baseUrl/api/daily/entries');
    debugPrint('[DailyApiService] POST $uri');
    try {
      final body = jsonEncode({
        'content': content,
        if (metadata != null) 'metadata': metadata,
      });
      final response = await _client
          .post(uri, headers: _headers, body: body)
          .timeout(_timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[DailyApiService] POST entries ${response.statusCode}');
        return null;
      }

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
        debugPrint('[DailyApiService] PATCH entries/$entryId ${response.statusCode}');
        return null;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      return JournalEntry.fromServerJson(decoded);
    } catch (e) {
      debugPrint('[DailyApiService] updateEntry error: $e');
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

      if (response.statusCode == 404 || response.statusCode == 204 ||
          (response.statusCode >= 200 && response.statusCode < 300)) {
        return true;
      }
      debugPrint('[DailyApiService] DELETE entries/$entryId ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[DailyApiService] deleteEntry error: $e');
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
      final dateStr = date ?? _todayStr();
      final request = http.MultipartRequest('POST', uri)
        ..files.add(await http.MultipartFile.fromPath('file', audioFile.path))
        ..fields['date'] = dateStr;
      if (apiKey != null && apiKey!.isNotEmpty) {
        request.headers['X-API-Key'] = apiKey!;
      }
      final streamed = await request.send().timeout(const Duration(seconds: 30));
      if (streamed.statusCode == 201) {
        final body = jsonDecode(await streamed.stream.bytesToString()) as Map<String, dynamic>;
        return body['path'] as String?;
      }
      debugPrint('[DailyApiService] uploadAudio ${streamed.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[DailyApiService] uploadAudio error: $e');
      return null;
    }
  }

  static String _todayStr() {
    final now = DateTime.now();
    final y = now.year.toString();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Keyword search across all entries.
  ///
  /// Returns empty list on error or when offline.
  Future<List<ApiSearchResult>> searchEntries(String query, {int limit = 30}) async {
    if (query.trim().isEmpty) return [];
    final uri = Uri.parse('$baseUrl/api/daily/entries/search').replace(
      queryParameters: {'q': query, 'limit': '$limit'},
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
        debugPrint('[DailyApiService] flexibleImport ${response.statusCode}: ${response.body}');
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

  void dispose() => _client.close();
}
