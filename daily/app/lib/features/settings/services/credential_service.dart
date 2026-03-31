import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Model representing a credential helper manifest from the server.
class CredentialHelperManifest {
  final String name;
  final String displayName;
  final String description;
  final List<SetupMethod> setupMethods;
  final ProviderCapabilities provides;
  final bool configured;
  final String? activeMethod;

  CredentialHelperManifest({
    required this.name,
    required this.displayName,
    required this.description,
    required this.setupMethods,
    required this.provides,
    this.configured = false,
    this.activeMethod,
  });

  factory CredentialHelperManifest.fromJson(String name, Map<String, dynamic> json) {
    return CredentialHelperManifest(
      name: name,
      displayName: json['display_name'] ?? name,
      description: json['description'] ?? '',
      setupMethods: (json['setup_methods'] as List? ?? [])
          .map((m) => SetupMethod.fromJson(m))
          .toList(),
      provides: ProviderCapabilities.fromJson(json['provides'] ?? {}),
      configured: json['configured'] ?? false,
      activeMethod: json['active_method'],
    );
  }
}

class SetupMethod {
  final String id;
  final String label;
  final bool recommended;
  final String help;
  final List<SetupField> fields;

  SetupMethod({
    required this.id,
    required this.label,
    this.recommended = false,
    this.help = '',
    required this.fields,
  });

  factory SetupMethod.fromJson(Map<String, dynamic> json) {
    return SetupMethod(
      id: json['id'] ?? '',
      label: json['label'] ?? '',
      recommended: json['recommended'] ?? false,
      help: json['help'] ?? '',
      fields: (json['fields'] as List? ?? [])
          .map((f) => SetupField.fromJson(f))
          .toList(),
    );
  }
}

class SetupField {
  final String id;
  final String label;
  final String type; // "string", "secret", "file"
  final String help;
  final bool required;

  SetupField({
    required this.id,
    required this.label,
    this.type = 'string',
    this.help = '',
    this.required = true,
  });

  factory SetupField.fromJson(Map<String, dynamic> json) {
    return SetupField(
      id: json['id'] ?? '',
      label: json['label'] ?? '',
      type: json['type'] ?? 'string',
      help: json['help'] ?? '',
      required: json['required'] ?? true,
    );
  }
}

class ProviderCapabilities {
  final List<String> envVars;
  final List<String> scripts;

  ProviderCapabilities({this.envVars = const [], this.scripts = const []});

  factory ProviderCapabilities.fromJson(Map<String, dynamic> json) {
    return ProviderCapabilities(
      envVars: (json['env_vars'] as List?)?.cast<String>() ?? [],
      scripts: (json['scripts'] as List?)?.cast<String>() ?? [],
    );
  }
}

/// Service for communicating with the credential broker API.
class CredentialService {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;

  CredentialService({
    required this.baseUrl,
    this.apiKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey != null && apiKey!.isNotEmpty) 'X-Api-Key': apiKey!,
      };

  /// Fetch all credential helper manifests.
  Future<Map<String, CredentialHelperManifest>> getHelpers() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/api/credentials/helpers'), headers: _headers)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('[CredentialService] getHelpers failed: ${response.statusCode}');
        return {};
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return data.map(
        (name, json) => MapEntry(
          name,
          CredentialHelperManifest.fromJson(name, json as Map<String, dynamic>),
        ),
      );
    } catch (e) {
      debugPrint('[CredentialService] getHelpers error: $e');
      return {};
    }
  }

  /// Configure a credential helper.
  Future<bool> setupHelper({
    required String name,
    required String method,
    required Map<String, String> fields,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$baseUrl/api/credentials/setup'),
            headers: _headers,
            body: jsonEncode({
              'name': name,
              'method': method,
              'fields': fields,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        return true;
      }
      debugPrint('[CredentialService] setup failed: ${response.statusCode} ${response.body}');
      return false;
    } catch (e) {
      debugPrint('[CredentialService] setup error: $e');
      return false;
    }
  }

  /// Remove a configured credential helper.
  Future<bool> removeHelper(String name) async {
    try {
      final response = await _client
          .delete(
            Uri.parse('$baseUrl/api/credentials/$name'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[CredentialService] remove error: $e');
      return false;
    }
  }
}
