import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/brain_v2_entity.dart';
import '../models/brain_v2_schema.dart';

/// Service for communicating with the Brain v2 API.
class BrainV2Service {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  static const _requestTimeout = Duration(seconds: 15);

  BrainV2Service({required this.baseUrl, this.apiKey})
      : _client = http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty)
          'Authorization': 'Bearer $apiKey',
      };

  /// List all available schemas.
  Future<List<BrainV2Schema>> listSchemas() async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain_v2/schemas');
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        throw BrainV2Exception('Failed to fetch schemas: ${response.statusCode}');
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final schemas = (data['schemas'] as List<dynamic>? ?? [])
          .map((s) => BrainV2Schema.fromJson(s as Map<String, dynamic>))
          .toList();

      return schemas;
    } catch (e) {
      if (e is BrainV2Exception) rethrow;
      throw BrainV2Exception('Error fetching schemas: $e');
    }
  }

  /// Query entities by type with optional pagination.
  Future<List<BrainV2Entity>> queryEntities(
    String type, {
    int limit = 100,
    int offset = 0,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain_v2/entities/$type').replace(
        queryParameters: {
          'limit': limit.toString(),
          'offset': offset.toString(),
        },
      );

      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        throw BrainV2Exception('Failed to query entities: ${response.statusCode}');
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final results = (data['results'] as List<dynamic>? ?? [])
          .map((e) => BrainV2Entity.fromJson(e as Map<String, dynamic>))
          .toList();

      return results;
    } catch (e) {
      if (e is BrainV2Exception) rethrow;
      throw BrainV2Exception('Error querying entities: $e');
    }
  }

  /// Get a single entity by ID.
  Future<BrainV2Entity?> getEntity(String id) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain_v2/entities/by_id').replace(
        queryParameters: {'id': id},
      );

      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_requestTimeout);

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode != 200) {
        throw BrainV2Exception('Failed to fetch entity: ${response.statusCode}');
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      return BrainV2Entity.fromJson(data);
    } catch (e) {
      if (e is BrainV2Exception) rethrow;
      throw BrainV2Exception('Error fetching entity: $e');
    }
  }

  /// Create a new entity.
  Future<String> createEntity(
    String type,
    Map<String, dynamic> data, {
    String? commitMsg,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain_v2/entities');
      final body = json.encode({
        'entity_type': type,
        'data': data,
        if (commitMsg != null) 'commit_msg': commitMsg,
      });

      final response = await _client
          .post(uri, headers: _headers, body: body)
          .timeout(_requestTimeout);

      if (response.statusCode != 200 && response.statusCode != 201) {
        final errorData = json.decode(response.body) as Map<String, dynamic>;
        final errorMsg = errorData['detail'] ?? 'Unknown error';
        throw BrainV2Exception('Failed to create entity: $errorMsg');
      }

      final responseData = json.decode(response.body) as Map<String, dynamic>;
      return responseData['entity_id'] as String;
    } catch (e) {
      if (e is BrainV2Exception) rethrow;
      throw BrainV2Exception('Error creating entity: $e');
    }
  }

  /// Update an existing entity.
  Future<void> updateEntity(
    String id,
    Map<String, dynamic> data, {
    String? commitMsg,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain_v2/entities/$id');
      final body = json.encode({
        'data': data,
        if (commitMsg != null) 'commit_msg': commitMsg,
      });

      final response = await _client
          .put(uri, headers: _headers, body: body)
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        final errorData = json.decode(response.body) as Map<String, dynamic>;
        final errorMsg = errorData['detail'] ?? 'Unknown error';
        throw BrainV2Exception('Failed to update entity: $errorMsg');
      }
    } catch (e) {
      if (e is BrainV2Exception) rethrow;
      throw BrainV2Exception('Error updating entity: $e');
    }
  }

  /// Delete an entity.
  Future<void> deleteEntity(String id, {String? commitMsg}) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain_v2/entities/$id').replace(
        queryParameters: {
          if (commitMsg != null) 'commit_msg': commitMsg,
        },
      );

      final response = await _client
          .delete(uri, headers: _headers)
          .timeout(_requestTimeout);

      if (response.statusCode != 200 && response.statusCode != 204) {
        final errorData = json.decode(response.body) as Map<String, dynamic>;
        final errorMsg = errorData['detail'] ?? 'Unknown error';
        throw BrainV2Exception('Failed to delete entity: $errorMsg');
      }
    } catch (e) {
      if (e is BrainV2Exception) rethrow;
      throw BrainV2Exception('Error deleting entity: $e');
    }
  }

  void dispose() {
    _client.close();
  }
}

/// Exception thrown by BrainV2Service operations.
class BrainV2Exception implements Exception {
  final String message;
  BrainV2Exception(this.message);

  @override
  String toString() => message;
}
