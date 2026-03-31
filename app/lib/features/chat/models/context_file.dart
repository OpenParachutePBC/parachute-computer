/// Represents a context file that can be loaded into a chat session
///
/// Context files are stored in the vault's contexts/ folder and provide
/// additional context about the user or specific projects.
class ContextFile {
  /// Path relative to vault root (e.g., "contexts/general-context.md")
  final String path;

  /// Just the filename (e.g., "general-context.md")
  final String filename;

  /// Human-readable title extracted from the file
  final String title;

  /// Brief description/first paragraph from the file
  final String description;

  /// Whether this is the default context (general-context.md)
  final bool isDefault;

  /// File size in bytes
  final int size;

  /// Last modified time
  final DateTime modified;

  const ContextFile({
    required this.path,
    required this.filename,
    required this.title,
    required this.description,
    required this.isDefault,
    required this.size,
    required this.modified,
  });

  factory ContextFile.fromJson(Map<String, dynamic> json) {
    return ContextFile(
      path: json['path'] as String,
      filename: json['filename'] as String,
      title: json['title'] as String,
      description: json['description'] as String? ?? '',
      isDefault: json['isDefault'] as bool? ?? false,
      size: json['size'] as int? ?? 0,
      modified: json['modified'] != null
          ? DateTime.parse(json['modified'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'filename': filename,
        'title': title,
        'description': description,
        'isDefault': isDefault,
        'size': size,
        'modified': modified.toIso8601String(),
      };

  @override
  String toString() => 'ContextFile($title, isDefault: $isDefault)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContextFile &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;
}
