import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/file_item.dart';
import '../providers/file_browser_provider.dart';

/// Screen for viewing and editing text files (json, yaml, code, etc.)
class TextViewerScreen extends ConsumerStatefulWidget {
  final FileItem file;

  const TextViewerScreen({
    super.key,
    required this.file,
  });

  @override
  ConsumerState<TextViewerScreen> createState() => _TextViewerScreenState();
}

class _TextViewerScreenState extends ConsumerState<TextViewerScreen> {
  String? _error;
  bool _isLoading = true;
  bool _isEditMode = false;
  bool _hasUnsavedChanges = false;
  bool _isSaving = false;

  String _originalContent = '';
  late TextEditingController _editController;
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController();
    _scrollController = ScrollController();
    _loadFile();
  }

  @override
  void dispose() {
    _editController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadFile() async {
    try {
      final file = File(widget.file.path);
      final content = await file.readAsString();

      _originalContent = content;
      _editController.text = content;

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  void _enterEditMode() {
    setState(() {
      _isEditMode = true;
      _editController.text = _originalContent;
      _hasUnsavedChanges = false;
    });
  }

  void _cancelEdit() {
    if (_hasUnsavedChanges) {
      _showDiscardChangesDialog();
    } else {
      _exitEditMode();
    }
  }

  void _exitEditMode() {
    setState(() {
      _isEditMode = false;
      _editController.text = _originalContent;
      _hasUnsavedChanges = false;
    });
  }

  Future<void> _showDiscardChangesDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final shouldDiscard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        title: const Text('Discard changes?'),
        content: const Text('You have unsaved changes. Are you sure you want to discard them?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
            child: const Text('Discard'),
          ),
        ],
      ),
    );

    if (shouldDiscard == true) {
      _exitEditMode();
    }
  }

  Future<void> _saveFile() async {
    if (_isSaving) return;

    setState(() => _isSaving = true);

    try {
      final service = ref.read(fileBrowserServiceProvider);
      await service.writeFile(widget.file.path, _editController.text);

      _originalContent = _editController.text;

      if (mounted) {
        setState(() {
          _hasUnsavedChanges = false;
          _isEditMode = false;
          _isSaving = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('File saved'),
            backgroundColor: BrandColors.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  void _onTextChanged() {
    final hasChanges = _editController.text != _originalContent;
    if (hasChanges != _hasUnsavedChanges) {
      setState(() => _hasUnsavedChanges = hasChanges);
    }
  }

  Future<bool> _onWillPop() async {
    if (_isEditMode && _hasUnsavedChanges) {
      final isDark = Theme.of(context).brightness == Brightness.dark;

      final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
          title: const Text('Unsaved changes'),
          content: const Text('Do you want to save your changes before leaving?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: Text(
                'Discard',
                style: TextStyle(color: BrandColors.error),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'cancel'),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              style: FilledButton.styleFrom(
                backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      );

      if (result == 'save') {
        await _saveFile();
        return true;
      } else if (result == 'discard') {
        return true;
      } else {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return PopScope(
      canPop: !(_isEditMode && _hasUnsavedChanges),
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          final canPop = await _onWillPop();
          if (canPop && mounted) {
            Navigator.of(context).pop();
          }
        }
      },
      child: Scaffold(
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
        appBar: AppBar(
          backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
          surfaceTintColor: Colors.transparent,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.file.name,
                style: TextStyle(
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  fontSize: TypographyTokens.titleMedium,
                ),
              ),
              if (_isEditMode && _hasUnsavedChanges)
                Text(
                  'Unsaved changes',
                  style: TextStyle(
                    color: BrandColors.warning,
                    fontSize: TypographyTokens.labelSmall,
                  ),
                ),
            ],
          ),
          leading: IconButton(
            icon: Icon(
              Icons.arrow_back,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
            onPressed: () async {
              final canPop = await _onWillPop();
              if (canPop && mounted) {
                Navigator.pop(context);
              }
            },
          ),
          actions: _buildAppBarActions(isDark),
        ),
        body: _buildBody(isDark),
      ),
    );
  }

  List<Widget> _buildAppBarActions(bool isDark) {
    if (_isEditMode) {
      return [
        TextButton(
          onPressed: _cancelEdit,
          child: Text(
            'Cancel',
            style: TextStyle(
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: Spacing.sm),
          child: FilledButton.icon(
            onPressed: _hasUnsavedChanges && !_isSaving ? _saveFile : null,
            icon: _isSaving
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.save, size: 18),
            label: Text(_isSaving ? 'Saving...' : 'Save'),
            style: FilledButton.styleFrom(
              backgroundColor: _hasUnsavedChanges
                  ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                  : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            ),
          ),
        ),
      ];
    } else {
      return [
        IconButton(
          icon: Icon(
            Icons.edit,
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          ),
          onPressed: _enterEditMode,
          tooltip: 'Edit file',
        ),
      ];
    }
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return _buildErrorState(isDark);
    }

    if (_isEditMode) {
      return _buildEditor(isDark);
    }

    return _buildViewer(isDark);
  }

  Widget _buildEditor(bool isDark) {
    return Container(
      color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      child: TextField(
        controller: _editController,
        onChanged: (_) => _onTextChanged(),
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: TypographyTokens.bodyMedium,
          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          height: 1.5,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(Spacing.md),
          hintText: 'Start typing...',
          hintStyle: TextStyle(
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
      ),
    );
  }

  Widget _buildViewer(bool isDark) {
    return Container(
      color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      child: Scrollbar(
        controller: _scrollController,
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(Spacing.md),
          child: SelectableText(
            _originalContent,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: TypographyTokens.bodyMedium,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: BrandColors.error,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'Failed to load file',
              style: TextStyle(
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                fontSize: TypographyTokens.titleMedium,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(
              _error ?? 'Unknown error',
              style: TextStyle(
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                fontSize: TypographyTokens.bodySmall,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.lg),
            FilledButton(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _error = null;
                });
                _loadFile();
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
