part of 'chat_service.dart';

/// API provider config returned by the server (keys redacted).
class ApiProviderConfig {
  final String name;
  final String label;
  final String baseUrl;
  final String keyHint;
  final String? defaultModel;
  final bool active;

  const ApiProviderConfig({
    required this.name,
    required this.label,
    required this.baseUrl,
    required this.keyHint,
    this.defaultModel,
    this.active = false,
  });

  factory ApiProviderConfig.fromJson(Map<String, dynamic> json) {
    return ApiProviderConfig(
      name: json['name'] as String,
      label: json['label'] as String? ?? json['name'] as String,
      baseUrl: json['base_url'] as String? ?? '',
      keyHint: json['key_hint'] as String? ?? '',
      defaultModel: json['default_model'] as String?,
      active: json['active'] as bool? ?? false,
    );
  }
}

/// Extension for API provider management (bring your own backend).
extension ChatProviderService on ChatService {
  /// Fetch all configured API providers and the active one.
  Future<({String? active, List<ApiProviderConfig> providers})> fetchProviders() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/providers'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch providers: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final active = data['active'] as String?;
      final providersList = (data['providers'] as List<dynamic>?)
              ?.map((p) => ApiProviderConfig.fromJson(p as Map<String, dynamic>))
              .toList() ??
          [];

      return (active: active, providers: providersList);
    } catch (e) {
      debugPrint('[ChatService] Error fetching providers: $e');
      rethrow;
    }
  }

  /// Add or update a named API provider.
  Future<void> addProvider({
    required String name,
    required String providerBaseUrl,
    required String apiKey,
    String? label,
    String? defaultModel,
  }) async {
    try {
      final body = <String, dynamic>{
        'base_url': providerBaseUrl,
        'api_key': apiKey,
        if (label != null) 'label': label,
        if (defaultModel != null) 'default_model': defaultModel,
      };

      final response = await client.post(
        Uri.parse('$baseUrl/api/providers/$name'),
        headers: defaultHeaders,
        body: jsonEncode(body),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 201) {
        throw Exception('Failed to add provider: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error adding provider: $e');
      rethrow;
    }
  }

  /// Remove a named API provider.
  Future<void> removeProvider(String name) async {
    try {
      final response = await client.delete(
        Uri.parse('$baseUrl/api/providers/$name'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to remove provider: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error removing provider: $e');
      rethrow;
    }
  }

  /// Switch the active API provider (null = Anthropic default).
  Future<String?> setActiveProvider(String? providerName) async {
    try {
      final response = await client.put(
        Uri.parse('$baseUrl/api/providers/active'),
        headers: defaultHeaders,
        body: jsonEncode({'provider': providerName}),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to set active provider: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data['effective_model'] as String?;
    } catch (e) {
      debugPrint('[ChatService] Error setting active provider: $e');
      rethrow;
    }
  }
}
