/// Represents a folder that contains CLAUDE.md context files.
///
/// Context folders are discovered throughout the vault and can be selected
/// to load context for a chat session. When selected, the full parent chain
/// of CLAUDE.md files is included automatically.
class ContextFolder {
  /// Path relative to vault root (e.g., "Projects/parachute" or "" for root)
  final String path;

  /// Which context file exists (typically "CLAUDE.md")
  final String contextFile;

  /// Whether this folder has AGENTS.md (legacy, kept for backwards compatibility)
  final bool hasAgentsMd;

  /// Whether this folder has CLAUDE.md
  final bool hasClaudeMd;

  /// Human-readable display name
  final String displayName;

  const ContextFolder({
    required this.path,
    required this.contextFile,
    required this.hasAgentsMd,
    required this.hasClaudeMd,
    required this.displayName,
  });

  factory ContextFolder.fromJson(Map<String, dynamic> json) {
    return ContextFolder(
      path: json['path'] as String? ?? '',
      contextFile: json['context_file'] as String? ?? 'CLAUDE.md',
      hasAgentsMd: json['has_agents_md'] as bool? ?? false,
      hasClaudeMd: json['has_claude_md'] as bool? ?? false,
      displayName: json['display_name'] as String? ?? json['path'] as String? ?? 'Root',
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'context_file': contextFile,
        'has_agents_md': hasAgentsMd,
        'has_claude_md': hasClaudeMd,
        'display_name': displayName,
      };

  /// Whether this is the vault root folder
  bool get isRoot => path.isEmpty;

  @override
  String toString() => 'ContextFolder($displayName, path: $path)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContextFolder &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;
}

/// Represents a file in the context chain (with level info)
class ContextChainFile {
  /// Path relative to vault root (e.g., "Projects/parachute/CLAUDE.md")
  final String path;

  /// Folder path (e.g., "Projects/parachute")
  final String folderPath;

  /// Level in the chain: "root", "parent", or "direct"
  final String level;

  /// Estimated token count
  final int tokens;

  /// Whether the file exists
  final bool exists;

  const ContextChainFile({
    required this.path,
    required this.folderPath,
    required this.level,
    required this.tokens,
    required this.exists,
  });

  factory ContextChainFile.fromJson(Map<String, dynamic> json) {
    return ContextChainFile(
      path: json['path'] as String? ?? '',
      folderPath: json['folder_path'] as String? ?? '',
      level: json['level'] as String? ?? 'direct',
      tokens: json['tokens'] as int? ?? 0,
      exists: json['exists'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'folder_path': folderPath,
        'level': level,
        'tokens': tokens,
        'exists': exists,
      };

  /// Human-readable level label
  String get levelLabel {
    switch (level) {
      case 'root':
        return 'Root';
      case 'parent':
        return 'Parent';
      case 'direct':
        return 'Selected';
      default:
        return level;
    }
  }

  @override
  String toString() => 'ContextChainFile($path, level: $level)';
}

/// Response containing the full context chain for selected folders
class ContextChain {
  /// Files in the chain, ordered from root to direct
  final List<ContextChainFile> files;

  /// Total tokens in the chain
  final int totalTokens;

  /// Whether the chain was truncated due to token limit
  final bool truncated;

  const ContextChain({
    required this.files,
    required this.totalTokens,
    this.truncated = false,
  });

  factory ContextChain.fromJson(Map<String, dynamic> json) {
    final filesList = json['files'] as List<dynamic>? ?? [];
    return ContextChain(
      files: filesList
          .map((f) => ContextChainFile.fromJson(f as Map<String, dynamic>))
          .toList(),
      totalTokens: json['total_tokens'] as int? ?? 0,
      truncated: json['truncated'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'files': files.map((f) => f.toJson()).toList(),
        'total_tokens': totalTokens,
        'truncated': truncated,
      };

  /// Get files by level
  List<ContextChainFile> get rootFiles =>
      files.where((f) => f.level == 'root').toList();
  List<ContextChainFile> get parentFiles =>
      files.where((f) => f.level == 'parent').toList();
  List<ContextChainFile> get directFiles =>
      files.where((f) => f.level == 'direct').toList();

  @override
  String toString() =>
      'ContextChain(${files.length} files, $totalTokens tokens)';
}
