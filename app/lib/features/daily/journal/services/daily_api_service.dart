import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/journal_entry.dart';

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

  void dispose() => _client.close();
}
