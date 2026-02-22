/// Field metadata from Brain v2 schema definition.
class BrainV2Field {
  final String name;
  final String type;
  final bool required;
  final List<String>? enumValues;
  final String? itemsType; // For array types
  final String? description;

  const BrainV2Field({
    required this.name,
    required this.type,
    this.required = false,
    this.enumValues,
    this.itemsType,
    this.description,
  });

  factory BrainV2Field.fromJson(String name, Map<String, dynamic> json) {
    return BrainV2Field(
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
