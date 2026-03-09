import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/compose_draft_provider.dart';
import '../widgets/markdown_text_controller.dart';

/// Result returned from the compose screen when the user saves.
class ComposeResult {
  final String title;
  final String content;

  const ComposeResult({required this.title, required this.content});
}

/// Full-screen markdown compose screen.
///
/// Opens from the input bar expand button or when editing a text entry.
/// Features:
/// - Source editing with lightweight inline styling (bold, italic, code)
/// - Preview toggle to see fully rendered markdown
/// - Optional title field
/// - Markdown formatting toolbar above keyboard
/// - Auto-save draft to SharedPreferences
class ComposeScreen extends ConsumerStatefulWidget {
  final String? initialTitle;
  final String? initialContent;
  final bool isEditing;

  const ComposeScreen({
    super.key,
    this.initialTitle,
    this.initialContent,
    this.isEditing = false,
  });

  @override
  ConsumerState<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends ConsumerState<ComposeScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _titleController;
  late final MarkdownTextEditingController _contentController;
  final FocusNode _contentFocusNode = FocusNode();
  final FocusNode _titleFocusNode = FocusNode();
  bool _showPreview = false;
  bool _draftRestored = false;
  bool _shouldRestoreDraft = false;

  bool get _hasContent =>
      _titleController.text.trim().isNotEmpty ||
      _contentController.text.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    final isDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;

    _titleController = TextEditingController(text: widget.initialTitle ?? '');
    _contentController = MarkdownTextEditingController(
      text: widget.initialContent ?? '',
      syntaxColor: BrandColors.driftwood,
      bodyColor: isDark ? BrandColors.stone : BrandColors.charcoal,
    );

    // If no initial content, draft will be restored reactively via
    // ref.listen in build() — handles both sync cache hits and async loads.
    _shouldRestoreDraft =
        (widget.initialContent == null || widget.initialContent!.isEmpty) &&
        (widget.initialTitle == null || widget.initialTitle!.isEmpty) &&
        !widget.isEditing;

    _titleController.addListener(_onTextChanged);
    _contentController.addListener(_onTextChanged);

