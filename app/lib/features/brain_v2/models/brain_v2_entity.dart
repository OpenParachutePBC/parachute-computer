/// A Brain v2 entity from the knowledge graph.
///
/// Entities have an @id (IRI like "Person/Alice"), @type (entity type),
/// and dynamic fields based on the schema definition.
class BrainV2Entity {
  final String id; // Entity IRI (e.g., "Person/Alice")
  final String type; // Entity type (e.g., "Person")
  final Map<String, dynamic> fields; // All entity data fields

  const BrainV2Entity({
    required this.id,
    required this.type,
    this.fields = const {},
  });

  factory BrainV2Entity.fromJson(Map<String, dynamic> json) {
    // TerminusDB uses '@id' and '@type' for system fields
    final id = json['@id'] as String? ?? json['id'] as String? ?? '';
    final type = json['@type'] as String? ?? json['type'] as String? ?? '';

    // All other fields are entity data
    final fields = Map<String, dynamic>.from(json);
    fields.remove('@id');
    fields.remove('@type');
    fields.remove('id');
    fields.remove('type');

    return BrainV2Entity(
      id: id,
      type: type,
      fields: fields,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      '@id': id,
      '@type': type,
      ...fields,
    };
  }

  /// Get display name from 'name' or 'title' field, fallback to ID.
  String get displayName {
    final name = fields['name'] ?? fields['title'];
    if (name != null) return name.toString();

    // Fallback: extract name from IRI (e.g., "Person/Alice" -> "Alice")
    if (id.contains('/')) {
      return id.split('/').last;
    }

    return id;
  }

  /// Get tags if present.
  List<String> get tags {
    final tagsField = fields['tags'];
    if (tagsField is List) {
      return tagsField.map((e) => e.toString()).toList();
    }
    return [];
  }

  /// Get field value by name.
  dynamic operator [](String key) => fields[key];

  /// Check if entity has a field.
  bool has(String key) => fields.containsKey(key);

  /// Safely get field value with type checking and default value.
  T? getField<T>(String key, [T? defaultValue]) {
    final value = fields[key];
    if (value == null) return defaultValue;
    if (value is T) return value;

    // Try to convert to string if T is String
    if (T == String) return value.toString() as T;

    return defaultValue;
  }
}
