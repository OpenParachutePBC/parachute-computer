import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/file_item.dart';
import '../providers/file_browser_provider.dart';

/// Screen for viewing and editing markdown files with frontmatter support
class MarkdownViewerScreen extends ConsumerStatefulWidget {
  final FileItem file;

  const MarkdownViewerScreen({
    super.key,
    required this.file,
  });

  @override
  ConsumerState<MarkdownViewerScreen> createState() => _MarkdownViewerScreenState();
}

class _MarkdownViewerScreenState extends ConsumerState<MarkdownViewerScreen> {
  String? _error;
  bool _isLoading = true;
  bool _frontmatterExpanded = true;
  bool _isEditMode = false;
  bool _hasUnsavedChanges = false;
  bool _isSaving = false;

  // Original content for detecting changes
  String _originalContent = '';

  // Parsed content for view mode
  Map<String, dynamic>? _frontmatter;
  String _body = '';

  // Editor controller
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
      final file = File(widget.file.path);
      final content = await file.readAsString();

      _originalContent = content;
      _editController.text = content;

      // Parse frontmatter and body
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

  /// Parse markdown content into frontmatter and body
  ({Map<String, dynamic>? frontmatter, String body}) _parseContent(String content) {
    final trimmed = content.trim();

    // Check for frontmatter (starts with ---)
    if (!trimmed.startsWith('---')) {
      return (frontmatter: null, body: trimmed);
    }

    // Find the closing ---
    final endIndex = trimmed.indexOf('---', 3);
    if (endIndex == -1) {
      return (frontmatter: null, body: trimmed);
    }

    final frontmatterStr = trimmed.substring(3, endIndex).trim();
    final body = trimmed.substring(endIndex + 3).trim();

    // Parse YAML frontmatter
    Map<String, dynamic>? frontmatter;
    try {
      final yaml = loadYaml(frontmatterStr);
      if (yaml is Map) {
        frontmatter = _convertYamlToMap(yaml);
      }
    } catch (e) {
      debugPrint('[MarkdownViewer] Error parsing frontmatter: $e');
    }

    return (frontmatter: frontmatter, body: body);
  }

  /// Convert YamlMap to regular Dart Map
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
      final service = ref.read(fileBrowserServiceProvider);
      await service.writeFile(widget.file.path, _editController.text);

