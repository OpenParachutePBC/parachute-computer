import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/brain_v2_schema.dart';
import '../providers/brain_v2_providers.dart';
import '../widgets/brain_v2_form_builder.dart';

/// Entity create/edit form screen.
class BrainV2EntityFormScreen extends ConsumerStatefulWidget {
  final String entityType;
  final String? entityId; // Null for create mode, non-null for edit mode

  const BrainV2EntityFormScreen({
    required this.entityType,
    this.entityId,
    super.key,
  });

  @override
  ConsumerState<BrainV2EntityFormScreen> createState() =>
      _BrainV2EntityFormScreenState();
}

class _BrainV2EntityFormScreenState
    extends ConsumerState<BrainV2EntityFormScreen> {
  final _commitMsgController = TextEditingController();
  Map<String, dynamic> _formData = {};
  bool _isSubmitting = false;

  bool get _isEditMode => widget.entityId != null;

  @override
  void initState() {
    super.initState();
    _commitMsgController.text = _isEditMode
        ? 'Update ${widget.entityType}'
        : 'Create ${widget.entityType}';
  }

  @override
  void dispose() {
    _commitMsgController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final schemasAsync = ref.watch(brainV2SchemaListProvider);
    final existingEntityAsync = _isEditMode
        ? ref.watch(brainV2EntityDetailProvider(widget.entityId!))
        : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditMode ? 'Edit ${widget.entityType}' : 'Create ${widget.entityType}',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor:
            isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: schemasAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
              const SizedBox(height: 16),
              Text('Failed to load schema: $error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
        data: (schemas) {
          final schema = schemas.firstWhere(
            (s) => s.name == widget.entityType,
            orElse: () => schemas.first,
          );

          // For edit mode, wait for existing entity to load
          if (_isEditMode && existingEntityAsync != null) {
            return existingEntityAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
                    const SizedBox(height: 16),
                    Text('Failed to load entity: $error'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Go Back'),
                    ),
                  ],
                ),
              ),
              data: (entity) {
                if (entity == null) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.search_off, size: 48),
                        const SizedBox(height: 16),
                        const Text('Entity not found'),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Go Back'),
                        ),
                      ],
                    ),
                  );
                }

                return _buildForm(schema, isDark, initialData: entity.fields);
              },
            );
          }

          // Create mode or edit mode with no initial data yet
          return _buildForm(schema, isDark);
        },
      ),
    );
  }

  Widget _buildForm(
    BrainV2Schema schema,
    bool isDark, {
    Map<String, dynamic>? initialData,
  }) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Dynamic form fields
          BrainV2FormBuilder(
            schema: schema,
            initialData: initialData,
            onDataChanged: (data) {
              setState(() {
                _formData = data;
              });
            },
          ),

          const SizedBox(height: 24),

          // Commit message (optional)
          Text(
            'Commit Message (optional)',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _commitMsgController,
            decoration: InputDecoration(
              hintText: 'Describe this change',
              filled: true,
              fillColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Radii.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),

          const SizedBox(height: 32),

          // Submit button
          ElevatedButton(
            onPressed: _isSubmitting ? null : () => _handleSubmit(schema),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  isDark ? BrandColors.nightForest : BrandColors.forest,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Radii.md),
              ),
            ),
            child: _isSubmitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : Text(
                    _isEditMode ? 'Update ${widget.entityType}' : 'Create ${widget.entityType}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),

          const SizedBox(height: 16),

          // Cancel button
          TextButton(
            onPressed: _isSubmitting
                ? null
                : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),

          const SizedBox(height: 80),
        ],
      ),
    );
  }

  Future<void> _handleSubmit(BrainV2Schema schema) async {
    // Validate required fields
    final missingFields = schema.fields
        .where((f) => f.required && (_formData[f.name] == null || _formData[f.name] == ''))
        .map((f) => f.name)
        .toList();

    if (missingFields.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Missing required fields: ${missingFields.join(', ')}'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final service = ref.read(brainV2ServiceProvider);
      if (service == null) {
        throw Exception('Service not available');
      }

      final commitMsg = _commitMsgController.text.trim().isEmpty
          ? null
          : _commitMsgController.text.trim();

      if (_isEditMode) {
        // Update existing entity
        await service.updateEntity(
          widget.entityId!,
          _formData,
          commitMsg: commitMsg,
        );

        // Invalidate providers to refresh
        ref.invalidate(brainV2EntityDetailProvider(widget.entityId!));
        ref.invalidate(brainV2EntityListProvider);

        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Entity updated successfully')),
          );
        }
      } else {
        // Create new entity
        final entityId = await service.createEntity(
          widget.entityType,
          _formData,
          commitMsg: commitMsg,
        );

        // Invalidate list provider to refresh
        ref.invalidate(brainV2EntityListProvider);

        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('Created entity: $entityId')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }
}
