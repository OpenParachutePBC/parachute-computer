import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_filter.dart';
import '../models/brain_schema.dart';
import '../providers/brain_providers.dart';

/// Horizontal query bar shown above the entity list.
///
/// Displays active filter chips and controls for adding/saving queries.
/// Hidden when no type is selected or schema has no fields.
class BrainQueryBar extends ConsumerWidget {
  final BrainSchema? schema;

  const BrainQueryBar({this.schema, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schema = this.schema;
    if (schema == null || schema.fields.isEmpty) return const SizedBox.shrink();

    final filters = ref.watch(brainActiveFiltersProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final dividerColor = isDark
        ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
        : BrandColors.charcoal.withValues(alpha: 0.1);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              // Active filter chips
              ...filters.asMap().entries.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(right: 6, top: 10, bottom: 10),
                      child: _FilterChip(
                        condition: e.value,
                        index: e.key,
                        isDark: isDark,
                      ),
                    ),
                  ),

              // + Add filter button
              Padding(
                padding: const EdgeInsets.only(right: 6, top: 10, bottom: 10),
                child: _AddFilterButton(schema: schema, isDark: isDark),
              ),

              // Saved queries dropdown (only when type selected)
              Padding(
                padding: const EdgeInsets.only(right: 6, top: 10, bottom: 10),
                child: _SavedQueriesButton(schema: schema, isDark: isDark),
              ),

              // Clear all — only shown when filters active
              if (filters.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 6, top: 10, bottom: 10),
                  child: _ClearButton(isDark: isDark),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: dividerColor),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Active filter chip
// ---------------------------------------------------------------------------

class _FilterChip extends ConsumerWidget {
  final BrainFilterCondition condition;
  final int index;
  final bool isDark;

