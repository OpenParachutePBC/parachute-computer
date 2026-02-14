/// Represents a directory that can be used as a working directory for chat sessions
///
/// Working directories allow Claude to operate on external codebases while
/// keeping session history in the vault.
class WorkingDirectory {
  /// Full path to the directory
  final String path;

  /// Just the directory name (e.g., "parachute")
  final String name;

  /// Type of directory: 'vault' for home vault, 'recent' for recently used
  final String type;

  /// Human-readable description
  final String description;

  const WorkingDirectory({
    required this.path,
    required this.name,
    required this.type,
    required this.description,
  });

  /// Whether this is the home vault directory
  bool get isVault => type == 'vault';

  /// Whether this was recently used
  bool get isRecent => type == 'recent';

  factory WorkingDirectory.fromJson(Map<String, dynamic> json) {
    return WorkingDirectory(
      path: json['path'] as String,
      name: json['name'] as String,
      type: json['type'] as String? ?? 'recent',
      description: json['description'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'type': type,
        'description': description,
      };

  @override
  String toString() => 'WorkingDirectory($name, type: $type)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkingDirectory &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;
}

/// Response from the /api/directories endpoint
class DirectoriesInfo {
  /// Path to the home vault
  final String homeVault;

  /// All available directories (vault + recent)
  final List<WorkingDirectory> directories;

  const DirectoriesInfo({
    required this.homeVault,
    required this.directories,
  });

  /// Get just the vault directory
  WorkingDirectory? get vault =>
      directories.where((d) => d.isVault).firstOrNull;

  /// Get recently used directories (excluding vault)
  List<WorkingDirectory> get recent =>
      directories.where((d) => d.isRecent).toList();

  factory DirectoriesInfo.fromJson(Map<String, dynamic> json) {
    final dirList = json['directories'] as List<dynamic>? ?? [];
    return DirectoriesInfo(
      homeVault: json['homeVault'] as String,
      directories: dirList
          .map((d) => WorkingDirectory.fromJson(d as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'homeVault': homeVault,
        'directories': directories.map((d) => d.toJson()).toList(),
      };
}
