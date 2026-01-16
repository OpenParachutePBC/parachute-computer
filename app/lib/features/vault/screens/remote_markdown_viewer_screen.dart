import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/file_item.dart';
import 'remote_files_screen.dart';

/// Screen for viewing and editing markdown files from remote server
class RemoteMarkdownViewerScreen extends ConsumerStatefulWidget {
  final FileItem file;

  const RemoteMarkdownViewerScreen({
    super.key,
    required this.file,
  });

  @override
  ConsumerState<RemoteMarkdownViewerScreen> createState() => _RemoteMarkdownViewerScreenState();
}

class _RemoteMarkdownViewerScreenState extends ConsumerState<RemoteMarkdownViewerScreen> {
  String? _error;
  bool _isLoading = true;
  bool _frontmatterExpanded = true;
  bool _isEditMode = false;
  bool _hasUnsavedChanges = false;
  bool _isSaving = false;

  String _originalContent = '';
  Map<String, dynamic>? _frontmatter;
  String _body = '';

  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController();
    _loadFile();
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  Future<void> _loadFile() async {
    try {
      final service = ref.read(remoteFileBrowserServiceProvider);
      if (service == null) {
        throw Exception('No server configured');
      }

      final content = await service.readFile(widget.file.path);
      if (content == null) {
        throw Exception('Could not read file');
      }

      _originalContent = content;
      _editController.text = content;

      final parsed = _parseContent(content);

      if (mounted) {
        setState(() {
          _frontmatter = parsed.frontmatter;
          _body = parsed.body;
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

  ({Map<String, dynamic>? frontmatter, String body}) _parseContent(String content) {
    final trimmed = content.trim();

    if (!trimmed.startsWith('---')) {
      return (frontmatter: null, body: trimmed);
    }

    final endIndex = trimmed.indexOf('---', 3);
    if (endIndex == -1) {
      return (frontmatter: null, body: trimmed);
    }

    final frontmatterStr = trimmed.substring(3, endIndex).trim();
    final body = trimmed.substring(endIndex + 3).trim();

    Map<String, dynamic>? frontmatter;
    try {
      final yaml = loadYaml(frontmatterStr);
      if (yaml is Map) {
        frontmatter = _convertYamlToMap(yaml);
      }
    } catch (e) {
      debugPrint('[RemoteMarkdownViewer] Error parsing frontmatter: $e');
    }

    return (frontmatter: frontmatter, body: body);
  }

  Map<String, dynamic> _convertYamlToMap(dynamic yaml) {
    if (yaml is Map) {
      return yaml.map((key, value) => MapEntry(
        key.toString(),
        value is Map ? _convertYamlToMap(value) : value,
      ));
    }
    return {};
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
      final service = ref.read(remoteFileBrowserServiceProvider);
      if (service == null) {
        throw Exception('No server configured');
      }

      final success = await service.writeFile(widget.file.path, _editController.text);
      if (!success) {
        throw Exception('Failed to save file');
      }

      _originalContent = _editController.text;
      final parsed = _parseContent(_originalContent);

      if (mounted) {
        setState(() {
          _frontmatter = parsed.frontmatter;
          _body = parsed.body;
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
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
          onPressed: () => Navigator.pop(context),
        ),
        actions: _buildAppBarActions(isDark),
      ),
      body: _buildBody(isDark),
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
    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_frontmatter != null && _frontmatter!.isNotEmpty)
            _buildFrontmatterSection(isDark),
          if (_body.isNotEmpty)
            MarkdownBody(
              data: _body,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(
                  color: textColor,
                  fontSize: TypographyTokens.bodyMedium,
                  height: TypographyTokens.lineHeightRelaxed,
                ),
                h1: TextStyle(
                  color: textColor,
                  fontSize: TypographyTokens.headlineLarge,
                  fontWeight: FontWeight.bold,
                ),
                h2: TextStyle(
                  color: textColor,
                  fontSize: TypographyTokens.headlineMedium,
                  fontWeight: FontWeight.bold,
                ),
                h3: TextStyle(
                  color: textColor,
                  fontSize: TypographyTokens.headlineSmall,
                  fontWeight: FontWeight.bold,
                ),
                code: TextStyle(
                  color: textColor,
                  backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
                  fontFamily: 'monospace',
                ),
                a: TextStyle(
                  color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFrontmatterSection(bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: Spacing.md),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: isDark ? BrandColors.charcoal : BrandColors.stone,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _frontmatterExpanded = !_frontmatterExpanded),
            child: Padding(
              padding: const EdgeInsets.all(Spacing.sm),
              child: Row(
                children: [
                  Icon(
                    Icons.data_object,
                    size: 18,
                    color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    'Frontmatter',
                    style: TextStyle(
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      fontWeight: FontWeight.w600,
                      fontSize: TypographyTokens.labelMedium,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _frontmatterExpanded ? Icons.expand_less : Icons.expand_more,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ],
              ),
            ),
          ),
          if (_frontmatterExpanded) ...[
            Divider(
              height: 1,
              color: isDark ? BrandColors.charcoal : BrandColors.stone,
            ),
            Padding(
              padding: const EdgeInsets.all(Spacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _frontmatter!.entries.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 80,
                        child: Text(
                          e.key,
                          style: TextStyle(
                            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                            fontSize: TypographyTokens.bodySmall,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          e.value.toString(),
                          style: TextStyle(
                            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                            fontSize: TypographyTokens.bodySmall,
                          ),
                        ),
                      ),
                    ],
                  ),
                )).toList(),
              ),
            ),
          ],
        ],
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
