part of 'chat_service.dart';

/// Prompts and instructions data from /api/settings/prompts
class SettingsPrompts {
  final String bridgeEnrichPrompt;
  final String bridgeObservePrompt;
  final String vaultInstructions;
  final String vaultInstructionsPath;

  const SettingsPrompts({
    required this.bridgeEnrichPrompt,
    required this.bridgeObservePrompt,
    required this.vaultInstructions,
    required this.vaultInstructionsPath,
  });

  factory SettingsPrompts.fromJson(Map<String, dynamic> json) {
    return SettingsPrompts(
      bridgeEnrichPrompt: json['bridgeEnrichPrompt'] as String? ?? '',
      bridgeObservePrompt: json['bridgeObservePrompt'] as String? ?? '',
      vaultInstructions: json['vaultInstructions'] as String? ?? '',
      vaultInstructionsPath: json['vaultInstructionsPath'] as String? ?? 'CLAUDE.md',
    );
  }
}

/// Extension for settings prompts and instructions operations
extension ChatSettingsService on ChatService {
  /// Fetch current bridge prompts and vault instructions
  Future<SettingsPrompts> fetchPrompts() async {
    try {
      final response = await client.get(
        Uri.parse('$baseUrl/api/settings/prompts'),
        headers: defaultHeaders,
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch prompts: ${response.statusCode}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return SettingsPrompts.fromJson(data);
    } catch (e) {
      debugPrint('[ChatService] Error fetching prompts: $e');
      rethrow;
    }
  }

  /// Save personal instructions to vault/CLAUDE.md
  Future<void> saveInstructions(String instructions) async {
    try {
      final response = await client.put(
        Uri.parse('$baseUrl/api/settings/instructions'),
        headers: defaultHeaders,
        body: jsonEncode({'instructions': instructions}),
      ).timeout(ChatService.requestTimeout);

      if (response.statusCode != 200) {
        throw Exception('Failed to save instructions: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[ChatService] Error saving instructions: $e');
      rethrow;
    }
  }
}
