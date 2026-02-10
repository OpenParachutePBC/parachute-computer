/// Information about an installed plugin fetched from the server.
class PluginInfo {
  final String slug;
  final String name;
  final String version;
  final String description;
  final String? author;
  final String source; // "parachute" or "user"
  final String? sourceUrl;
  final String path;
  final List<String> skills;
  final List<String> agents;
  final List<String> mcpNames;
  final String? installedAt;

  const PluginInfo({
    required this.slug,
    required this.name,
    this.version = '0.0.0',
    this.description = '',
    this.author,
    this.source = 'parachute',
    this.sourceUrl,
    required this.path,
    this.skills = const [],
    this.agents = const [],
    this.mcpNames = const [],
    this.installedAt,
  });

  factory PluginInfo.fromJson(Map<String, dynamic> json) {
    return PluginInfo(
      slug: json['slug'] as String,
      name: json['name'] as String,
      version: json['version'] as String? ?? '0.0.0',
      description: json['description'] as String? ?? '',
      author: json['author'] as String?,
      source: json['source'] as String? ?? 'parachute',
      sourceUrl: json['sourceUrl'] as String?,
      path: json['path'] as String? ?? '',
      skills: (json['skills'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      agents: (json['agents'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      mcpNames: (json['mcps'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      installedAt: json['installedAt'] as String?,
    );
  }

  /// Display label: capitalize and humanize the slug.
  String get displayName {
    if (name.isNotEmpty && name != slug) return name;
    return slug
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : '')
        .join(' ');
  }

  /// Whether this is a user plugin (from ~/.claude/plugins/).
  bool get isUserPlugin => source == 'user';

  /// Whether this plugin was installed from a remote URL.
  bool get isRemote => sourceUrl != null && sourceUrl!.isNotEmpty;

  /// Total number of capabilities provided by this plugin.
  int get capabilityCount => skills.length + agents.length + mcpNames.length;
}