  const _FilterChip({
    required this.condition,
    required this.index,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = _buildLabel(condition);

    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? BrandColors.nightForest.withValues(alpha: 0.2)
            : BrandColors.forestMist,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? BrandColors.nightForest.withValues(alpha: 0.4)
              : BrandColors.forest.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2, right: 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => ref.read(brainActiveFiltersProvider.notifier).remove(index),
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(
                Icons.close,
                size: 14,
                color: isDark
                    ? BrandColors.nightForest.withValues(alpha: 0.8)
                    : BrandColors.forest.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buildLabel(BrainFilterCondition c) {
    final valueStr = switch (c.value) {
      StringFilterValue v => v.value,
      EnumFilterValue v => v.value,
      LinkFilterValue v => v.entityId,
      IntFilterValue v => '${v.value}',
    };
    final opLabel = switch (c.operator) {
      'eq' => '=',
      'neq' => '≠',
      'contains' => '~',
      _ => c.operator,
    };
    return '${c.fieldName} $opLabel $valueStr';
  }
}

// ---------------------------------------------------------------------------
// + Add filter button
// ---------------------------------------------------------------------------

class _AddFilterButton extends StatelessWidget {
  final BrainSchema schema;
  final bool isDark;

  const _AddFilterButton({required this.schema, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showAddFilterSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.4)
                : BrandColors.charcoal.withValues(alpha: 0.2),
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add,
              size: 14,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            const SizedBox(width: 4),
            Text(
              'Filter',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showAddFilterSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddFilterSheet(schema: schema),
    );
  }
}

// ---------------------------------------------------------------------------
// Saved queries button + menu
// ---------------------------------------------------------------------------

class _SavedQueriesButton extends ConsumerWidget {
  final BrainSchema schema;
  final bool isDark;

  const _SavedQueriesButton({required this.schema, required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final savedAsync = ref.watch(brainSavedQueriesProvider);

    return GestureDetector(
      onTap: () => _showMenu(context, ref, savedAsync.valueOrNull ?? []),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.4)
                : BrandColors.charcoal.withValues(alpha: 0.2),
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.bookmark_outline,
              size: 14,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            const SizedBox(width: 4),
            Text(
              'Saved',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down,
              size: 14,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ],
        ),
      ),
    );
  }

  void _showMenu(
    BuildContext context,
    WidgetRef ref,
    List<SavedQuery> saved,
  ) {
    final filters = ref.read(brainActiveFiltersProvider);
    // Filter to just this type's queries
    final forType =
        saved.where((q) => q.entityType == schema.name).toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _SavedQueriesSheet(
        schema: schema,
        savedQueries: forType,
        activeFilters: filters,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Clear all button
// ---------------------------------------------------------------------------

class _ClearButton extends ConsumerWidget {
  final bool isDark;
  const _ClearButton({required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () => ref.read(brainActiveFiltersProvider.notifier).clear(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.4)
                : BrandColors.charcoal.withValues(alpha: 0.2),
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          'Clear',
          style: TextStyle(
            fontSize: 12,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add filter bottom sheet
// ---------------------------------------------------------------------------

class _AddFilterSheet extends ConsumerStatefulWidget {
  final BrainSchema schema;
  const _AddFilterSheet({required this.schema});

  @override
  ConsumerState<_AddFilterSheet> createState() => _AddFilterSheetState();
}

class _AddFilterSheetState extends ConsumerState<_AddFilterSheet> {
  String? _selectedField;
  String _selectedOperator = 'eq';
  final TextEditingController _valueController = TextEditingController();

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E2220) : Colors.white;
    final handleColor = isDark
        ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
        : BrandColors.charcoal.withValues(alpha: 0.2);

    final textFields =
        widget.schema.fields.where((f) => !f.isArray).toList();

    final selectedBrainField = _selectedField != null
        ? textFields.where((f) => f.name == _selectedField).firstOrNull
        : null;

    final operators = _operatorsFor(selectedBrainField?.type);

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        left: 20,
        right: 20,
        top: 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: handleColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          Text(
            'Add Filter',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          const SizedBox(height: 16),

          // Field picker
          _Label('Field', isDark: isDark),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _selectedField,
            decoration: _inputDecoration(isDark),
            hint: Text('Select field',
                style: TextStyle(
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                  fontSize: 14,
                )),
            items: textFields
                .map((f) => DropdownMenuItem(
                      value: f.name,
                      child: Text(f.name, style: const TextStyle(fontSize: 14)),
                    ))
                .toList(),
            onChanged: (v) => setState(() {
              _selectedField = v;
              _selectedOperator = 'eq';
              _valueController.clear();
            }),
          ),
          const SizedBox(height: 12),

          // Operator picker
          _Label('Operator', isDark: isDark),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _selectedOperator,
            decoration: _inputDecoration(isDark),
            items: operators
                .map((op) => DropdownMenuItem(
                      value: op,
                      child: Text(_operatorLabel(op),
                          style: const TextStyle(fontSize: 14)),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _selectedOperator = v ?? 'eq'),
          ),
          const SizedBox(height: 12),

          // Value input
          _Label('Value', isDark: isDark),
          const SizedBox(height: 6),
          _buildValueInput(isDark, selectedBrainField),
          const SizedBox(height: 20),

          // Apply button
          ElevatedButton(
            onPressed: _canApply() ? () => _applyFilter(context) : null,
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  isDark ? BrandColors.nightForest : BrandColors.forest,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              minimumSize: const Size.fromHeight(44),
            ),
            child: const Text('Apply Filter'),
          ),
        ],
      ),
    );
  }

  Widget _buildValueInput(bool isDark, dynamic field) {
    return TextFormField(
      controller: _valueController,
      decoration: _inputDecoration(isDark).copyWith(hintText: 'Enter value'),
      keyboardType: field?.type == 'integer'
          ? TextInputType.number
          : TextInputType.text,
      style: const TextStyle(fontSize: 14),
    );
  }

  List<String> _operatorsFor(String? fieldType) {
    switch (fieldType) {
      case 'integer':
        return ['eq', 'neq'];
      case 'string':
        return ['eq', 'neq', 'contains'];
      default:
        return ['eq', 'neq'];
    }
  }

  String _operatorLabel(String op) {
    return switch (op) {
      'eq' => 'equals',
      'neq' => 'not equals',
      'contains' => 'contains',
      _ => op,
    };
  }

  bool _canApply() =>
      _selectedField != null && _valueController.text.trim().isNotEmpty;

  void _applyFilter(BuildContext context) {
    final rawValue = _valueController.text.trim();
    FilterValue filterValue;

    // Determine value type from field type
    final field = widget.schema.fields
        .where((f) => f.name == _selectedField)
        .firstOrNull;

    if (field?.type == 'integer') {
      final parsed = int.tryParse(rawValue);
      if (parsed == null) return; // invalid
      filterValue = IntFilterValue(parsed);
    } else if (field?.type == 'enum') {
      filterValue = EnumFilterValue(rawValue);
    } else {
      filterValue = StringFilterValue(rawValue);
    }

    ref.read(brainActiveFiltersProvider.notifier).add(
          BrainFilterCondition(
            fieldName: _selectedField!,
            operator: _selectedOperator,
            value: filterValue,
          ),
        );

    Navigator.of(context).pop();
  }

  InputDecoration _inputDecoration(bool isDark) => InputDecoration(
        filled: true,
        fillColor: isDark
            ? BrandColors.charcoal.withValues(alpha: 0.3)
            : BrandColors.charcoal.withValues(alpha: 0.05),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
                : BrandColors.charcoal.withValues(alpha: 0.2),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
                : BrandColors.charcoal.withValues(alpha: 0.2),
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Saved queries sheet
// ---------------------------------------------------------------------------

class _SavedQueriesSheet extends ConsumerStatefulWidget {
  final BrainSchema schema;
  final List<SavedQuery> savedQueries;
  final List<BrainFilterCondition> activeFilters;

  const _SavedQueriesSheet({
    required this.schema,
    required this.savedQueries,
    required this.activeFilters,
  });

  @override
  ConsumerState<_SavedQueriesSheet> createState() =>
      _SavedQueriesSheetState();
}

class _SavedQueriesSheetState extends ConsumerState<_SavedQueriesSheet> {
  bool _showSaveForm = false;
  final TextEditingController _nameController = TextEditingController();
  bool _isSaving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E2220) : Colors.white;
    final handleColor = isDark
        ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
        : BrandColors.charcoal.withValues(alpha: 0.2);

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        left: 20,
        right: 20,
        top: 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: handleColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Saved Queries',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              if (widget.activeFilters.isNotEmpty)
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _showSaveForm = !_showSaveForm),
                  icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                  label: const Text('Save current'),
                  style: TextButton.styleFrom(
                    foregroundColor:
                        isDark ? BrandColors.nightForest : BrandColors.forest,
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
          ),

          if (_showSaveForm) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                hintText: 'Query name',
                filled: true,
                fillColor: isDark
                    ? BrandColors.charcoal.withValues(alpha: 0.3)
                    : BrandColors.charcoal.withValues(alpha: 0.05),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: isDark
                        ? BrandColors.nightTextSecondary.withValues(alpha: 0.3)
                        : BrandColors.charcoal.withValues(alpha: 0.2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _isSaving ? null : () => _saveCurrentQuery(context),
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    isDark ? BrandColors.nightForest : BrandColors.forest,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                minimumSize: const Size.fromHeight(40),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ],

          const SizedBox(height: 8),

          if (widget.savedQueries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'No saved queries for ${widget.schema.name}',
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
                textAlign: TextAlign.center,
              ),
            )
          else
            ...widget.savedQueries.map(
              (q) => ListTile(
                dense: true,
                title: Text(q.name,
                    style: const TextStyle(fontSize: 14)),
                subtitle: Text(
                  '${q.filters.length} filter${q.filters.length == 1 ? '' : 's'}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => _deleteQuery(context, q),
                ),
                onTap: () => _loadQuery(context, q),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _saveCurrentQuery(BuildContext context) async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isSaving = true);
    try {
      await ref.read(brainQueryServiceProvider).saveQuery(
            name,
            widget.schema.name,
            widget.activeFilters,
          );
      ref.invalidate(brainSavedQueriesProvider);
      if (mounted) nav.pop();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to save query: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _loadQuery(BuildContext context, SavedQuery query) {
    final notifier = ref.read(brainActiveFiltersProvider.notifier);
    notifier.clear();
    for (final f in query.filters) {
      notifier.add(f);
    }
    Navigator.of(context).pop();
  }

  Future<void> _deleteQuery(BuildContext context, SavedQuery query) async {
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(brainQueryServiceProvider).deleteQuery(query.id);
      ref.invalidate(brainSavedQueriesProvider);
      if (mounted) nav.pop();
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to delete query: $e')),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _Label extends StatelessWidget {
  final String text;
  final bool isDark;
  const _Label(this.text, {required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color:
            isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
      ),
    );
  }
}
