import 'dart:async';
import 'dart:convert';
import 'dart:io';
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

      if (response.statusCode != 200) {
        debugPrint('[DailyApiService] GET entries ${response.statusCode}');
        return [];
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> data = decoded['entries'] as List<dynamic>? ?? [];
      return data
          .map((json) => JournalEntry.fromServerJson(json as Map<String, dynamic>))
          .toList();
    } on SocketException catch (e) {
      debugPrint('[DailyApiService] Offline: $e');
      return [];
    } on TimeoutException catch (e) {
      debugPrint('[DailyApiService] Timeout: $e');
      return [];
    } on http.ClientException catch (e) {
      debugPrint('[DailyApiService] HTTP error: $e');
      return [];
    } catch (e) {
      debugPrint('[DailyApiService] Error fetching entries: $e');
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

      if (response.statusCode != 200) {
        debugPrint('[DailyApiService] POST entries ${response.statusCode}');
        return null;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      // Server returns {id, path, created_at, brain_suggestions}
      // Reconstruct entry from response + what we sent using fromServerJson
      final syntheticJson = {
        'id': decoded['id'],
        'created_at': decoded['created_at'],
        'content': content,
        'metadata': {
          if (metadata != null) ...metadata,
        },
      };
      return JournalEntry.fromServerJson(syntheticJson);
    } on SocketException catch (e) {
      debugPrint('[DailyApiService] Offline (create): $e');
      return null;
    } on TimeoutException catch (e) {
      debugPrint('[DailyApiService] Timeout (create): $e');
      return null;
    } on http.ClientException catch (e) {
      debugPrint('[DailyApiService] HTTP error (create): $e');
      return null;
    } catch (e) {
      debugPrint('[DailyApiService] Error creating entry: $e');
      return null;
    }
  }

  void dispose() => _client.close();
}
