/// Information about an available skill fetched from the server.
class SkillInfo {
  final String name;
  final String description;
  final String? content;
  final int? size;
  final String? modified;

  const SkillInfo({
    required this.name,
    this.description = '',
    this.content,
    this.size,
    this.modified,
  });

  factory SkillInfo.fromJson(Map<String, dynamic> json) {
    return SkillInfo(
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      content: json['content'] as String?,
      size: json['size'] as int?,
      modified: json['modified'] as String?,
    );
  }
}
