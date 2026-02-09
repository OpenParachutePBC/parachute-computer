import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/workspace.dart';

/// Service for workspace CRUD operations against the server API.
class WorkspaceService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  WorkspaceService({required this.baseUrl, this.apiKey}) : _client = http.Client();

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'User-Agent': 'Parachute-Chat/1.0',
    if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
  };

  /// List all workspaces.
  Future<List<Workspace>> listWorkspaces() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/workspaces'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to list workspaces: ${response.statusCode}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    final List<dynamic> data = envelope['workspaces'] as List<dynamic>;
    return data.map((json) => Workspace.fromJson(json as Map<String, dynamic>)).toList();
  }

  /// Get a single workspace by slug.
  Future<Workspace?> getWorkspace(String slug) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/workspaces/$slug'),
      headers: _headers,
    );

    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw Exception('Failed to get workspace: ${response.statusCode}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    return Workspace.fromJson(envelope['workspace'] as Map<String, dynamic>);
  }

  /// Create a new workspace.
  Future<Workspace> createWorkspace({
    required String name,
    String description = '',
    String defaultTrustLevel = 'trusted',
    String? workingDirectory,
    String? model,
    WorkspaceCapabilities? capabilities,
  }) async {
    final body = {
      'name': name,
      'description': description,
      'default_trust_level': defaultTrustLevel,
      if (workingDirectory != null) 'working_directory': workingDirectory,
      if (model != null) 'model': model,
      if (capabilities != null) 'capabilities': capabilities.toJson(),
    };

    final response = await _client.post(
      Uri.parse('$baseUrl/api/workspaces'),
      headers: _headers,
      body: jsonEncode(body),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to create workspace: ${response.statusCode} ${response.body}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    return Workspace.fromJson(envelope['workspace'] as Map<String, dynamic>);
  }

  /// Update a workspace.
  Future<Workspace> updateWorkspace(String slug, Map<String, dynamic> updates) async {
    final response = await _client.put(
      Uri.parse('$baseUrl/api/workspaces/$slug'),
      headers: _headers,
      body: jsonEncode(updates),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to update workspace: ${response.statusCode}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    return Workspace.fromJson(envelope['workspace'] as Map<String, dynamic>);
  }

  /// Delete a workspace.
  Future<void> deleteWorkspace(String slug) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/workspaces/$slug'),
      headers: _headers,
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Failed to delete workspace: ${response.statusCode}');
    }
  }

  void dispose() {
    _client.close();
  }
}
