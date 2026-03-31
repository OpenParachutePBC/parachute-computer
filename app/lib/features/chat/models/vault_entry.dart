/// Represents an entry (file or directory) in the vault
class VaultEntry {
  final String name;
  final String type; // 'file' or 'directory'
  final String path;
  final String relativePath;
  final bool isSymlink;
  final String? symlinkTarget;
  final bool hasAgentsMd;
  final bool hasClaudeMd;
  final bool isGitRepo;
  final DateTime? lastModified;
  final int? size;

  const VaultEntry({
    required this.name,
    required this.type,
    required this.path,
    required this.relativePath,
    this.isSymlink = false,
    this.symlinkTarget,
    this.hasAgentsMd = false,
    this.hasClaudeMd = false,
    this.isGitRepo = false,
    this.lastModified,
    this.size,
  });

  bool get isDirectory => type == 'directory';
  bool get isFile => type == 'file';

  /// Whether this folder has context files (CLAUDE.md)
  bool get hasContextFile => hasClaudeMd;

  factory VaultEntry.fromJson(Map<String, dynamic> json) {
    return VaultEntry(
      name: json['name'] as String,
      type: json['type'] as String,
      path: json['path'] as String,
      relativePath: json['relativePath'] as String? ?? json['path'] as String,
      isSymlink: json['isSymlink'] as bool? ?? false,
      symlinkTarget: json['symlinkTarget'] as String?,
      hasAgentsMd: json['hasAgentsMd'] as bool? ?? false,
      hasClaudeMd: json['hasClaudeMd'] as bool? ?? false,
      isGitRepo: json['isGitRepo'] as bool? ?? false,
      lastModified: json['lastModified'] != null
          ? DateTime.parse(json['lastModified'] as String)
          : null,
      size: json['size'] as int?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type,
      'path': path,
      'relativePath': relativePath,
      'isSymlink': isSymlink,
      if (symlinkTarget != null) 'symlinkTarget': symlinkTarget,
      'hasAgentsMd': hasAgentsMd,
      'hasClaudeMd': hasClaudeMd,
      'isGitRepo': isGitRepo,
      if (lastModified != null) 'lastModified': lastModified!.toIso8601String(),
      if (size != null) 'size': size,
    };
  }
}
