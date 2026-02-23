// Filter condition models for the Brain query builder.

/// Type-safe filter value — sealed class prevents dynamic value usage.
sealed class FilterValue {
  const FilterValue();
}

class StringFilterValue extends FilterValue {
  final String value;
  const StringFilterValue(this.value);
}

class EnumFilterValue extends FilterValue {
  final String value;
  const EnumFilterValue(this.value);
}

class LinkFilterValue extends FilterValue {
  final String entityId;
  const LinkFilterValue(this.entityId);
}

class IntFilterValue extends FilterValue {
  final int value;
  const IntFilterValue(this.value);
}

/// A single filter condition: fieldName + operator + value.
class BrainFilterCondition {
  final String fieldName;
  /// v1 operators: eq | neq | contains
  final String operator;
  final FilterValue value;

  const BrainFilterCondition({
    required this.fieldName,
    required this.operator,
    required this.value,
  });

  Map<String, dynamic> toJson() => {
        'field_name': fieldName,
        'operator': operator,
        'value': _valueToJson(),
      };

  dynamic _valueToJson() {
    return switch (value) {
      StringFilterValue v => v.value,
      EnumFilterValue v => v.value,
      LinkFilterValue v => v.entityId,
      IntFilterValue v => v.value,
    };
  }

  static BrainFilterCondition fromJson(Map<String, dynamic> json) {
    final raw = json['value'];
    FilterValue filterValue;
    if (raw is int) {
      filterValue = IntFilterValue(raw);
    } else {
      filterValue = StringFilterValue(raw?.toString() ?? '');
    }
    return BrainFilterCondition(
      fieldName: json['field_name'] as String,
      operator: json['operator'] as String,
      value: filterValue,
    );
  }
}

/// A named, saved set of filter conditions.
class SavedQuery {
  final String id;
  final String name;
  final String entityType;
  final List<BrainFilterCondition> filters;

  const SavedQuery({
    required this.id,
    required this.name,
    required this.entityType,
    required this.filters,
  });

  factory SavedQuery.fromJson(Map<String, dynamic> json) {
    return SavedQuery(
      id: json['id'] as String? ?? '',
      name: json['name'] as String,
      entityType: json['entity_type'] as String,
      filters: (json['filters'] as List<dynamic>? ?? [])
          .map((f) => BrainFilterCondition.fromJson(f as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'entity_type': entityType,
        'filters': filters.map((f) => f.toJson()).toList(),
      };
}
