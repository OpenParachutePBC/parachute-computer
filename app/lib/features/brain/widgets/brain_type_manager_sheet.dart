import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/brain_providers.dart';

/// Bottom sheet for creating and editing schema types.
///
/// New mode: typeName == null
/// Edit mode: typeName is set, name field is read-only
///
/// Must be ConsumerStatefulWidget — needs ref for provider reads during
/// form validation (checking existing type names from brainSchemaDetailProvider).
class BrainTypeManagerSheet extends ConsumerStatefulWidget {
  final String? typeName;
  const BrainTypeManagerSheet({this.typeName, super.key});

  @override
  ConsumerState<BrainTypeManagerSheet> createState() =>
      _BrainTypeManagerSheetState();
}

class _BrainTypeManagerSheetState extends ConsumerState<BrainTypeManagerSheet> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _typeNameController;
  late TextEditingController _descriptionController;

  // Each field: {name, type, required, values (for enum), link_type (for link)}
  final List<Map<String, dynamic>> _fields = [];
  final List<TextEditingController> _fieldNameControllers = [];

  bool _isSubmitting = false;
  String? _errorMessage;

  static final _typeNamePattern = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');
  static final _fieldNamePattern = RegExp(r'^[a-z][a-z0-9_]*$');
  static final _reservedNames = {
    'Class', 'Enum', 'Set', 'Optional', 'TaggedUnion', 'Array',
    'Sys', 'xsd', 'rdf', 'owl', 'rdfs',
  };

  @override
  void initState() {
    super.initState();
    _typeNameController = TextEditingController(text: widget.typeName ?? '');
    _descriptionController = TextEditingController();
    // In edit mode, populate fields from provider after first frame
    if (widget.typeName != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadExistingType());
    }
  }

  void _loadExistingType() {
    final typesAsync = ref.read(brainSchemaDetailProvider);
    typesAsync.whenData((types) {
      final type = types.where((t) => t.name == widget.typeName).firstOrNull;
      if (type == null) return;
      setState(() {
        _descriptionController.text = type.description ?? '';
        for (final field in type.fields) {
          final ctrl = TextEditingController(text: field.name);
          _fieldNameControllers.add(ctrl);
          _fields.add({
            'type': field.isEntity ? 'link' : field.type,
            'required': field.required,
            'values': List<String>.from(field.enumValues ?? []),
            'link_type': field.isEntity ? field.type : null,
          });
        }
      });
    });
  }

  @override
  void dispose() {
    _typeNameController.dispose();
    _descriptionController.dispose();
    for (final c in _fieldNameControllers) c.dispose();
    super.dispose();
  }

  void _addField() {
    setState(() {
      _fieldNameControllers.add(TextEditingController());
      _fields.add({
        'type': 'string',
        'required': false,
        'values': <String>[],
        'link_type': null,
      });
    });
  }

  void _removeField(int index) {
    setState(() {
      _fieldNameControllers[index].dispose();
      _fieldNameControllers.removeAt(index);
      _fields.removeAt(index);
    });
  }

  Future<void> _handleSave() async {
    if (_isSubmitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final typeName = _typeNameController.text.trim();
    final service = ref.read(brainServiceProvider);

    // Build fields map
    final fieldsMap = <String, Map<String, dynamic>>{};
    for (var i = 0; i < _fields.length; i++) {
      final name = _fieldNameControllers[i].text.trim();
      if (name.isEmpty) continue;
      final field = _fields[i];
      final spec = <String, dynamic>{
        'type': field['type'],
        'required': field['required'] ?? false,
      };
      if (field['type'] == 'enum') {
        spec['values'] = List<String>.from(field['values'] as List);
      }
      if (field['type'] == 'link') {
        spec['link_type'] = field['link_type'] ?? '';
      }
      fieldsMap[name] = spec;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      if (widget.typeName == null) {
        await service.createSchemaType(name: typeName, fields: fieldsMap);
      } else {
        await service.updateSchemaType(name: typeName, fields: fieldsMap);
      }
      ref.invalidate(brainSchemaDetailProvider);
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (e) {
      setState(() => _errorMessage = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _handleDelete() async {
    final entityCount = ref
        .read(brainSchemaDetailProvider)
        .valueOrNull
        ?.firstWhere(
          (t) => t.name == widget.typeName,
          orElse: () => throw StateError(''),
        )
        .entityCount;

    if (entityCount != null && entityCount > 0) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Cannot Delete'),
            content: Text(
              'Delete all $entityCount entities first. This type cannot be removed while data exists.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Type'),
        content: Text(
          'Delete type "${widget.typeName}"? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isSubmitting = true);
    try {
      await ref.read(brainServiceProvider).deleteSchemaType(widget.typeName!);
      ref.invalidate(brainSchemaDetailProvider);
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (e) {
      setState(() => _errorMessage = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isEditMode = widget.typeName != null;
    final existingTypes = ref.watch(brainSchemaDetailProvider).valueOrNull ?? [];
    final existingTypeNames = existingTypes.map((t) => t.name).toSet();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.85,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              // Drag handle
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark
                        ? BrandColors.nightTextSecondary.withValues(alpha: 0.4)
                        : BrandColors.charcoal.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        isEditMode ? 'Edit Type' : 'New Type',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                    ),
                    if (isEditMode)
                      TextButton.icon(
                        onPressed: _isSubmitting ? null : _handleDelete,
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        label: const Text('Delete', style: TextStyle(color: Colors.red)),
                      ),
                  ],
                ),
              ),

              Divider(height: 1, color: isDark
                  ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                  : BrandColors.charcoal.withValues(alpha: 0.1)),

              // Scrollable form content
              Flexible(
                child: Form(
                  key: _formKey,
                  child: ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Type name field
                      TextFormField(
                        controller: _typeNameController,
                        enabled: !isEditMode,
                        decoration: InputDecoration(
                          labelText: 'Type name',
                          hintText: 'e.g. Project',
                          helperText: isEditMode
                              ? 'Type name cannot be changed after creation'
                              : 'PascalCase, e.g. "Project" or "TeamMember"',
                          filled: true,
                          fillColor: isDark
                              ? BrandColors.nightSurfaceElevated
                              : BrandColors.cream,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(Radii.sm),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        validator: (v) {
                          final name = v?.trim() ?? '';
                          if (name.isEmpty) return 'Type name is required';
                          if (!_typeNamePattern.hasMatch(name)) {
                            return 'Must start with a letter and contain only letters, digits, underscores';
                          }
                          if (_reservedNames.contains(name)) {
                            return '"$name" is reserved by TerminusDB';
                          }
                          if (!isEditMode && existingTypeNames.contains(name)) {
                            return 'A type named "$name" already exists';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Description field
                      TextFormField(
                        controller: _descriptionController,
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: 'Description (optional)',
                          filled: true,
                          fillColor: isDark
                              ? BrandColors.nightSurfaceElevated
                              : BrandColors.cream,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(Radii.sm),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      Text(
                        'FIELDS',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                          color: isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood,
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Field editor rows
                      for (var i = 0; i < _fields.length; i++)
                        _FieldEditorRow(
                          key: ValueKey(i),
                          nameController: _fieldNameControllers[i],
                          field: _fields[i],
                          existingTypeNames: existingTypeNames.toList(),
                          isDark: isDark,
                          onChanged: (updated) {
                            setState(() => _fields[i] = updated);
                          },
                          onRemove: () => _removeField(i),
                          fieldNameValidator: (v) {
                            final name = v?.trim() ?? '';
                            if (name.isEmpty) return 'Required';
                            if (!_fieldNamePattern.hasMatch(name)) {
                              return 'Must be snake_case (e.g. "field_name")';
                            }
                            // Check for duplicates
                            final others = _fieldNameControllers
                                .asMap()
                                .entries
                                .where((e) => e.key != i)
                                .map((e) => e.value.text.trim())
                                .toSet();
                            if (others.contains(name)) return 'Duplicate field name';
                            return null;
                          },
                        ),

                      // + Add field button
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _addField,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add field'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                          side: BorderSide(
                            color: isDark ? BrandColors.nightForest : BrandColors.forest,
                          ),
                        ),
                      ),

                      // Error message
                      if (_errorMessage != null) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(Radii.sm),
                          ),
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ],

                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),

              // Action buttons (pinned)
              Divider(height: 1, color: isDark
                  ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                  : BrandColors.charcoal.withValues(alpha: 0.1)),
              Padding(
                padding: EdgeInsets.fromLTRB(
                    16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _isSubmitting ? null : _handleSave,
                        style: FilledButton.styleFrom(
                          backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                        ),
                        child: _isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(isEditMode ? 'Save' : 'Create'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Stateful row for editing a single field definition.
class _FieldEditorRow extends StatefulWidget {
  final TextEditingController nameController;
  final Map<String, dynamic> field;
  final List<String> existingTypeNames;
  final bool isDark;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final VoidCallback onRemove;
  final FormFieldValidator<String>? fieldNameValidator;

  const _FieldEditorRow({
    required this.nameController,
    required this.field,
    required this.existingTypeNames,
    required this.isDark,
    required this.onChanged,
    required this.onRemove,
    this.fieldNameValidator,
    super.key,
  });

  @override
  State<_FieldEditorRow> createState() => _FieldEditorRowState();
}

class _FieldEditorRowState extends State<_FieldEditorRow> {
  final _enumValueController = TextEditingController();

  @override
  void dispose() {
    _enumValueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final fieldType = field['type'] as String;
    final isRequired = field['required'] as bool? ?? false;
    final enumValues = List<String>.from(field['values'] as List? ?? []);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: widget.isDark ? BrandColors.nightSurfaceElevated : BrandColors.cream,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Field name
                Expanded(
                  child: TextFormField(
                    controller: widget.nameController,
                    decoration: InputDecoration(
                      labelText: 'Field name',
                      hintText: 'e.g. title',
                      isDense: true,
                      filled: true,
                      fillColor: widget.isDark
                          ? BrandColors.nightSurface
                          : BrandColors.softWhite,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.sm),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    validator: widget.fieldNameValidator,
                  ),
                ),
                const SizedBox(width: 8),
                // Delete field button
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: widget.onRemove,
                  color: Colors.red.shade400,
                  tooltip: 'Remove field',
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Type selector + required toggle
            Row(
              children: [
                // Type dropdown
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: fieldType,
                    decoration: InputDecoration(
                      labelText: 'Type',
                      isDense: true,
                      filled: true,
                      fillColor: widget.isDark
                          ? BrandColors.nightSurface
                          : BrandColors.softWhite,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(Radii.sm),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    items: [
                      'string', 'integer', 'boolean', 'datetime', 'enum', 'link',
                    ].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      widget.onChanged({
                        ...field,
                        'type': v,
                        'values': <String>[],
                        'link_type': v == 'link' ? '' : null,
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // Required toggle
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Required',
                      style: TextStyle(
                        fontSize: 13,
                        color: widget.isDark
                            ? BrandColors.nightTextSecondary
                            : BrandColors.driftwood,
                      ),
                    ),
                    Switch(
                      value: isRequired,
                      onChanged: (v) {
                        widget.onChanged({...field, 'required': v});
                      },
                      activeColor: widget.isDark
                          ? BrandColors.nightForest
                          : BrandColors.forest,
                    ),
                  ],
                ),
              ],
            ),

            // Enum values editor
            if (fieldType == 'enum') ...[
              const SizedBox(height: 8),
              Text(
                'Values',
                style: TextStyle(
                  fontSize: 12,
                  color: widget.isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final v in enumValues)
                    Chip(
                      label: Text(v, style: const TextStyle(fontSize: 12)),
                      deleteIcon: const Icon(Icons.close, size: 14),
                      onDeleted: () {
                        final updated = [...enumValues]..remove(v);
                        widget.onChanged({...field, 'values': updated});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _enumValueController,
                      decoration: InputDecoration(
                        hintText: 'Add value...',
                        isDense: true,
                        filled: true,
                        fillColor: widget.isDark
                            ? BrandColors.nightSurface
                            : BrandColors.softWhite,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(Radii.sm),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (v) {
                        if (v.trim().isNotEmpty) {
                          widget.onChanged({
                            ...field,
                            'values': [...enumValues, v.trim()],
                          });
                          _enumValueController.clear();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.add, size: 18),
                    onPressed: () {
                      final v = _enumValueController.text.trim();
                      if (v.isNotEmpty) {
                        widget.onChanged({
                          ...field,
                          'values': [...enumValues, v],
                        });
                        _enumValueController.clear();
                      }
                    },
                  ),
                ],
              ),
            ],

            // Link type selector
            if (fieldType == 'link') ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: (field['link_type'] as String?)?.isNotEmpty == true
                    ? field['link_type'] as String
                    : null,
                decoration: InputDecoration(
                  labelText: 'Links to type',
                  isDense: true,
                  filled: true,
                  fillColor: widget.isDark
                      ? BrandColors.nightSurface
                      : BrandColors.softWhite,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    borderSide: BorderSide.none,
                  ),
                ),
                items: widget.existingTypeNames
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
                validator: (v) =>
                    v == null || v.isEmpty ? 'Select a target type' : null,
                onChanged: (v) {
                  widget.onChanged({...field, 'link_type': v ?? ''});
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
