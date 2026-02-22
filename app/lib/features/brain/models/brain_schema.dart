import 'brain_field.dart';

/// Schema definition for an entity type in Brain.
class BrainSchema {
  final String id;
  final String name;
  final String? description;
  final List<BrainField> fields;
  final String? keyStrategy;
  final List<String>? keyFields;

  const BrainSchema({
    required this.id,
    required this.name,
    this.description,
    this.fields = const [],
    this.keyStrategy,
    this.keyFields,
  });

  factory BrainSchema.fromJson(Map<String, dynamic> json) {
    final fieldsMap = json['fields'] as Map<String, dynamic>? ?? {};
    final fields = fieldsMap.entries
        .map((e) => BrainField.fromJson(e.key, e.value as Map<String, dynamic>))
        .toList();

    return BrainSchema(
      id: json['id'] as String? ?? json['name'] as String? ?? '',
      name: json['name'] as String? ?? '',
      description: json['description'] as String?,
      fields: fields,
      keyStrategy: json['key_strategy'] as String?,
      keyFields: json['key_fields'] != null
          ? (json['key_fields'] as List<dynamic>).map((e) => e.toString()).toList()
          : null,
    );
  }

  /// Get primary display field (name, title, or first string field).
  String? get displayField {
    // Prefer 'name' or 'title' field
    final nameField = fields.where((f) => f.name == 'name' || f.name == 'title').firstOrNull;
    if (nameField != null) return nameField.name;

    // Fallback to first string field
    final stringField = fields.where((f) => f.type == 'string').firstOrNull;
    return stringField?.name;
  }

  /// Get fields that should be shown in list view (first 2-3 non-array fields).
  List<BrainField> get primaryFields {
    return fields
        .where((f) => !f.isArray && f.name != 'tags')
        .take(3)
        .toList();
  }
}
