import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/brain_entity.dart';
import '../models/brain_filter.dart';
import '../models/brain_schema.dart';

/// Service for communicating with the Brain API.
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

  /// List all available schemas.
  Future<List<BrainSchema>> listSchemas() async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/schemas');
      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        throw BrainException('Failed to fetch schemas: ${response.statusCode}');
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final schemas = (data['schemas'] as List<dynamic>? ?? [])
          .map((s) => BrainSchema.fromJson(s as Map<String, dynamic>))
          .toList();

      return schemas;
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error fetching schemas: $e');
    }
  }

  /// Query entities by type with optional pagination.
  Future<List<BrainEntity>> queryEntities(
    String type, {
    int limit = 100,
    int offset = 0,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/entities/$type').replace(
        queryParameters: {
          'limit': limit.toString(),
          'offset': offset.toString(),
        },
      );

      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_requestTimeout);

      if (response.statusCode != 200) {
        throw BrainException('Failed to query entities: ${response.statusCode}');
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      final results = (data['results'] as List<dynamic>? ?? [])
          .map((e) => BrainEntity.fromJson(e as Map<String, dynamic>))
          .toList();

      return results;
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error querying entities: $e');
    }
  }

  /// Get a single entity by ID.
  Future<BrainEntity?> getEntity(String id) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/entities/by_id').replace(
        queryParameters: {'id': id},
      );

      final response = await _client
          .get(uri, headers: _headers)
          .timeout(_requestTimeout);

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode != 200) {
        throw BrainException('Failed to fetch entity: ${response.statusCode}');
      }

      final data = json.decode(response.body) as Map<String, dynamic>;
      return BrainEntity.fromJson(data);
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error fetching entity: $e');
    }
  }

  /// Create a new entity.
  Future<String> createEntity(
    String type,
    Map<String, dynamic> data, {
    String? commitMsg,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/entities');
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
        throw BrainException('Failed to create entity: $errorMsg');
      }

      final responseData = json.decode(response.body) as Map<String, dynamic>;
      return responseData['entity_id'] as String;
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error creating entity: $e');
    }
  }

  /// Update an existing entity.
  Future<void> updateEntity(
    String id,
    Map<String, dynamic> data, {
    String? commitMsg,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/entities/$id');
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
        throw BrainException('Failed to update entity: $errorMsg');
      }
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error updating entity: $e');
    }
  }

  /// Delete an entity.
  Future<void> deleteEntity(String id, {String? commitMsg}) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/entities/$id').replace(
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
        throw BrainException('Failed to delete entity: $errorMsg');
      }
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error deleting entity: $e');
    }
  }

  // --- Schema type CRUD ---

  /// List all schema types with field definitions and entity counts.
  Future<List<BrainSchemaDetail>> listSchemaTypes() async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/types');
      final response = await _client.get(uri, headers: _headers).timeout(_requestTimeout);

      if (response.statusCode != 200) {
        throw BrainException('Failed to fetch schema types: ${response.statusCode}');
      }

      final list = json.decode(response.body) as List<dynamic>;
      return list.map((s) => BrainSchemaDetail.fromJson(s as Map<String, dynamic>)).toList();
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error fetching schema types: $e');
    }
  }

  /// Create a new schema type.
  Future<void> createSchemaType({
    required String name,
    required Map<String, Map<String, dynamic>> fields,
    String keyStrategy = 'Random',
    String? description,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/types');
      final body = json.encode({
        'name': name,
        'fields': fields,
        'key_strategy': keyStrategy,
        if (description != null) 'description': description,
      });
      final response = await _client.post(uri, headers: _headers, body: body).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        throw BrainException(data['detail']?.toString() ?? 'Failed to create type');
      }
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error creating schema type: $e');
    }
  }

  /// Update an existing schema type's fields (full replacement).
  Future<void> updateSchemaType({
    required String name,
    required Map<String, Map<String, dynamic>> fields,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/types/$name');
      final body = json.encode({'fields': fields});
      final response = await _client.put(uri, headers: _headers, body: body).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        throw BrainException(data['detail']?.toString() ?? 'Failed to update type');
      }
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error updating schema type: $e');
    }
  }

  /// Delete a schema type. Throws [BrainException] if entities exist.
  Future<void> deleteSchemaType(String name) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/types/$name');
      final response = await _client.delete(uri, headers: _headers).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        throw BrainException(data['detail']?.toString() ?? 'Failed to delete type');
      }
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error deleting schema type: $e');
    }
  }

  // --- Saved queries ---

  /// List all saved filter queries.
  Future<List<SavedQuery>> listSavedQueries() async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/queries');
      final response = await _client.get(uri, headers: _headers).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        throw BrainException('Failed to fetch saved queries: ${response.statusCode}');
      }
      final data = json.decode(response.body) as Map<String, dynamic>;
      return (data['queries'] as List<dynamic>? ?? [])
          .map((q) => SavedQuery.fromJson(q as Map<String, dynamic>))
          .toList();
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error fetching saved queries: $e');
    }
  }

  /// Save a named filter query. Returns the new query ID.
  Future<String> saveQuery({
    required String name,
    required String entityType,
    required List<BrainFilterCondition> filters,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/queries');
      final body = json.encode({
        'id': '',
        'name': name,
        'entity_type': entityType,
        'filters': filters.map((f) => f.toJson()).toList(),
      });
      final response = await _client.post(uri, headers: _headers, body: body).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        throw BrainException(data['detail']?.toString() ?? 'Failed to save query');
      }
      final data = json.decode(response.body) as Map<String, dynamic>;
      return data['id'] as String;
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error saving query: $e');
    }
  }

  /// Delete a saved query by ID.
  Future<void> deleteQuery(String queryId) async {
    try {
      final uri = Uri.parse('$baseUrl/api/brain/queries/$queryId');
      final response = await _client.delete(uri, headers: _headers).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        throw BrainException(data['detail']?.toString() ?? 'Failed to delete query');
      }
    } catch (e) {
      if (e is BrainException) rethrow;
      throw BrainException('Error deleting query: $e');
    }
  }

  void dispose() {
    _client.close();
  }
}

/// Exception thrown by BrainService operations.
class BrainException implements Exception {
  final String message;
  BrainException(this.message);

  @override
  String toString() => message;
}
