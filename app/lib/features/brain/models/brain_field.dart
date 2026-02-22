/// Field metadata from Brain schema definition.
class BrainField {
  final String name;
  final String type;
  final bool required;
  final List<String>? enumValues;
  final String? itemsType; // For array types
  final String? description;

  const BrainField({
    required this.name,
    required this.type,
    this.required = false,
    this.enumValues,
    this.itemsType,
    this.description,
  });

  factory BrainField.fromJson(String name, Map<String, dynamic> json) {
    return BrainField(
      name: name,
      type: json['type'] as String? ?? 'string',
      required: json['required'] as bool? ?? false,
      enumValues: json['enum'] != null
          ? (json['enum'] as List<dynamic>).map((e) => e.toString()).toList()
          : null,
      itemsType: json['items'] as String?,
      description: json['description'] as String?,
    );
  }

  bool get isEnum => enumValues != null && enumValues!.isNotEmpty;
  bool get isArray => type == 'array';
  bool get isEntity => !['string', 'integer', 'boolean', 'datetime', 'array', 'enum'].contains(type);
}
