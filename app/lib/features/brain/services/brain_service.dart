import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/brain_entity.dart';
import '../models/brain_search_result.dart';

/// Service for communicating with the Brain module API.
class BrainService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  static const _requestTimeout = Duration(seconds: 15);

  BrainService({required this.baseUrl, this.apiKey})
      : _client = http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      };

  /// Search brain entities by query string.
  Future<BrainSearchResult> search(String query) async {
    final uri = Uri.parse('$baseUrl/api/brain/search').replace(
      queryParameters: {'q': query},
    );
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw Exception('Brain search failed: ${response.statusCode}');
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return BrainSearchResult.fromJson(data);
  }

  /// Get a single entity by para ID.
  Future<BrainEntity> getEntity(String paraId) async {
    final uri = Uri.parse('$baseUrl/api/brain/entities/$paraId');
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw Exception('Brain entity fetch failed: ${response.statusCode}');
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return BrainEntity.fromJson(data);
  }

  /// Resolve an entity by name.
  Future<BrainEntity> resolveByName(String name) async {
    final uri = Uri.parse('$baseUrl/api/brain/resolve/$name');
    final response = await _client
        .get(uri, headers: _headers)
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw Exception('Brain resolve failed: ${response.statusCode}');
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    return BrainEntity.fromJson(data);
  }

  /// Trigger a reload of the brain index.
  Future<void> reload() async {
    final uri = Uri.parse('$baseUrl/api/brain/reload');
    final response = await _client
        .post(uri, headers: _headers)
        .timeout(_requestTimeout);

    if (response.statusCode != 200) {
      throw Exception('Brain reload failed: ${response.statusCode}');
    }
  }

  void dispose() {
    _client.close();
  }
}
