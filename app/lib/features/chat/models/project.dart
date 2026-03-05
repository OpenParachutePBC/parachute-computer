/// Project model matching the server's Project.
///
/// Projects are named execution environments that group sandboxed
/// sessions. Private sessions (no named project) auto-get a UUID-slug project
/// on first sandboxed turn.
class Project {
  final String slug;
  final String displayName;
  final String? coreMemory;
  final DateTime createdAt;

  const Project({
    required this.slug,
    required this.displayName,
    this.coreMemory,
    required this.createdAt,
  });

  factory Project.fromJson(Map<String, dynamic> json) => Project(
        slug: json['slug'] as String,
        displayName: json['displayName'] as String,
        coreMemory: json['coreMemory'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'displayName': displayName,
        if (coreMemory != null) 'coreMemory': coreMemory,
        'createdAt': createdAt.toIso8601String(),
      };

  Project copyWith({String? slug, String? displayName, String? coreMemory, DateTime? createdAt}) =>
      Project(
        slug: slug ?? this.slug,
        displayName: displayName ?? this.displayName,
        coreMemory: coreMemory ?? this.coreMemory,
        createdAt: createdAt ?? this.createdAt,
      );
}

/// Request body for creating a new project.
class ProjectCreate {
  final String displayName;
  final String? slug;
  final String? coreMemory;

  const ProjectCreate({required this.displayName, this.slug, this.coreMemory});

  Map<String, dynamic> toJson() => {
        'displayName': displayName,
        if (slug != null) 'slug': slug,
        if (coreMemory != null) 'coreMemory': coreMemory,
      };
}
