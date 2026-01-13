/// Represents an AI agent defined in the vault
class Agent {
  final String name;
  final String path;
  final String? description;
  final String type; // 'chatbot', 'doc', 'standalone'
  final String? model;
  final List<String> tools;
  final Map<String, dynamic>? triggers; // Auto-trigger configuration

  const Agent({
    required this.name,
    required this.path,
    this.description,
    this.type = 'chatbot',
    this.model,
    this.tools = const [],
    this.triggers,
  });

  factory Agent.fromJson(Map<String, dynamic> json) {
    return Agent(
      name: json['name'] as String? ?? 'Unknown Agent',
      path: json['path'] as String? ?? '',
      description: json['description'] as String?,
      type: json['type'] as String? ?? 'chatbot',
      model: json['model'] as String?,
      tools: (json['tools'] as List<dynamic>?)
              ?.map((t) => t as String)
              .toList() ??
          [],
      triggers: json['triggers'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'path': path,
      'description': description,
      'type': type,
      'model': model,
      'tools': tools,
      if (triggers != null) 'triggers': triggers,
    };
  }

  /// Check if this is a chatbot (maintains conversation)
  bool get isChatbot => type == 'chatbot';

  /// Check if this is a document agent (processes specific document)
  bool get isDocAgent => type == 'doc';

  /// Check if this is standalone (one-shot)
  bool get isStandalone => type == 'standalone';
}

/// The default vault agent (no specific agent path)
const vaultAgent = Agent(
  name: 'Vault Agent',
  path: '',
  description: 'General assistant with access to your vault',
  type: 'chatbot',
  triggers: null,
);
