/// A Brain entity (person, concept, project, etc.) from the knowledge graph.
class BrainEntity {
  final String paraId;
  final String name;
  final List<String> tags;
  final String? content;
  final String? snippet;
  final String? path;

  const BrainEntity({
    required this.paraId,
    required this.name,
    this.tags = const [],
    this.content,
    this.snippet,
    this.path,
  });

  factory BrainEntity.fromJson(Map<String, dynamic> json) {
    return BrainEntity(
      paraId: json['para_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      tags: (json['tags'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      content: json['content'] as String?,
      snippet: json['snippet'] as String?,
      path: json['path'] as String?,
    );
  }
}
