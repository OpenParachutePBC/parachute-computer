part of 'chat_service.dart';

/// Extension for authentication and API key management
extension ChatAuthService on ChatService {
  /// Get list of API keys (metadata only, no actual keys)
  Future<ApiKeysResponse> getApiKeys() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/auth/keys'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get API keys: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ApiKeysResponse.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting API keys: $e');
      rethrow;
    }
  }

  /// Create a new API key
  ///
  /// Returns the full key exactly once - it cannot be retrieved again.
  Future<ApiKeyCreated> createApiKey(String label) async {
    try {
      final response = await client.post(
        Uri.parse('$baseUrl/api/auth/keys'),
        headers: defaultHeaders,
        body: jsonEncode({'label': label}),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to create API key: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ApiKeyCreated.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error creating API key: $e');
      rethrow;
    }
  }

  /// Delete an API key
  Future<void> deleteApiKey(String keyId) async {
    try {
      final response = await client.delete(
        Uri.parse('$baseUrl/api/auth/keys/$keyId'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to delete API key: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error deleting API key: $e');
      rethrow;
    }
  }

  /// Get current auth settings
  Future<AuthSettings> getAuthSettings() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/auth/settings'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to get auth settings: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return AuthSettings.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error getting auth settings: $e');
      rethrow;
    }
  }

  /// Fetch Claude usage limits
  ///
  /// Returns usage data for 5-hour and 7-day windows.
  /// This data comes from Claude Code's OAuth credentials.
  Future<ClaudeUsage> getUsage() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/usage'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        return ClaudeUsage(
          error: 'Failed to fetch usage: ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return ClaudeUsage.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error fetching usage: $e');
      return ClaudeUsage(error: e.toString());
    }
  }
}

/// Information about an API key (without the actual key)
class ApiKeyInfo {
  final String id;
  final String label;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  const ApiKeyInfo({
    required this.id,
    required this.label,
    required this.createdAt,
    this.lastUsedAt,
  });

  factory ApiKeyInfo.fromJson(Map<String, dynamic> json) {
    return ApiKeyInfo(
      id: json['id'] as String,
      label: json['label'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      lastUsedAt: json['last_used_at'] != null
          ? DateTime.parse(json['last_used_at'] as String)
          : null,
    );
  }
}

/// Response from listing API keys
class ApiKeysResponse {
  final List<ApiKeyInfo> keys;
  final String authMode;

  const ApiKeysResponse({required this.keys, required this.authMode});

  factory ApiKeysResponse.fromJson(Map<String, dynamic> json) {
    final keysList = json['keys'] as List<dynamic>? ?? [];
    return ApiKeysResponse(
      keys: keysList.map((k) => ApiKeyInfo.fromJson(k as Map<String, dynamic>)).toList(),
      authMode: json['auth_mode'] as String? ?? 'remote',
    );
  }
}

/// Response from creating an API key
class ApiKeyCreated {
  final String id;
  final String label;
  final String key; // The actual key - only shown once!
  final DateTime createdAt;

  const ApiKeyCreated({
    required this.id,
    required this.label,
    required this.key,
    required this.createdAt,
  });

  factory ApiKeyCreated.fromJson(Map<String, dynamic> json) {
    return ApiKeyCreated(
      id: json['id'] as String,
      label: json['label'] as String,
      key: json['key'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// Auth settings from server
class AuthSettings {
  final String requireAuth;
  final int keyCount;

  const AuthSettings({required this.requireAuth, required this.keyCount});

  factory AuthSettings.fromJson(Map<String, dynamic> json) {
    return AuthSettings(
      requireAuth: json['require_auth'] as String? ?? 'remote',
      keyCount: json['key_count'] as int? ?? 0,
    );
  }
}
