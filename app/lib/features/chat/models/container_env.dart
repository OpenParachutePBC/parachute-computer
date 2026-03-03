/// Container environment model matching the server's ContainerEnv.
///
/// Container envs are named execution environments that group sandboxed
/// sessions. Private sessions (no named env) auto-get a UUID-slug env
/// on first sandboxed turn.
class ContainerEnv {
  final String slug;
  final String displayName;
  final DateTime createdAt;

  const ContainerEnv({
    required this.slug,
    required this.displayName,
    required this.createdAt,
  });

  factory ContainerEnv.fromJson(Map<String, dynamic> json) => ContainerEnv(
        slug: json['slug'] as String,
        displayName: json['displayName'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'slug': slug,
        'displayName': displayName,
        'createdAt': createdAt.toIso8601String(),
      };

  ContainerEnv copyWith({String? slug, String? displayName, DateTime? createdAt}) =>
      ContainerEnv(
        slug: slug ?? this.slug,
        displayName: displayName ?? this.displayName,
        createdAt: createdAt ?? this.createdAt,
      );
}

/// Request body for creating a new container env.
class ContainerEnvCreate {
  final String displayName;
  final String? slug;

  const ContainerEnvCreate({required this.displayName, this.slug});

  Map<String, dynamic> toJson() => {
        'displayName': displayName,
        if (slug != null) 'slug': slug,
      };
}