    // Auto-focus content field
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_showPreview) _contentFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _titleController.dispose();
    _contentController.dispose();
    _contentFocusNode.dispose();
    _titleFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (_hasContent && !widget.isEditing) {
        ref.read(composeDraftProvider.notifier).flushDraft(
              _titleController.text,
              _contentController.text,
            );
      }
    }
  }

  void _restoreDraft(ComposeDraft draft) {
    if (_draftRestored || draft.isEmpty) return;
    _draftRestored = true;
    _titleController.text = draft.title;
    _contentController.text = draft.content;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Draft restored'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _onTextChanged() {
    // No setState — save button uses ValueListenableBuilder to
    // avoid rebuilding the entire compose screen on every keystroke.
    if (!widget.isEditing) {
      ref.read(composeDraftProvider.notifier).saveDraft(
            _titleController.text,
            _contentController.text,
          );
    }
  }

  void _save() {
    final content = _contentController.text.trim();
    if (content.isEmpty) return;

    final title = _titleController.text.trim();

    if (!widget.isEditing) {
      ref.read(composeDraftProvider.notifier).clearDraft();
    }

    Navigator.of(context).pop(ComposeResult(title: title, content: content));
  }

  Future<bool> _onWillPop() async {
    if (!_hasContent) return true;

    if (!widget.isEditing) return true;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your changes will not be saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _togglePreview() {
    setState(() {
      _showPreview = !_showPreview;
      if (!_showPreview) {
        // Returning to source — refocus editor
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _contentFocusNode.requestFocus();
        });
      } else {
        // Entering preview — dismiss keyboard
        FocusScope.of(context).unfocus();
      }
    });
  }

  /// Insert markdown syntax around the current selection or at cursor.
  /// Uses [TextEditingValue] to preserve IME composing state.
  void _insertMarkdown(String prefix, [String? suffix]) {
    final text = _contentController.text;
    final selection = _contentController.selection;
    suffix ??= prefix;

    if (selection.isCollapsed) {
      final newText = text.substring(0, selection.start) +
          prefix +
          suffix +
          text.substring(selection.start);
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start + prefix.length,
        ),
      );
    } else {
      final selected = text.substring(selection.start, selection.end);
      final newText = text.substring(0, selection.start) +
          prefix +
          selected +
          suffix +
          text.substring(selection.end);
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: selection.start + prefix.length,
          extentOffset: selection.end + prefix.length,
        ),
      );
    }

    _contentFocusNode.requestFocus();
  }

  /// Insert markdown at the start of the current line.
  /// Uses [TextEditingValue] to preserve IME composing state.
  void _insertLinePrefix(String prefix) {
    final text = _contentController.text;
    final selection = _contentController.selection;

    var lineStart = selection.start;
    while (lineStart > 0 && text[lineStart - 1] != '\n') {
      lineStart--;
    }

    if (text.substring(lineStart).startsWith(prefix)) {
      final newText =
          text.substring(0, lineStart) + text.substring(lineStart + prefix.length);
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start - prefix.length,
        ),
      );
    } else {
      final newText =
          text.substring(0, lineStart) + prefix + text.substring(lineStart);
      _contentController.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(
          offset: selection.start + prefix.length,
        ),
      );
    }

    _contentFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    // Reactively restore draft when async _loadDraft() completes
    if (_shouldRestoreDraft) {
      ref.listen<ComposeDraft>(composeDraftProvider, (prev, next) {
        if (!_draftRestored && next.isNotEmpty) {
          _restoreDraft(next);
        }
      });
      // Also check current value (covers sync cache hit)
      final current = ref.read(composeDraftProvider);
      if (!_draftRestored && current.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _restoreDraft(current);
        });
      }
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (shouldPop && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor:
            isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        appBar: AppBar(
          backgroundColor:
              isDark ? BrandColors.nightSurface : BrandColors.softWhite,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              final shouldPop = await _onWillPop();
              if (shouldPop && context.mounted) {
                Navigator.of(context).pop();
              }
            },
          ),
          actions: [
            // Preview toggle
            IconButton(
              icon: Icon(
                _showPreview ? Icons.edit : Icons.visibility,
                color: isDark ? BrandColors.stone : BrandColors.charcoal,
              ),
              tooltip: _showPreview ? 'Edit' : 'Preview',
              onPressed: _togglePreview,
            ),
            // Save button — scoped rebuild via ValueListenableBuilder
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _contentController,
                builder: (context, value, _) {
                  final canSave = value.text.trim().isNotEmpty;
                  return TextButton(
                    onPressed: canSave ? _save : null,
                    child: Text(
                      widget.isEditing ? 'Update' : 'Save',
                      style: TextStyle(
                        color: canSave
                            ? BrandColors.forest
                            : BrandColors.driftwood,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            // Title field (always editable, not part of preview)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _titleController,
                focusNode: _titleFocusNode,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  hintText: 'Title (optional)',
                  hintStyle: TextStyle(
                    color: BrandColors.driftwood,
                    fontWeight: FontWeight.w400,
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _contentFocusNode.requestFocus(),
              ),
            ),
            const Divider(height: 1),

            // Content area — source or preview
            Expanded(
              child: _showPreview
                  ? _buildPreview(theme, isDark)
                  : _buildSourceEditor(theme, isDark),
            ),

            // Toolbar (only in source mode)
            if (!_showPreview) _buildToolbar(isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceEditor(ThemeData theme, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: TextField(
        controller: _contentController,
        focusNode: _contentFocusNode,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.newline,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: isDark ? BrandColors.stone : BrandColors.charcoal,
          height: 1.6,
        ),
        decoration: InputDecoration(
          hintText: 'Start writing...',
          hintStyle: TextStyle(color: BrandColors.driftwood),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildPreview(ThemeData theme, bool isDark) {
    final content = _contentController.text;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: content.isEmpty
          ? Text(
              'Nothing to preview',
              style: TextStyle(
                color: BrandColors.driftwood,
                fontStyle: FontStyle.italic,
              ),
            )
          : MarkdownBody(
              data: content,
              shrinkWrap: true,
              softLineBreak: true,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: theme.textTheme.bodyLarge?.copyWith(
                  color: isDark ? BrandColors.stone : BrandColors.charcoal,
                  height: 1.6,
                ),
                h1: theme.textTheme.headlineMedium?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.bold,
                ),
                h2: theme.textTheme.headlineSmall?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w600,
                ),
                h3: theme.textTheme.titleLarge?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  fontWeight: FontWeight.w600,
                ),
                listBullet: theme.textTheme.bodyLarge?.copyWith(
                  color: isDark ? BrandColors.stone : BrandColors.charcoal,
                ),
                code: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  backgroundColor: isDark
                      ? BrandColors.charcoal.withValues(alpha: 0.3)
                      : BrandColors.stone.withValues(alpha: 0.3),
                  color: isDark
                      ? BrandColors.turquoise
                      : BrandColors.turquoiseDeep,
                ),
                blockquoteDecoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: BrandColors.driftwood,
                      width: 3,
                    ),
                  ),
                ),
                blockquotePadding:
                    const EdgeInsets.only(left: 12, top: 4, bottom: 4),
              ),
            ),
    );
  }

  Widget _buildToolbar(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.cream,
        border: Border(
          top: BorderSide(
            color: isDark ? BrandColors.charcoal : BrandColors.stone,
            width: 0.5,
          ),
        ),
      ),
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: 4,
        bottom: MediaQuery.viewInsetsOf(context).bottom > 0
            ? 4
            : MediaQuery.paddingOf(context).bottom + 4,
      ),
      child: Row(
        children: [
          _toolbarButton(
            icon: Icons.format_bold,
            tooltip: 'Bold',
            onTap: () => _insertMarkdown('**'),
            isDark: isDark,
          ),
          _toolbarButton(
            icon: Icons.format_italic,
            tooltip: 'Italic',
            onTap: () => _insertMarkdown('*'),
            isDark: isDark,
          ),
          _toolbarButton(
            icon: Icons.title,
            tooltip: 'Heading',
            onTap: () => _insertLinePrefix('# '),
            isDark: isDark,
          ),
          _toolbarButton(
            icon: Icons.format_list_bulleted,
            tooltip: 'List',
            onTap: () => _insertLinePrefix('- '),
            isDark: isDark,
          ),
          _toolbarButton(
            icon: Icons.format_quote,
            tooltip: 'Quote',
            onTap: () => _insertLinePrefix('> '),
            isDark: isDark,
          ),
          const Spacer(),
          _toolbarButton(
            icon: Icons.keyboard_hide,
            tooltip: 'Hide keyboard',
            onTap: () => FocusScope.of(context).unfocus(),
            isDark: isDark,
          ),
        ],
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        icon: Icon(icon, size: 22),
        color: isDark ? BrandColors.stone : BrandColors.charcoal,
        tooltip: tooltip,
        onPressed: onTap,
        constraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
      ),
    );
  }
}
