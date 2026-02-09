/// Workspace model matching server's WorkspaceConfig.
///
/// Workspaces are named capability sets that control what MCPs, skills,
/// agents, and plugins are available in sessions created under them.
class Workspace {
  final String name;
  final String slug;
  final String description;
  final String trustLevel;
  final String? workingDirectory;
  final String? model;
  final WorkspaceCapabilities capabilities;

  const Workspace({
    required this.name,
    required this.slug,
    this.description = '',
    this.trustLevel = 'trusted',
    this.workingDirectory,
    this.model,
    this.capabilities = const WorkspaceCapabilities(),
  });

  factory Workspace.fromJson(Map<String, dynamic> json) {
    return Workspace(
      name: json['name'] as String,
      slug: json['slug'] as String,
      description: json['description'] as String? ?? '',
      trustLevel: json['trust_level'] as String? ?? 'trusted',
      workingDirectory: json['working_directory'] as String?,
      model: json['model'] as String?,
      capabilities: json['capabilities'] != null
          ? WorkspaceCapabilities.fromJson(json['capabilities'] as Map<String, dynamic>)
          : const WorkspaceCapabilities(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'slug': slug,
      'description': description,
      'trust_level': trustLevel,
      if (workingDirectory != null) 'working_directory': workingDirectory,
      if (model != null) 'model': model,
      'capabilities': capabilities.toJson(),
    };
  }
}

/// Capability sets for a workspace.
///
/// Each capability can be "all", "none", or a list of named items.
class WorkspaceCapabilities {
  /// MCP servers: "all", "none", or list of names
  final dynamic mcps;

  /// Skills: "all", "none", or list of names
  final dynamic skills;

  /// Agents: "all", "none", or list of names
  final dynamic agents;

  const WorkspaceCapabilities({
    this.mcps = 'all',
    this.skills = 'all',
    this.agents = 'all',
  });

  factory WorkspaceCapabilities.fromJson(Map<String, dynamic> json) {
    return WorkspaceCapabilities(
      mcps: json['mcps'] ?? 'all',
      skills: json['skills'] ?? 'all',
      agents: json['agents'] ?? 'all',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'mcps': mcps,
      'skills': skills,
      'agents': agents,
    };
  }

  /// Human-readable summary of capabilities.
  String get summary {
    final parts = <String>[];
    if (mcps is String) {
      parts.add('MCPs: $mcps');
    } else if (mcps is List) {
      parts.add('MCPs: ${(mcps as List).length}');
    }
    if (skills is String) {
      parts.add('Skills: $skills');
    } else if (skills is List) {
      parts.add('Skills: ${(skills as List).length}');
    }
    if (agents is String) {
      parts.add('Agents: $agents');
    } else if (agents is List) {
      parts.add('Agents: ${(agents as List).length}');
    }
    return parts.join(', ');
  }
}
