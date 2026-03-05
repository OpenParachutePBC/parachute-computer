import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/project.dart';

/// Service for project CRUD operations against the server API.
class ProjectService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  ProjectService({required this.baseUrl, this.apiKey}) : _client = http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'User-Agent': 'Parachute-Chat/1.0',
        if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
      };

  /// List all named projects.
  Future<List<Project>> listProjects() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/projects'),
      headers: _headers,
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to list projects: ${response.statusCode}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    final List<dynamic> data = envelope['projects'] as List<dynamic>;
    return data
        .map((e) => Project.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Create a new named project.
  Future<Project> createProject(ProjectCreate create) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/projects'),
      headers: _headers,
      body: jsonEncode(create.toJson()),
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to create project: ${response.statusCode} ${response.body}');
    }

    final Map<String, dynamic> envelope = jsonDecode(response.body);
    return Project.fromJson(envelope['project'] as Map<String, dynamic>);
  }

  /// Delete a project by slug.
  Future<void> deleteProject(String slug) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/projects/$slug'),
      headers: _headers,
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception('Failed to delete project: ${response.statusCode}');
    }
  }

  void dispose() {
    _client.close();
  }
}
