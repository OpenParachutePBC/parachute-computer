import 'dart:convert';
import 'package:http/http.dart' as http;

/// Service for the brain API (/api/brain/).
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

  /// Unified memory feed — sessions + notes merged, sorted by time.
  Future<Map<String, dynamic>> getMemory({
    int limit = 50,
    String? search,
    String? type, // 'sessions', 'notes', or null for all
  }) async {
    final uri = Uri.parse('$baseUrl/api/brain/memory').replace(
      queryParameters: {
        'limit': limit.toString(),
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
