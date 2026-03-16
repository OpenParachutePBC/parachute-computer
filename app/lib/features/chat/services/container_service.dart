import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/container_env.dart';

/// Service for container CRUD operations against the server API.
class ContainerService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  ContainerService({required this.baseUrl, this.apiKey}) : _client = http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'User-Agent': 'Parachute-Chat/1.0',
        if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
      };

  /// List workspace containers only (is_workspace=true).
  Future<List<ContainerEnv>> listContainers() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/containers?workspace=true'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to list containers: ${response.statusCode}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    final List<dynamic> data = envelope['containers'] as List<dynamic>;
    return data
        .map((e) => ContainerEnv.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// List all containers (workspaces + auto-sandboxes).
  Future<List<ContainerEnv>> listAllContainers() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/containers'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to list containers: ${response.statusCode}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    final List<dynamic> data = envelope['containers'] as List<dynamic>;
    return data
        .map((e) => ContainerEnv.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Create a new named container.
  Future<ContainerEnv> createContainer(ContainerEnvCreate create) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/containers'),
      headers: _headers,
      body: jsonEncode(create.toJson()),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to create container: ${response.statusCode} ${response.body}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    return ContainerEnv.fromJson(envelope['container'] as Map<String, dynamic>);
  }

  /// Update a container's display name or core memory.
  Future<ContainerEnv> updateContainer(
    String slug, {
    String? displayName,
    String? coreMemory,
  }) async {
    final body = <String, dynamic>{};
    if (displayName != null) body['displayName'] = displayName;
    if (coreMemory != null) body['coreMemory'] = coreMemory;

    final response = await _client.patch(
      Uri.parse('$baseUrl/api/containers/$slug'),
      headers: _headers,
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to update container: ${response.statusCode} ${response.body}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    return ContainerEnv.fromJson(envelope['container'] as Map<String, dynamic>);
  }

  /// Delete a container by slug.
  Future<void> deleteContainer(String slug) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/containers/$slug'),
      headers: _headers,
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Failed to delete container: ${response.statusCode}');
    }
  }

  void dispose() {
    _client.close();
  }
}
