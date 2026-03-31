/// A Thing is the universal record in the Parachute graph.
/// Everything is a thing — journal entries, cards, people, projects.
/// What makes a thing specific is its tags.
class Thing {
  final String id;
  final String content;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String createdBy;
  final String status;
  final List<ThingTag> tags;
  final List<ThingEdge> edges;

  const Thing({
    required this.id,
    required this.content,
    required this.createdAt,
    this.updatedAt,
    this.createdBy = 'user',
    this.status = 'active',
    this.tags = const [],
    this.edges = const [],
  });

  // ---- Tag convenience ----

  bool hasTag(String tagName) => tags.any((t) => t.tagName == tagName);

  /// Get a field value from a specific tag.
  T? tagField<T>(String tagName, String fieldName) {
    final tag = tags.cast<ThingTag?>().firstWhere(
      (t) => t!.tagName == tagName,
      orElse: () => null,
    );
    if (tag == null) return null;
    final value = tag.fieldValues[fieldName];
    if (value is T) return value;
    return null;
  }

  /// Get all field values for a tag.
  Map<String, dynamic>? tagFields(String tagName) {
    final tag = tags.cast<ThingTag?>().firstWhere(
      (t) => t!.tagName == tagName,
      orElse: () => null,
    );
    return tag?.fieldValues;
  }

  // ---- Type checks ----

  bool get isDailyNote => hasTag('daily-note');
  bool get isCard => hasTag('card');
  bool get isPerson => hasTag('person');
  bool get isProject => hasTag('project');

  // ---- Daily-note fields ----

  String get entryType => tagField<String>('daily-note', 'entry_type') ?? 'text';
  String? get audioUrl => tagField<String>('daily-note', 'audio_url');
  int? get durationSeconds => tagField<int>('daily-note', 'duration_seconds');
  String? get transcriptionStatus => tagField<String>('daily-note', 'transcription_status');
  String? get cleanupStatus => tagField<String>('daily-note', 'cleanup_status');
  String? get noteDate => tagField<String>('daily-note', 'date');

  // ---- Card fields ----

  String? get cardType => tagField<String>('card', 'card_type');
  String? get readAt => tagField<String>('card', 'read_at');
  bool get isRead => readAt != null && readAt!.isNotEmpty;
  bool get isUnread => !isRead;
  String? get cardDate => tagField<String>('card', 'date');

  // ---- Edge convenience ----

  List<ThingEdge> edgesOfType(String relationship) =>
      edges.where((e) => e.relationship == relationship).toList();

  // ---- Serialization ----

  factory Thing.fromJson(Map<String, dynamic> json) {
    return Thing(
      id: json['id'] as String,
      content: json['content'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
      createdBy: json['createdBy'] as String? ?? 'user',
      status: json['status'] as String? ?? 'active',
      tags: (json['tags'] as List<dynamic>?)
              ?.map((t) => ThingTag.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
      edges: (json['edges'] as List<dynamic>?)
              ?.map((e) => ThingEdge.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
        'createdBy': createdBy,
        'status': status,
        'tags': tags.map((t) => t.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
      };

  Thing copyWith({
    String? id,
    String? content,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? createdBy,
    String? status,
    List<ThingTag>? tags,
    List<ThingEdge>? edges,
  }) {
    return Thing(
      id: id ?? this.id,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      status: status ?? this.status,
      tags: tags ?? this.tags,
      edges: edges ?? this.edges,
    );
  }

  @override
  String toString() => 'Thing($id, ${content.length > 50 ? '${content.substring(0, 50)}...' : content})';
}

/// A tag applied to a thing, with field values defined by the tag's schema.
class ThingTag {
  final String tagName;
  final Map<String, dynamic> fieldValues;
  final String taggedAt;

  const ThingTag({
    required this.tagName,
    this.fieldValues = const {},
    required this.taggedAt,
  });

  factory ThingTag.fromJson(Map<String, dynamic> json) {
    return ThingTag(
      tagName: json['tagName'] as String,
      fieldValues: Map<String, dynamic>.from(json['fieldValues'] as Map? ?? {}),
      taggedAt: json['taggedAt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'tagName': tagName,
        'fieldValues': fieldValues,
        'taggedAt': taggedAt,
      };
}

/// A relationship between two things.
class ThingEdge {
  final String sourceId;
  final String targetId;
  final String relationship;
  final Map<String, dynamic> properties;
  final String createdBy;
  final String createdAt;
  final Thing? source;
  final Thing? target;

  const ThingEdge({
    required this.sourceId,
    required this.targetId,
    required this.relationship,
    this.properties = const {},
    this.createdBy = 'user',
    required this.createdAt,
    this.source,
    this.target,
  });

  factory ThingEdge.fromJson(Map<String, dynamic> json) {
    return ThingEdge(
      sourceId: json['sourceId'] as String,
      targetId: json['targetId'] as String,
      relationship: json['relationship'] as String,
      properties: Map<String, dynamic>.from(json['properties'] as Map? ?? {}),
      createdBy: json['createdBy'] as String? ?? 'user',
      createdAt: json['createdAt'] as String? ?? '',
      source: json['source'] != null
          ? Thing.fromJson(json['source'] as Map<String, dynamic>)
          : null,
      target: json['target'] != null
          ? Thing.fromJson(json['target'] as Map<String, dynamic>)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'targetId': targetId,
        'relationship': relationship,
        'properties': properties,
        'createdBy': createdBy,
        'createdAt': createdAt,
      };
}

/// A tag definition (the type itself, not an instance on a thing).
class TagDef {
  final String name;
  final String displayName;
  final String description;
  final List<Map<String, dynamic>> schema;
  final String? icon;
  final String? color;
  final String? publishedBy;
  final int count;

  const TagDef({
    required this.name,
    this.displayName = '',
    this.description = '',
    this.schema = const [],
    this.icon,
    this.color,
    this.publishedBy,
    this.count = 0,
  });

  factory TagDef.fromJson(Map<String, dynamic> json) {
    return TagDef(
      name: json['name'] as String,
      displayName: json['displayName'] as String? ?? '',
      description: json['description'] as String? ?? '',
      schema: (json['schema'] as List<dynamic>?)
              ?.map((s) => Map<String, dynamic>.from(s as Map))
              .toList() ??
          [],
      icon: json['icon'] as String?,
      color: json['color'] as String?,
      publishedBy: json['publishedBy'] as String?,
      count: json['count'] as int? ?? 0,
    );
  }
}
