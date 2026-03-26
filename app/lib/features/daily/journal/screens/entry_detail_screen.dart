import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/widgets/tag_input.dart';
import '../models/journal_entry.dart';

/// Result returned when composing a new entry via Navigator.pop.
class ComposeResult {
  final String title;
  final String content;

  const ComposeResult({required this.title, required this.content});
}

/// Unified entry detail screen — replaces both ComposeScreen (text entries)
/// and EntryEditModal (voice/photo/handwriting).
///
/// Opens in **read mode** by default, with an "Edit" button to switch to
/// edit mode. For new entries (entry == null), opens directly in edit mode.
class EntryDetailScreen extends ConsumerStatefulWidget {
  /// The entry to view/edit. Null for new entries (compose mode).
  final JournalEntry? entry;

  /// Whether to start in edit mode (true for new entries).
  final bool startInEditMode;

  /// System-wide tags for autocomplete suggestions.
  final List<String> allTags;

  /// Audio player widget for voice entries.
  final Widget? audioPlayer;

  /// Callback for saving edits to an existing entry.
  /// If null, pops with ComposeResult (new entry mode).
  final Future<void> Function(JournalEntry updatedEntry)? onSave;

  /// Initial content to pre-fill when creating a new entry (e.g. from input bar).
  final String? initialContent;

  const EntryDetailScreen({
    super.key,
    this.entry,
    this.startInEditMode = false,
    this.allTags = const [],
    this.audioPlayer,
    this.onSave,
    this.initialContent,
  });

