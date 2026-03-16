/// ContainerEnv model matching the server's Container.
///
/// Containers are Docker execution environments that group sandboxed
/// sessions. Private sessions (no named container) auto-get a UUID-slug container
/// on first sandboxed turn.
///
/// Named "ContainerEnv" to avoid collision with Flutter's built-in Container widget.
class ContainerEnv {
  final String slug;
  final String displayName;
  final String? coreMemory;
  final bool isWorkspace;
  final DateTime createdAt;

  const ContainerEnv({
    required this.slug,
    required this.displayName,
    this.coreMemory,
    this.isWorkspace = false,
    required this.createdAt,
  });

  factory ContainerEnv.fromJson(Map<String, dynamic> json) => ContainerEnv(
        slug: json['slug'] as String,
        displayName: json['displayName'] as String,
        coreMemory: json['coreMemory'] as String?,
        isWorkspace: json['isWorkspace'] as bool? ?? false,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'displayName': displayName,
        if (coreMemory != null) 'coreMemory': coreMemory,
        'isWorkspace': isWorkspace,
        'createdAt': createdAt.toIso8601String(),
      };

  ContainerEnv copyWith({
    String? slug,
    String? displayName,
    String? coreMemory,
    bool? isWorkspace,
    DateTime? createdAt,
  }) =>
      ContainerEnv(
        slug: slug ?? this.slug,
        displayName: displayName ?? this.displayName,
        coreMemory: coreMemory ?? this.coreMemory,
        isWorkspace: isWorkspace ?? this.isWorkspace,
        createdAt: createdAt ?? this.createdAt,
      );
}

/// Request body for creating a new container.
class ContainerEnvCreate {
  final String displayName;
  final String? slug;
  final String? coreMemory;

  const ContainerEnvCreate({required this.displayName, this.slug, this.coreMemory});

  Map<String, dynamic> toJson() => {
        'displayName': displayName,
        if (slug != null) 'slug': slug,
        if (coreMemory != null) 'coreMemory': coreMemory,
      };
}