      // Update the original content and parsed view
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
        // Cancel button
        TextButton(
          onPressed: _cancelEdit,
          child: Text(
            'Cancel',
            style: TextStyle(
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
        ),
        // Save button
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
        // Edit button
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Frontmatter section
          if (_frontmatter != null && _frontmatter!.isNotEmpty)
            _buildFrontmatterSection(isDark),

          // Markdown body
          if (_body.isNotEmpty) _buildMarkdownBody(isDark),
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
          // Header (tappable to expand/collapse)
          InkWell(
            onTap: () => setState(() => _frontmatterExpanded = !_frontmatterExpanded),
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(Radii.md),
              bottom: _frontmatterExpanded ? Radius.zero : const Radius.circular(Radii.md),
            ),
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

          // Content
          if (_frontmatterExpanded) ...[
            Divider(
              height: 1,
              color: isDark ? BrandColors.charcoal : BrandColors.stone,
            ),
            Padding(
              padding: const EdgeInsets.all(Spacing.sm),
              child: _buildFrontmatterContent(isDark),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFrontmatterContent(bool isDark) {
    if (_frontmatter == null) return const SizedBox.shrink();

    final entries = _frontmatter!.entries.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: entries.map((entry) => _buildFrontmatterField(entry, isDark)).toList(),
    );
  }

  Widget _buildFrontmatterField(MapEntry<String, dynamic> entry, bool isDark) {
    final key = entry.key;
    final value = entry.value;

    // Handle nested maps (like 'entries' with audio metadata)
    if (value is Map<String, dynamic>) {
      return _buildNestedField(key, value, isDark);
    }

    // Handle lists
    if (value is List) {
      return _buildListField(key, value, isDark);
    }

    // Simple key-value
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              key,
              style: TextStyle(
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                fontSize: TypographyTokens.bodySmall,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              _formatValue(value),
              style: TextStyle(
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                fontSize: TypographyTokens.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNestedField(String key, Map<String, dynamic> value, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            key,
            style: TextStyle(
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              fontSize: TypographyTokens.bodySmall,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            margin: const EdgeInsets.only(left: Spacing.sm),
            padding: const EdgeInsets.all(Spacing.xs),
            decoration: BoxDecoration(
              color: isDark
                  ? BrandColors.nightSurface.withValues(alpha: 0.5)
                  : BrandColors.cream,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: value.entries.map((e) {
                if (e.value is Map<String, dynamic>) {
                  // Entry metadata (like para:abc123: {audio_path: ..., duration: ...})
                  return _buildEntryMetadata(e.key, e.value as Map<String, dynamic>, isDark);
                }
                return _buildFrontmatterField(e, isDark);
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryMetadata(String entryId, Map<String, dynamic> metadata, bool isDark) {
    // Format entry ID nicely (truncate if too long)
    final displayId = entryId.length > 12 ? '${entryId.substring(0, 12)}...' : entryId;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.all(Spacing.xs),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            displayId,
            style: TextStyle(
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              fontSize: TypographyTokens.labelSmall,
              fontFamily: 'monospace',
            ),
          ),
          ...metadata.entries.map((e) => Padding(
            padding: const EdgeInsets.only(left: Spacing.xs, top: 2),
            child: Row(
              children: [
                Text(
                  '${e.key}: ',
                  style: TextStyle(
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    fontSize: TypographyTokens.labelSmall,
                  ),
                ),
                Expanded(
                  child: Text(
                    _formatValue(e.value),
                    style: TextStyle(
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      fontSize: TypographyTokens.labelSmall,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildListField(String key, List value, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$key (${value.length} items)',
            style: TextStyle(
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              fontSize: TypographyTokens.bodySmall,
              fontWeight: FontWeight.w500,
            ),
          ),
          ...value.take(5).map((item) => Padding(
            padding: const EdgeInsets.only(left: Spacing.sm, top: 2),
            child: Text(
              '• ${_formatValue(item)}',
              style: TextStyle(
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                fontSize: TypographyTokens.bodySmall,
              ),
            ),
          )),
          if (value.length > 5)
            Padding(
              padding: const EdgeInsets.only(left: Spacing.sm, top: 2),
              child: Text(
                '... and ${value.length - 5} more',
                style: TextStyle(
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  fontSize: TypographyTokens.labelSmall,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _formatValue(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return value;
    if (value is num) return value.toString();
    if (value is bool) return value.toString();
    if (value is DateTime) return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
    return value.toString();
  }

  Widget _buildMarkdownBody(bool isDark) {
    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;

    return MarkdownBody(
      data: _body,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.bodyMedium,
          height: TypographyTokens.lineHeightRelaxed,
        ),
        code: TextStyle(
          color: textColor,
          backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
          fontFamily: 'monospace',
          fontSize: TypographyTokens.bodySmall,
        ),
        codeblockDecoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        codeblockPadding: const EdgeInsets.all(Spacing.sm),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
              width: 3,
            ),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: Spacing.md),
        h1: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.headlineLarge,
          fontWeight: FontWeight.bold,
          height: 1.4,
        ),
        h2: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.headlineMedium,
          fontWeight: FontWeight.bold,
          height: 1.4,
        ),
        h3: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.headlineSmall,
          fontWeight: FontWeight.bold,
          height: 1.4,
        ),
        h4: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.titleLarge,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        h5: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.titleMedium,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        h6: TextStyle(
          color: textColor,
          fontSize: TypographyTokens.titleSmall,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
        listBullet: TextStyle(color: textColor),
        listIndent: 24,
        tableHead: TextStyle(
          color: textColor,
          fontWeight: FontWeight.bold,
        ),
        tableBody: TextStyle(color: textColor),
        tableBorder: TableBorder.all(
          color: isDark ? BrandColors.charcoal : BrandColors.stone,
          width: 1,
        ),
        tableCellsPadding: const EdgeInsets.all(Spacing.xs),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: isDark ? BrandColors.charcoal : BrandColors.stone,
              width: 1,
            ),
          ),
        ),
        a: TextStyle(
          color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
          decoration: TextDecoration.underline,
        ),
        strong: TextStyle(
          color: textColor,
          fontWeight: FontWeight.bold,
        ),
        em: TextStyle(
          color: textColor,
          fontStyle: FontStyle.italic,
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
