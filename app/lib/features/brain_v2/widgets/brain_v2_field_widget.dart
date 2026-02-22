import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_v2_field.dart';
import 'brain_v2_relationship_chip.dart';

/// Dynamic field renderer based on field type.
class BrainV2FieldWidget extends StatelessWidget {
  final BrainV2Field field;
  final dynamic value;

  const BrainV2FieldWidget({
    required this.field,
    required this.value,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (value == null) {
      return Text(
        '—',
        style: TextStyle(
          fontSize: 14,
          color: isDark
              ? BrandColors.nightTextSecondary
              : BrandColors.driftwood,
        ),
      );
    }

    // Handle different field types
    if (field.type == 'boolean') {
      return _buildBooleanField(value, isDark);
    } else if (field.type == 'datetime') {
      return _buildDateTimeField(value, isDark);
    } else if (field.type == 'array') {
      return _buildArrayField(value, isDark);
    } else if (field.isEntity) {
      return _buildEntityField(value, isDark);
    } else if (field.isEnum) {
      return _buildEnumField(value, isDark);
    } else {
      return _buildTextField(value, isDark);
    }
  }

  Widget _buildTextField(dynamic value, bool isDark) {
    return SelectableText(
      value.toString(),
      style: TextStyle(
        fontSize: 14,
        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
      ),
    );
  }

  Widget _buildBooleanField(dynamic value, bool isDark) {
    final boolValue = value is bool ? value : value.toString().toLowerCase() == 'true';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          boolValue ? Icons.check_circle : Icons.cancel,
          size: 18,
          color: boolValue
              ? (isDark ? BrandColors.nightForest : BrandColors.forest)
              : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
        ),
        const SizedBox(width: 6),
        Text(
          boolValue ? 'Yes' : 'No',
          style: TextStyle(
            fontSize: 14,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
      ],
    );
  }

  Widget _buildDateTimeField(dynamic value, bool isDark) {
    try {
      final dateTime = DateTime.parse(value.toString());
      // Simple date/time formatting without intl package
      final date = '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
      final time = '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
      final formatted = '$date $time';
      return Text(
        formatted,
        style: TextStyle(
          fontSize: 14,
          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
        ),
      );
    } catch (e) {
      return _buildTextField(value, isDark);
    }
  }

  Widget _buildArrayField(dynamic value, bool isDark) {
    if (value is! List || value.isEmpty) {
      return Text(
        '—',
        style: TextStyle(
          fontSize: 14,
          color: isDark
              ? BrandColors.nightTextSecondary
              : BrandColors.driftwood,
        ),
      );
    }

    // Check if array contains entity references (IRIs)
    final firstItem = value.first;
    if (firstItem is String && firstItem.contains('/')) {
      // Likely entity references
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: value.map((item) {
          return BrainV2RelationshipChip(entityId: item.toString());
        }).toList(),
      );
    }

    // Regular array of strings
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: value.map((item) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isDark
                ? BrandColors.nightForest.withOpacity(0.2)
                : BrandColors.forest.withOpacity(0.1),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Text(
            item.toString(),
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? BrandColors.nightForest
                  : BrandColors.forest,
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildEntityField(dynamic value, bool isDark) {
    // Single entity reference
    if (value is String) {
      return BrainV2RelationshipChip(entityId: value);
    }

    // Entity object with @id
    if (value is Map && value.containsKey('@id')) {
      return BrainV2RelationshipChip(entityId: value['@id'].toString());
    }

    return _buildTextField(value, isDark);
  }

  Widget _buildEnumField(dynamic value, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightForest.withOpacity(0.3)
            : BrandColors.forest.withOpacity(0.15),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: isDark ? BrandColors.nightForest : BrandColors.forest,
          width: 1,
        ),
      ),
      child: Text(
        value.toString(),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: isDark ? BrandColors.nightForest : BrandColors.forest,
        ),
      ),
    );
  }
}
