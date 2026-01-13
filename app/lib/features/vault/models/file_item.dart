/// Type of file system item
enum FileItemType {
  folder,
  markdown,
  audio,
  other,
}

/// Represents a file or folder in the vault browser
class FileItem {
  final String name;
  final String path;
  final FileItemType type;
  final DateTime? modified;
  final int? sizeBytes;

  const FileItem({
    required this.name,
    required this.path,
    required this.type,
    this.modified,
    this.sizeBytes,
  });

  /// Check if this is a folder
  bool get isFolder => type == FileItemType.folder;

  /// Check if this is a markdown file
  bool get isMarkdown => type == FileItemType.markdown;

  /// Check if this is an audio file
  bool get isAudio => type == FileItemType.audio;

  /// Get file extension (empty for folders)
  String get extension {
    if (isFolder) return '';
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1) return '';
    return name.substring(dotIndex + 1).toLowerCase();
  }

  /// Create FileItem from file system entity info
  factory FileItem.fromPath(String path, {
    required bool isDirectory,
    DateTime? modified,
    int? sizeBytes,
  }) {
    final name = path.split('/').last;

    FileItemType type;
    if (isDirectory) {
      type = FileItemType.folder;
    } else {
      final ext = name.split('.').last.toLowerCase();
      switch (ext) {
        case 'md':
        case 'markdown':
          type = FileItemType.markdown;
          break;
        case 'wav':
        case 'mp3':
        case 'opus':
        case 'm4a':
        case 'aac':
          type = FileItemType.audio;
          break;
        default:
          type = FileItemType.other;
      }
    }

    return FileItem(
      name: name,
      path: path,
      type: type,
      modified: modified,
      sizeBytes: sizeBytes,
    );
  }

  @override
  String toString() => 'FileItem($name, $type)';
}
