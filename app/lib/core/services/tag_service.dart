import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:parachute/core/config/app_config.dart';
import 'package:parachute/core/providers/app_state_provider.dart'
    show apiKeyProvider;
import 'package:parachute/core/providers/feature_flags_provider.dart'
    show aiServerUrlProvider;

/// Riverpod provider for [TagService] — mirrors dailyApiServiceProvider pattern.
final tagServiceProvider = Provider<TagService>((ref) {
  final urlAsync = ref.watch(aiServerUrlProvider);
  final baseUrl = urlAsync.valueOrNull ?? AppConfig.defaultServerUrl;
  final apiKeyAsync = ref.watch(apiKeyProvider);
  final apiKey = apiKeyAsync.valueOrNull;

  final service = TagService(baseUrl: baseUrl, apiKey: apiKey);
  ref.onDispose(() => service.dispose());
  return service;
});

/// Client for the universal tag API at /api/tags/.
///
/// Works across entity types: chat, note, card, entity, agent.
class TagService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  static const _timeout = Duration(seconds: 10);

  TagService({required this.baseUrl, this.apiKey})
      : _client = http.Client();

  /// Close the underlying HTTP client.
  void dispose() => _client.close();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'User-Agent': 'Parachute/1.0',
        if (apiKey != null && apiKey!.isNotEmpty) 'X-API-Key': apiKey!,
      };

  /// Fetch all tags with usage counts.
  Future<List<TagInfo>> listTags() async {
    final uri = Uri.parse('$baseUrl/api/tags');
    try {
      final response =
          await _client.get(uri, headers: _headers).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('[TagService] listTags ${response.statusCode}');
        return [];
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> data = decoded['tags'] as List<dynamic>? ?? [];
      return data
          .map((j) => TagInfo.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[TagService] listTags error: $e');
      return [];
    }
  }

  /// Get tags for a specific entity.
  Future<List<String>> getEntityTags(String entityType, String entityId) async {
    final uri = Uri.parse('$baseUrl/api/tags/$entityType/$entityId');
    try {
      final response =
          await _client.get(uri, headers: _headers).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return [];
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> tags = decoded['tags'] as List<dynamic>? ?? [];
      return tags.cast<String>();
    } catch (e) {
      debugPrint('[TagService] getEntityTags error: $e');
      return [];
    }
  }

  /// Add a tag to an entity.
  Future<bool> addTag(String entityType, String entityId, String tag) async {
    final uri = Uri.parse('$baseUrl/api/tags/$entityType/$entityId');
    try {
      final response = await _client
          .post(uri,
              headers: _headers, body: jsonEncode({'tag': tag}))
          .timeout(_timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('[TagService] addTag error: $e');
      return false;
    }
  }

  /// Remove a tag from an entity.
  Future<bool> removeTag(
      String entityType, String entityId, String tag) async {
    final uri = Uri.parse('$baseUrl/api/tags/$entityType/$entityId/$tag');
    try {
      final response =
          await _client.delete(uri, headers: _headers).timeout(_timeout);
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('[TagService] removeTag error: $e');
      return false;
    }
  }
}

/// Tag with usage count from the server.
class TagInfo {
  final String tag;
  final String description;
  final int count;

  const TagInfo({required this.tag, this.description = '', this.count = 0});

  factory TagInfo.fromJson(Map<String, dynamic> json) {
    return TagInfo(
      tag: json['tag'] as String? ?? '',
      description: json['description'] as String? ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
    );
  }
}
