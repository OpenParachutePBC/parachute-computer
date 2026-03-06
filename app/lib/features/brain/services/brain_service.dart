import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service for the graph query API (/api/brain/).
class BrainService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  static const _timeout = Duration(seconds: 15);

  BrainService({required this.baseUrl, this.apiKey})
      : _client = http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      };

  void dispose() => _client.close();

  Future<Map<String, dynamic>> getSchema() async {
    final uri = Uri.parse('$baseUrl/api/brain/schema');
    final response = await _client.get(uri, headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('getSchema failed: ${response.statusCode} ${response.body}');
    }
    return json.decode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSessions({
    String? module,
    int limit = 30,
    bool archived = false,
  }) async {
    final uri = Uri.parse('$baseUrl/api/brain/sessions').replace(
      queryParameters: {
        if (module != null) 'module': module,
        'limit': limit.toString(),
        'archived': archived.toString(),
      },
    );
    final response = await _client.get(uri, headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('getSessions failed: ${response.statusCode}');
    }
    return json.decode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getProjects({int limit = 30}) async {
    final uri = Uri.parse('$baseUrl/api/brain/projects').replace(
      queryParameters: {'limit': limit.toString()},
    );
    final response = await _client.get(uri, headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('getProjects failed: ${response.statusCode}');
    }
    return json.decode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getDailyEntries({
    String? dateFrom,
    String? dateTo,
    int limit = 30,
  }) async {
    final uri = Uri.parse('$baseUrl/api/brain/daily/entries').replace(
      queryParameters: {
        if (dateFrom != null) 'date_from': dateFrom,
        if (dateTo != null) 'date_to': dateTo,
        'limit': limit.toString(),
      },
    );
    final response = await _client.get(uri, headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('getDailyEntries failed: ${response.statusCode}');
    }
    return json.decode(response.body) as Map<String, dynamic>;
  }

  /// Unified memory feed — sessions + notes merged, sorted by time.
  Future<Map<String, dynamic>> getMemory({
    int limit = 50,
    int offset = 0,
    String? search,
    String? type, // 'sessions', 'notes', or null for all
  }) async {
    final uri = Uri.parse('$baseUrl/api/brain/memory').replace(
      queryParameters: {
        'limit': limit.toString(),
        'offset': offset.toString(),
        if (search != null && search.isNotEmpty) 'search': search,
        if (type != null) 'type': type,
      },
    );
    final response = await _client.get(uri, headers: _headers).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('getMemory failed: ${response.statusCode}');
    }
    return json.decode(response.body) as Map<String, dynamic>;
  }
}
