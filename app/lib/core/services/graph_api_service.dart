import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/thing.dart';

/// Service for communicating with the Parachute Daily v2 graph API.
/// Targets /api/* on either local (Bun) or hosted (CF Workers) server.
class GraphApiService {
  final String baseUrl;
  final http.Client _client;
  final String? _apiKey;
  final Duration _timeout;

  /// Callback for instant network state changes
  void Function(bool reachable)? onReachabilityChanged;

  GraphApiService({
    required this.baseUrl,
    String? apiKey,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
    this.onReachabilityChanged,
  })  : _apiKey = apiKey,
        _client = client ?? http.Client(),
        _timeout = timeout;

  // ---- Things ----

  /// Query things by tag, date, filters.
  Future<List<Thing>?> queryThings({
    String? tag,
    String? date,
    String? sort,
    int? limit,
  }) async {
    final params = <String, String>{};
    if (tag != null) params['tag'] = tag;
    if (date != null) params['date'] = date;
    if (sort != null) params['sort'] = sort;
    if (limit != null) params['limit'] = limit.toString();

    final data = await _get('/things', params);
    if (data == null) return null;
    return (data as List).map((j) => Thing.fromJson(j as Map<String, dynamic>)).toList();
  }

  /// Create a thing with optional tags.
  Future<Thing?> createThing(
    String content, {
    String? id,
    Map<String, Map<String, dynamic>>? tags,
    String? createdBy,
  }) async {
    final body = <String, dynamic>{
      'content': content,
      if (id != null) 'id': id,
      if (tags != null) 'tags': tags,
      if (createdBy != null) 'created_by': createdBy,
    };
    final data = await _post('/things', body);
    if (data == null) return null;
    return Thing.fromJson(data as Map<String, dynamic>);
  }

  /// Get a thing by ID.
  Future<Thing?> getThing(String id, {bool includeEdges = false}) async {
    final params = <String, String>{};
    if (includeEdges) params['edges'] = 'true';
    final data = await _get('/things/$id', params);
    if (data == null) return null;
    return Thing.fromJson(data as Map<String, dynamic>);
  }

  /// Update a thing.
  Future<Thing?> updateThing(
    String id, {
    String? content,
    String? status,
    Map<String, Map<String, dynamic>>? tags,
  }) async {
    final body = <String, dynamic>{};
    if (content != null) body['content'] = content;
    if (status != null) body['status'] = status;
    if (tags != null) body['tags'] = tags;
    final data = await _patch('/things/$id', body);
    if (data == null) return null;
    return Thing.fromJson(data as Map<String, dynamic>);
  }

  /// Delete a thing.
  Future<bool> deleteThing(String id) async {
    final data = await _delete('/things/$id');
    return data != null;
  }

  // ---- Search ----

  /// Full-text search across things.
  Future<List<Thing>?> searchThings(
    String query, {
    String? tag,
    int? limit,
  }) async {
    final params = <String, String>{'q': query};
    if (tag != null) params['tag'] = tag;
    if (limit != null) params['limit'] = limit.toString();

    final data = await _get('/search', params);
    if (data == null) return null;
    return (data as List).map((j) => Thing.fromJson(j as Map<String, dynamic>)).toList();
  }

  // ---- Edges ----

  /// Create an edge between two things.
  Future<ThingEdge?> createEdge(
    String sourceId,
    String targetId,
    String relationship,
  ) async {
    final data = await _post('/edges', {
      'source_id': sourceId,
      'target_id': targetId,
      'relationship': relationship,
    });
    if (data == null) return null;
    return ThingEdge.fromJson(data as Map<String, dynamic>);
  }

  /// Get edges for a thing.
  Future<List<ThingEdge>?> getEdges(
    String thingId, {
    String? relationship,
    String direction = 'both',
  }) async {
    final params = <String, String>{'direction': direction};
    if (relationship != null) params['relationship'] = relationship;
    final data = await _get('/things/$thingId/edges', params);
    if (data == null) return null;
    return (data as List).map((j) => ThingEdge.fromJson(j as Map<String, dynamic>)).toList();
  }

  // ---- Tags ----

  /// List all tag definitions with usage counts.
  Future<List<TagDef>?> getTags() async {
    final data = await _get('/tags', {});
    if (data == null) return null;
    return (data as List).map((j) => TagDef.fromJson(j as Map<String, dynamic>)).toList();
  }

  // ---- Tools ----

