/// A Brain entity from the knowledge graph.
///
/// Entities have a name (primary key), entity_type (any string),
/// and dynamic fields — always includes 'description', plus any
/// type-specific fields added via brain_create_type.
class BrainEntity {
  final String id; // Entity name (primary key, e.g., "Kevin")
  final String type; // Entity type string (e.g., "person", "project")
  final Map<String, dynamic> fields; // All entity data fields

  const BrainEntity({
    required this.id,
    required this.type,
    this.fields = const {},
  });

  factory BrainEntity.fromJson(Map<String, dynamic> json) {
    // LadybugDB v3: flat shape — 'name' is primary key, 'entity_type' is the type label
    final id = json['name'] as String? ?? '';
    final type = json['entity_type'] as String? ?? '';

    // Strip system fields — everything else is user data
    final fields = Map<String, dynamic>.from(json)
      ..remove('name')
      ..remove('entity_type')
      ..remove('created_at')
      ..remove('updated_at');

    // Drop null values so callers can check `field != null` reliably
    fields.removeWhere((k, v) => v == null);

    return BrainEntity(
      id: id,
      type: type,
      fields: fields,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': id,
      'entity_type': type,
      ...fields,
    };
  }

  /// The entity name is the primary key — use it directly as display name.
  String get displayName => id.isNotEmpty ? id : 'Unnamed';

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