  @override
  ConsumerState<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends ConsumerState<EntryDetailScreen> {
  late bool _isEditing;
  late TextEditingController _titleController;
  late TextEditingController _contentController;
  late List<String> _tags;
  final FocusNode _contentFocusNode = FocusNode();

  // Original values for change detection
  late String _originalTitle;
  late String _originalContent;
  late List<String> _originalTags;

  bool get _isNewEntry => widget.entry == null;

  bool get _hasChanges {
    return _titleController.text != _originalTitle ||
        _contentController.text != _originalContent ||
        !listEquals(_tags, _originalTags);
  }

  @override
  void initState() {
    super.initState();
    _isEditing = widget.startInEditMode || _isNewEntry;

    // Parse title from content if it starts with a markdown heading
    String initialTitle;
    String initialContent;
    if (widget.entry != null) {
      final entry = widget.entry!;
      final headingMatch = RegExp(r'^# (.+)\n\n').firstMatch(entry.content);
      if (headingMatch != null && entry.type == JournalEntryType.text) {
        initialTitle = headingMatch.group(1) ?? '';
        initialContent = entry.content.substring(headingMatch.end);
      } else {
        initialTitle = entry.title;
        initialContent = entry.content;
      }
    } else {
      initialTitle = '';
      initialContent = widget.initialContent ?? '';
    }

    _titleController = TextEditingController(text: initialTitle);
    _contentController = TextEditingController(text: initialContent);
    _tags = List<String>.from(widget.entry?.tags ?? []);

    _originalTitle = initialTitle;
    _originalContent = initialContent;
    _originalTags = List<String>.from(_tags);

    if (_isEditing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _contentFocusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    _contentFocusNode.dispose();
    super.dispose();
  }

  void _enterEditMode() {
    setState(() {
      _isEditing = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _contentFocusNode.requestFocus();
    });
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();

    if (content.isEmpty && title.isEmpty) return;

    if (_isNewEntry) {
      // New entry — pop with result (same pattern as old ComposeScreen)
      Navigator.of(context).pop(ComposeResult(title: title, content: content));
      return;
    }

    // Existing entry — reconstruct full content with title heading for text entries
    final entry = widget.entry!;
    String fullContent;
    if (entry.type == JournalEntryType.text && title.isNotEmpty) {
      fullContent = '# $title\n\n$content';
    } else {
      fullContent = content;
    }

    final updatedEntry = entry.copyWith(
      content: fullContent,
      title: title,
      tags: _tags.isNotEmpty ? _tags : null,
    );

    if (widget.onSave != null) {
      try {
        await widget.onSave!(updatedEntry);
        if (mounted) {
          // Capture messenger before pop — context's Scaffold is torn down after pop
          final messenger = ScaffoldMessenger.of(context);
          Navigator.of(context).pop();
          messenger.showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Text('Saved'),
                ],
              ),
              backgroundColor: BrandColors.forest,
              duration: const Duration(seconds: 1),
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        }
      } catch (e) {
        debugPrint('[EntryDetailScreen] Error saving: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to save: $e'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    }
  }

  Future<bool> _onWillPop() async {
    if (!_isEditing) return true;
    if (!_hasChanges) return true;

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

  @override
  Widget build(BuildContext context) {
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
        appBar: _buildAppBar(theme, isDark),
        body: _isEditing
            ? _buildEditMode(theme, isDark)
            : _buildReadMode(theme, isDark),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(ThemeData theme, bool isDark) {
    return AppBar(
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
        if (_isEditing)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _save,
              child: Text(
                _isNewEntry ? 'Save' : 'Update',
                style: TextStyle(
                  color: BrandColors.forest,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
          )
        else if (widget.entry != null &&
            widget.entry!.id != 'preamble' &&
            !widget.entry!.id.startsWith('plain_'))
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: _enterEditMode,
              icon: Icon(Icons.edit, size: 18, color: BrandColors.forest),
              label: Text(
                'Edit',
                style: TextStyle(
                  color: BrandColors.forest,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ── Read Mode ──────────────────────────────────────────────────────────

  Widget _buildReadMode(ThemeData theme, bool isDark) {
    final entry = widget.entry!;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Entry type header
          _buildEntryHeader(theme, isDark, entry),
          const SizedBox(height: 16),

          // Audio player for voice entries
          if (widget.audioPlayer != null) ...[
            widget.audioPlayer!,
            const SizedBox(height: 16),
          ],

          // Title
          if (entry.title.isNotEmpty) ...[
            Text(
              entry.title,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: isDark ? BrandColors.softWhite : BrandColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Content (rendered markdown)
          _buildRenderedContent(theme, isDark, entry),

          // Tags (read-only chips)
          if (_tags.isNotEmpty) ...[
            const SizedBox(height: 24),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _tags.map((tag) => Chip(
                label: Text(
                  tag,
                  style: TextStyle(
                    fontSize: 13,
                    color: isDark ? BrandColors.stone : BrandColors.charcoal,
                  ),
                ),
                backgroundColor: isDark
                    ? BrandColors.charcoal.withValues(alpha: 0.5)
                    : BrandColors.stone.withValues(alpha: 0.3),
                side: BorderSide.none,
                visualDensity: VisualDensity.compact,
              )).toList(),
            ),
          ],

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildEntryHeader(ThemeData theme, bool isDark, JournalEntry entry) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _getEntryColor(entry.type).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            _getEntryIcon(entry.type),
            color: _getEntryColor(entry.type),
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          _getEntryTypeLabel(entry.type),
          style: theme.textTheme.bodySmall?.copyWith(
            color: BrandColors.driftwood,
          ),
        ),
        if (entry.durationSeconds != null && entry.durationSeconds! > 0) ...[
          const SizedBox(width: 8),
          Text(
            '·',
            style: TextStyle(color: BrandColors.driftwood),
          ),
          const SizedBox(width: 8),
          Text(
            _formatDuration(entry.durationSeconds!),
            style: theme.textTheme.bodySmall?.copyWith(
              color: BrandColors.driftwood,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRenderedContent(
      ThemeData theme, bool isDark, JournalEntry entry) {
    // For text entries, strip the title heading from content before rendering
    String displayContent = entry.content;
    if (entry.type == JournalEntryType.text) {
      final headingMatch = RegExp(r'^# .+\n\n').firstMatch(entry.content);
      if (headingMatch != null) {
        displayContent = entry.content.substring(headingMatch.end);
      }
    }

    if (displayContent.isEmpty) {
      return Text(
        'No content',
        style: TextStyle(
          color: BrandColors.driftwood,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    return MarkdownBody(
      data: displayContent,
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
          color: isDark ? BrandColors.turquoise : BrandColors.turquoiseDeep,
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
    );
  }

  // ── Edit Mode ──────────────────────────────────────────────────────────

  Widget _buildEditMode(ThemeData theme, bool isDark) {
    return Column(
      children: [
        // Audio player for voice entries (stays visible in edit mode)
        if (widget.audioPlayer != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: widget.audioPlayer!,
          ),
        ],

        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title field
                TextField(
                  controller: _titleController,
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
                const Divider(height: 1),

                // Content field
                TextField(
                  controller: _contentController,
                  focusNode: _contentFocusNode,
                  maxLines: null,
                  minLines: 12,
                  textAlignVertical: TextAlignVertical.top,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.newline,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: isDark ? BrandColors.stone : BrandColors.charcoal,
                    height: 1.6,
                  ),
                  decoration: InputDecoration(
                    hintText: _isNewEntry
                        ? 'Start writing...'
                        : 'Write your thoughts...',
                    hintStyle: TextStyle(color: BrandColors.driftwood),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),

                // Tags section
                const SizedBox(height: 24),
                Text(
                  'Tags',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: BrandColors.driftwood,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                TagInput(
                  tags: _tags,
                  onChanged: (updated) {
                    setState(() {
                      _tags = updated;
                    });
                  },
                  suggestions: widget.allTags,
                  hintText: 'Add a tag (e.g., "recipe", "work")...',
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  IconData _getEntryIcon(JournalEntryType type) {
    switch (type) {
      case JournalEntryType.text:
        return Icons.edit_note;
      case JournalEntryType.voice:
        return Icons.mic;
      case JournalEntryType.photo:
        return Icons.photo_camera;
      case JournalEntryType.handwriting:
        return Icons.draw;
      case JournalEntryType.linked:
        return Icons.link;
    }
  }

  Color _getEntryColor(JournalEntryType type) {
    switch (type) {
      case JournalEntryType.text:
        return BrandColors.forest;
      case JournalEntryType.voice:
        return BrandColors.turquoise;
      case JournalEntryType.photo:
        return BrandColors.warning;
      case JournalEntryType.handwriting:
        return BrandColors.info;
      case JournalEntryType.linked:
        return BrandColors.driftwood;
    }
  }

  String _getEntryTypeLabel(JournalEntryType type) {
    switch (type) {
      case JournalEntryType.text:
        return 'Text entry';
      case JournalEntryType.voice:
        return 'Voice note';
      case JournalEntryType.photo:
        return 'Photo';
      case JournalEntryType.handwriting:
        return 'Handwriting';
      case JournalEntryType.linked:
        return 'Linked file';
    }
  }

  String _formatDuration(int seconds) {
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    if (minutes > 0) {
      return '$minutes min${secs > 0 ? ' $secs sec' : ''}';
    }
    return '$secs sec';
  }
}
