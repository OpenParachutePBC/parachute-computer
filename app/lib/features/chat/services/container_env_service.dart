import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/container_env.dart';

/// Service for container env CRUD operations against the server API.
class ContainerEnvService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  ContainerEnvService({required this.baseUrl, this.apiKey}) : _client = http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'User-Agent': 'Parachute-Chat/1.0',
        if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
      };

  /// List all named container envs.
  Future<List<ContainerEnv>> listContainerEnvs() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/containers'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to list container envs: ${response.statusCode}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    final List<dynamic> data = envelope['containers'] as List<dynamic>;
    return data
        .map((e) => ContainerEnv.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Create a new named container env.
  Future<ContainerEnv> createContainerEnv(ContainerEnvCreate create) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/containers'),
      headers: _headers,
      body: jsonEncode(create.toJson()),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to create container env: ${response.statusCode} ${response.body}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    return ContainerEnv.fromJson(envelope['container'] as Map<String, dynamic>);
  }

  /// Delete a container env by slug.
  Future<void> deleteContainerEnv(String slug) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/containers/$slug'),
      headers: _headers,
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Failed to delete container env: ${response.statusCode}');
    }
  }

  void dispose() {
    _client.close();
  }
}
