import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_schema.dart';
import '../models/brain_field.dart';

/// Dynamic form builder that generates form fields from schema.
class BrainFormBuilder extends StatefulWidget {
  final BrainSchema schema;
  final Map<String, dynamic>? initialData; // For edit mode
  final void Function(Map<String, dynamic> data) onDataChanged;

  const BrainFormBuilder({
    required this.schema,
    required this.onDataChanged,
    this.initialData,
    super.key,
  });

  @override
  State<BrainFormBuilder> createState() => _BrainFormBuilderState();
}

class _BrainFormBuilderState extends State<BrainFormBuilder> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, dynamic> _formData = {};

  @override
  void initState() {
    super.initState();
    _initializeControllers();
  }

  void _initializeControllers() {
    for (final field in widget.schema.fields) {
      final initialValue = widget.initialData?[field.name];

      if (field.type == 'string' || field.type == 'integer' || field.type == 'datetime') {
        final controller = TextEditingController(
          text: initialValue?.toString() ?? '',
        );
        controller.addListener(() => _updateFormData());
        _controllers[field.name] = controller;
      } else if (field.type == 'boolean') {
        _formData[field.name] = initialValue is bool ? initialValue : false;
      } else if (field.isEnum) {
        _formData[field.name] = initialValue?.toString();
      } else if (field.type == 'array' && field.itemsType == 'string') {
        final list = initialValue is List ? initialValue : [];
        final text = list.join(', ');
        final controller = TextEditingController(text: text);
        controller.addListener(() => _updateFormData());
        _controllers[field.name] = controller;
      } else {
        _formData[field.name] = initialValue;
      }
    }
  }

  void _updateFormData() {
    // Schedule state update for after current frame to avoid setState during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          for (final field in widget.schema.fields) {
            if (_controllers.containsKey(field.name)) {
              final text = _controllers[field.name]!.text;

              if (field.type == 'integer') {
                _formData[field.name] = text.isEmpty ? null : int.tryParse(text);
              } else if (field.type == 'array' && field.itemsType == 'string') {
                _formData[field.name] = text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList();
              } else {
                _formData[field.name] = text.isEmpty ? null : text;
              }
            }
          }
        });

        // Notify parent after setState completes
        widget.onDataChanged(_formData);
      }
    });
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widget.schema.fields.map((field) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    field.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? BrandColors.nightText
                          : BrandColors.charcoal,
                    ),
                  ),
                  if (field.required) ...[
                    const SizedBox(width: 4),
                    Text(
                      '*',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark
                            ? Colors.red.shade400
                            : Colors.red.shade700,
                      ),
                    ),
                  ],
                ],
              ),
              if (field.description != null) ...[
                const SizedBox(height: 4),
                Text(
                  field.description!,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              _buildFieldInput(field, isDark),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildFieldInput(BrainField field, bool isDark) {
    if (field.type == 'boolean') {
      return _buildBooleanField(field, isDark);
    } else if (field.isEnum) {
      return _buildEnumField(field, isDark);
    } else if (field.type == 'integer') {
      return _buildIntegerField(field, isDark);
    } else if (field.type == 'array' && field.itemsType == 'string') {
      return _buildArrayField(field, isDark);
    } else if (field.type == 'datetime') {
      return _buildDateTimeField(field, isDark);
    } else {
      return _buildTextField(field, isDark);
    }
  }

  Widget _buildTextField(BrainField field, bool isDark) {
    return TextField(
      controller: _controllers[field.name],
      decoration: InputDecoration(
        hintText: 'Enter ${field.name}',
        filled: true,
        fillColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
      ),
      maxLines: field.name.contains('description') || field.name.contains('content') ? 3 : 1,
    );
  }

  Widget _buildIntegerField(BrainField field, bool isDark) {
    return TextField(
      controller: _controllers[field.name],
      decoration: InputDecoration(
        hintText: 'Enter ${field.name}',
        filled: true,
        fillColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
      ),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
  }

  Widget _buildBooleanField(BrainField field, bool isDark) {
    return SwitchListTile(
      title: Text(_formData[field.name] == true ? 'Yes' : 'No'),
      value: _formData[field.name] == true,
      onChanged: (value) {
        setState(() {
          _formData[field.name] = value;
        });
        widget.onDataChanged(_formData);
      },
      activeColor: isDark ? BrandColors.nightForest : BrandColors.forest,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildEnumField(BrainField field, bool isDark) {
    return DropdownButtonFormField<String>(
      value: _formData[field.name],
      decoration: InputDecoration(
        hintText: 'Select ${field.name}',
        filled: true,
        fillColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
      ),
      items: field.enumValues?.map((value) {
        return DropdownMenuItem(
          value: value,
          child: Text(value),
        );
      }).toList(),
      onChanged: (value) {
        setState(() {
          _formData[field.name] = value;
        });
        widget.onDataChanged(_formData);
      },
    );
  }

  Widget _buildArrayField(BrainField field, bool isDark) {
    return TextField(
      controller: _controllers[field.name],
      decoration: InputDecoration(
        hintText: 'Enter items separated by commas',
        filled: true,
        fillColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
        helperText: 'Separate items with commas',
      ),
      maxLines: 2,
    );
  }

  Widget _buildDateTimeField(BrainField field, bool isDark) {
    return TextField(
      controller: _controllers[field.name],
      decoration: InputDecoration(
        hintText: 'YYYY-MM-DD HH:MM:SS',
        filled: true,
        fillColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: BorderSide.none,
        ),
        suffixIcon: IconButton(
          icon: const Icon(Icons.calendar_today),
          onPressed: () => _selectDateTime(field, isDark),
        ),
      ),
    );
  }

  Future<void> _selectDateTime(BrainField field, bool isDark) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (date != null && mounted) {
      final time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.now(),
      );

      if (time != null && mounted) {
        final dateTime = DateTime(
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        );

        _controllers[field.name]?.text = dateTime.toIso8601String();
        _updateFormData();
      }
    }
  }
}