  /// Execute a tool by name.
  Future<dynamic> executeTool(String name, Map<String, dynamic> params) async {
    final data = await _post('/tools/$name/execute', params);
    if (data == null) return null;
    return (data as Map<String, dynamic>)['result'];
  }

  // ---- Storage ----

  /// Upload an audio file, returns the relative storage path.
  Future<String?> uploadAudio(Uint8List data, String filename) async {
    try {
      final uri = Uri.parse('$baseUrl/storage/upload');
      final request = http.MultipartRequest('POST', uri);
      _addAuthHeaders(request.headers);
      request.files.add(http.MultipartFile.fromBytes(
        'file',
        data,
        filename: filename,
      ));

      final response = await request.send().timeout(_timeout);
      if (response.statusCode == 201) {
        final body = await response.stream.bytesToString();
        final json = jsonDecode(body) as Map<String, dynamic>;
        _notifyReachable(true);
        return json['path'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('[GraphApiService] Upload error: $e');
      _notifyReachable(false);
      return null;
    }
  }

  // ---- Registration ----

  /// Register app's builtin tags and tools.
  Future<bool> register({
    required String appName,
    List<Map<String, dynamic>>? tags,
    List<Map<String, dynamic>>? tools,
  }) async {
    final data = await _post('/register', {
      'app': appName,
      if (tags != null) 'tags': tags,
      if (tools != null) 'tools': tools,
    });
    return data != null;
  }

  // ---- Health ----

  /// Check server health.
  Future<bool> isHealthy() async {
    try {
      final uri = Uri.parse('$baseUrl/health');
      final response = await _client.get(uri, headers: _headers()).timeout(
        const Duration(seconds: 5),
      );
      final healthy = response.statusCode == 200;
      _notifyReachable(healthy);
      return healthy;
    } catch (_) {
      _notifyReachable(false);
      return false;
    }
  }

  // ---- HTTP Helpers ----

  Future<dynamic> _get(String path, Map<String, String> params) async {
    try {
      final uri = Uri.parse('$baseUrl$path').replace(queryParameters: params.isNotEmpty ? params : null);
      final response = await _client.get(uri, headers: _headers()).timeout(_timeout);
      _notifyReachable(true);
      if (response.statusCode == 200) return jsonDecode(response.body);
      if (response.statusCode == 404) return null;
      debugPrint('[GraphApiService] GET $path: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[GraphApiService] GET $path error: $e');
      _notifyReachable(false);
      return null;
    }
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body) async {
    try {
      final uri = Uri.parse('$baseUrl$path');
      final response = await _client.post(
        uri,
        headers: _headers(),
        body: jsonEncode(body),
      ).timeout(_timeout);
      _notifyReachable(true);
      if (response.statusCode == 200 || response.statusCode == 201) {
        return jsonDecode(response.body);
      }
      debugPrint('[GraphApiService] POST $path: ${response.statusCode} ${response.body}');
      return null;
    } catch (e) {
      debugPrint('[GraphApiService] POST $path error: $e');
      _notifyReachable(false);
      return null;
    }
  }

  Future<dynamic> _patch(String path, Map<String, dynamic> body) async {
    try {
      final uri = Uri.parse('$baseUrl$path');
      final response = await _client.patch(
        uri,
        headers: _headers(),
        body: jsonEncode(body),
      ).timeout(_timeout);
      _notifyReachable(true);
      if (response.statusCode == 200) return jsonDecode(response.body);
      debugPrint('[GraphApiService] PATCH $path: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[GraphApiService] PATCH $path error: $e');
      _notifyReachable(false);
      return null;
    }
  }

  Future<dynamic> _delete(String path) async {
    try {
      final uri = Uri.parse('$baseUrl$path');
      final response = await _client.delete(uri, headers: _headers()).timeout(_timeout);
      _notifyReachable(true);
      if (response.statusCode == 200) return jsonDecode(response.body);
      debugPrint('[GraphApiService] DELETE $path: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('[GraphApiService] DELETE $path error: $e');
      _notifyReachable(false);
      return null;
    }
  }

  Map<String, String> _headers() {
    final headers = {'Content-Type': 'application/json'};
    if (_apiKey != null) headers['Authorization'] = 'Bearer $_apiKey';
    return headers;
  }

  void _addAuthHeaders(Map<String, String> headers) {
    if (_apiKey != null) headers['Authorization'] = 'Bearer $_apiKey';
  }

  void _notifyReachable(bool reachable) {
    onReachabilityChanged?.call(reachable);
  }
}
