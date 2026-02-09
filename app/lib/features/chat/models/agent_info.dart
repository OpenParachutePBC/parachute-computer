/// Information about an available agent fetched from the server.
class AgentInfo {
  final String name;
  final String? description;
  final String type;
  final String? model;
  final String? path;
  final String source; // "builtin", "vault_agents", "custom_agents"
  final List<String> tools;

  const AgentInfo({
    required this.name,
    this.description,
    this.type = 'chatbot',
    this.model,
    this.path,
    required this.source,
    this.tools = const [],
  });

  factory AgentInfo.fromJson(Map<String, dynamic> json) {
    return AgentInfo(
      name: json['name'] as String,
      description: json['description'] as String?,
      type: json['type'] as String? ?? 'chatbot',
      model: json['model'] as String?,
      path: json['path'] as String?,
      source: json['source'] as String? ?? 'builtin',
      tools: (json['tools'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
    );
  }

  /// Display label: capitalize first letter of name, replace hyphens with spaces.
  String get displayName {
    if (name == 'vault-agent') return 'Default';
    return name
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '')
        .join(' ');
  }

  /// Whether this is the built-in default agent.
  bool get isBuiltin => source == 'builtin';
}
