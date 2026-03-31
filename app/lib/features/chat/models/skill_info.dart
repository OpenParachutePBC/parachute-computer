/// Information about an available skill fetched from the server.
class SkillInfo {
  final String name;
  final String description;
  final String? content;
  final int? size;
  final String? modified;

  // Detail fields (populated by GET /skills/{name})
  final String? version;
  final List<String> allowedTools;
  final bool isDirectory;
  final List<SkillFile> files;
  final String? source;

  const SkillInfo({
    required this.name,
    this.description = '',
    this.content,
    this.size,
    this.modified,
    this.version,
    this.allowedTools = const [],
    this.isDirectory = false,
    this.files = const [],
    this.source,
  });

  factory SkillInfo.fromJson(Map<String, dynamic> json) {
    return SkillInfo(
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      content: json['content'] as String?,
      size: json['size'] as int?,
      modified: json['modified'] as String?,
      version: json['version'] as String?,
      allowedTools: (json['allowed_tools'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      isDirectory: json['is_directory'] as bool? ?? false,
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => SkillFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      source: json['source'] as String?,
    );
  }
}

/// A file inside a directory-based skill.
class SkillFile {
  final String name;
  final int size;

  const SkillFile({required this.name, required this.size});

  factory SkillFile.fromJson(Map<String, dynamic> json) {
    return SkillFile(
      name: json['name'] as String,
      size: json['size'] as int? ?? 0,
    );
  }

  /// Human-readable file size.
  String get humanSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
