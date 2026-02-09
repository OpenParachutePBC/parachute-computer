import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/settings/models/trust_level.dart';
import '../models/workspace.dart';
import '../providers/workspace_providers.dart';

/// Shared workspace form fields used by both create and edit dialogs.
///
/// Provides: name, description, working directory, trust level, and model.
class _WorkspaceForm extends StatelessWidget {
  final TextEditingController nameController;
  final TextEditingController descController;
  final TextEditingController dirController;
  final String trustLevel;
  final String? model;
  final ValueChanged<String> onTrustChanged;
  final ValueChanged<String?> onModelChanged;
  final bool autofocusName;

  const _WorkspaceForm({
    required this.nameController,
    required this.descController,
    required this.dirController,
    required this.trustLevel,
    required this.model,
    required this.onTrustChanged,
    required this.onModelChanged,
    this.autofocusName = false,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameController,
            autofocus: autofocusName,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          SizedBox(height: Spacing.md),
          TextField(
            controller: descController,
            decoration: const InputDecoration(labelText: 'Description (optional)'),
          ),
          SizedBox(height: Spacing.md),
          TextField(
            controller: dirController,
            decoration: const InputDecoration(
              labelText: 'Working directory (optional)',
              hintText: 'e.g., Projects/my-app',
            ),
          ),
          SizedBox(height: Spacing.md),
          DropdownButtonFormField<String>(
            value: trustLevel,
            decoration: const InputDecoration(labelText: 'Trust level'),
            items: TrustLevel.values
                .map((tl) => DropdownMenuItem(
                      value: tl.name,
                      child: Row(
                        children: [
                          Icon(tl.icon, size: 16, color: tl.iconColor(Theme.of(context).brightness == Brightness.dark)),
                          const SizedBox(width: 8),
                          Text(tl.displayName),
                        ],
                      ),
                    ))
                .toList(),
            onChanged: (val) => onTrustChanged(val ?? 'trusted'),
          ),
          SizedBox(height: Spacing.md),
          DropdownButtonFormField<String?>(
            value: model,
            decoration: const InputDecoration(labelText: 'Default model'),
            items: const [
              DropdownMenuItem(value: null, child: Text('Server default')),
              DropdownMenuItem(value: 'sonnet', child: Text('Sonnet')),
              DropdownMenuItem(value: 'opus', child: Text('Opus')),
              DropdownMenuItem(value: 'haiku', child: Text('Haiku')),
            ],
            onChanged: (val) => onModelChanged(val),
          ),
        ],
      ),
    );
  }
}

/// Dialog for creating a new workspace.
///
/// Used from both the sidebar and the settings workspace management section.
class CreateWorkspaceDialog extends ConsumerStatefulWidget {
  /// Called after successful creation.
  final void Function(Workspace created)? onCreated;

  const CreateWorkspaceDialog({super.key, this.onCreated});

  /// Show the dialog and return the created workspace (or null if cancelled).
  static Future<Workspace?> show(BuildContext context, {void Function(Workspace)? onCreated}) {
    return showDialog<Workspace>(
      context: context,
      builder: (_) => CreateWorkspaceDialog(onCreated: onCreated),
    );
  }

  @override
  ConsumerState<CreateWorkspaceDialog> createState() => _CreateWorkspaceDialogState();
}

class _CreateWorkspaceDialogState extends ConsumerState<CreateWorkspaceDialog> {
  final _nameController = TextEditingController();
  final _descController = TextEditingController();
  final _dirController = TextEditingController();
  String _trustLevel = 'trusted';
  String? _model;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _dirController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Workspace'),
      content: _WorkspaceForm(
        nameController: _nameController,
        descController: _descController,
        dirController: _dirController,
        trustLevel: _trustLevel,
        model: _model,
        onTrustChanged: (val) => setState(() => _trustLevel = val),
        onModelChanged: (val) => setState(() => _model = val),
        autofocusName: true,
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;

    setState(() => _isSubmitting = true);
    try {
      final service = ref.read(workspaceServiceProvider);
      final ws = await service.createWorkspace(
        name: name,
        description: _descController.text.trim(),
        trustLevel: _trustLevel,
        workingDirectory: _dirController.text.trim().isEmpty ? null : _dirController.text.trim(),
        model: _model,
      );
      widget.onCreated?.call(ws);
      if (mounted) Navigator.pop(context, ws);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create workspace: $e')),
        );
        setState(() => _isSubmitting = false);
      }
    }
  }
}

/// Dialog for editing an existing workspace.
///
/// Used from both the sidebar and the settings workspace management section.
class EditWorkspaceDialog extends ConsumerStatefulWidget {
  final Workspace workspace;
  final VoidCallback? onSaved;

  const EditWorkspaceDialog({super.key, required this.workspace, this.onSaved});

  /// Show the dialog. Returns true if the workspace was saved.
  static Future<bool?> show(BuildContext context, Workspace workspace, {VoidCallback? onSaved}) {
    return showDialog<bool>(
      context: context,
      builder: (_) => EditWorkspaceDialog(workspace: workspace, onSaved: onSaved),
    );
  }

  @override
  ConsumerState<EditWorkspaceDialog> createState() => _EditWorkspaceDialogState();
}

class _EditWorkspaceDialogState extends ConsumerState<EditWorkspaceDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late final TextEditingController _dirController;
  late String _trustLevel;
  late String? _model;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.workspace.name);
    _descController = TextEditingController(text: widget.workspace.description);
    _dirController = TextEditingController(text: widget.workspace.workingDirectory ?? '');
    _trustLevel = widget.workspace.trustLevel;
    _model = widget.workspace.model;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _dirController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit "${widget.workspace.name}"'),
      content: _WorkspaceForm(
        nameController: _nameController,
        descController: _descController,
        dirController: _dirController,
        trustLevel: _trustLevel,
        model: _model,
        onTrustChanged: (val) => setState(() => _trustLevel = val),
        onModelChanged: (val) => setState(() => _model = val),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    setState(() => _isSubmitting = true);
    try {
      final service = ref.read(workspaceServiceProvider);
      final updates = <String, dynamic>{
        'name': _nameController.text.trim(),
        'description': _descController.text.trim(),
        'trust_level': _trustLevel,
        'working_directory': _dirController.text.trim().isEmpty ? null : _dirController.text.trim(),
        'model': _model,
      };
      await service.updateWorkspace(widget.workspace.slug, updates);
      widget.onSaved?.call();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
        setState(() => _isSubmitting = false);
      }
    }
  }
}

/// Confirm deletion of a workspace. Returns true if confirmed.
Future<bool> confirmDeleteWorkspace(BuildContext context, Workspace workspace) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete "${workspace.name}"?'),
      content: const Text(
        'Sessions in this workspace will be unlinked but not deleted.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return result ?? false;
}
