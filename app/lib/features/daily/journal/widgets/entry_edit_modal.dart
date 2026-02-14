import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/journal_entry.dart';
import 'journal_entry_row.dart' show EntrySaveState;

/// Modal sheet for viewing and editing journal entries
///
/// This modal provides a comfortable editing space for journal entries,
/// with auto-save functionality and visible save state feedback.
class EntryEditModal extends StatefulWidget {
  final JournalEntry entry;
  final String? audioPath;
  final bool canEdit;
  final Future<void> Function(JournalEntry updatedEntry)? onSave;
  final Future<void> Function(String audioPath)? onPlayAudio;
  final Widget? audioPlayer;

  const EntryEditModal({
    super.key,
    required this.entry,
    this.audioPath,
    this.canEdit = true,
    this.onSave,
    this.onPlayAudio,
    this.audioPlayer,
  });

  @override
  State<EntryEditModal> createState() => _EntryEditModalState();
}

class _EntryEditModalState extends State<EntryEditModal>
    with WidgetsBindingObserver {
  late TextEditingController _contentController;
  late TextEditingController _titleController;
  final FocusNode _contentFocusNode = FocusNode();

  // Save state tracking
  Timer? _draftSaveTimer;
  EntrySaveState _saveState = EntrySaveState.saved;
  bool _hasChanges = false;
  static const _draftKeyPrefix = 'journal_draft_';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _contentController = TextEditingController(text: widget.entry.content);
    _titleController = TextEditingController(text: widget.entry.title);

    _contentController.addListener(_onContentChanged);
    _titleController.addListener(_onContentChanged);

    // Load any existing draft
    _loadDraft();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Flush any pending save before disposing
    _flushPendingSave();
    _draftSaveTimer?.cancel();
    _contentController.dispose();
    _titleController.dispose();
    _contentFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _flushPendingSave();
    }
  }

  void _onContentChanged() {
    if (!widget.canEdit) return;

    final hasContentChanges =
        _contentController.text != widget.entry.content ||
            _titleController.text != widget.entry.title;

    if (hasContentChanges != _hasChanges) {
      setState(() {
        _hasChanges = hasContentChanges;
      });
    }

    if (hasContentChanges) {
      _saveDraftDebounced();
    }
  }

  void _saveDraftDebounced() {
    _draftSaveTimer?.cancel();
    setState(() {
      _saveState = EntrySaveState.saving;
    });

    _draftSaveTimer = Timer(const Duration(milliseconds: 500), () {
      _saveDraft();
    });
  }

  Future<void> _saveDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_draftKeyPrefix${widget.entry.id}';
    final draftValue =
        '${_titleController.text}|||${_contentController.text}';
    await prefs.setString(key, draftValue);
    debugPrint('[EntryEditModal] Draft saved for entry ${widget.entry.id}');

    if (mounted) {
      setState(() {
        _saveState = EntrySaveState.draftSaved;
      });
    }
  }

  Future<void> _loadDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_draftKeyPrefix${widget.entry.id}';
    final draftValue = prefs.getString(key);

    if (draftValue == null) return;

    final parts = draftValue.split('|||');
    if (parts.length != 2) return;

    final draftTitle = parts[0];
    final draftContent = parts[1];

    // Only restore if different from current entry
    final hasDraftChanges = draftTitle != widget.entry.title ||
        draftContent != widget.entry.content;

    if (hasDraftChanges && mounted) {
      _titleController.text = draftTitle;
      _contentController.text = draftContent;
      setState(() {
        _hasChanges = true;
        _saveState = EntrySaveState.draftSaved;
      });

      // Show draft restored feedback
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.restore, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Text('Draft restored'),
            ],
          ),
          backgroundColor: BrandColors.forest,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    }
  }

  Future<void> _clearDraft() async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_draftKeyPrefix${widget.entry.id}';
    await prefs.remove(key);
  }

  void _flushPendingSave() {
    if (_hasChanges) {
      _draftSaveTimer?.cancel();
      // Fire and forget
      _saveDraft();
    }
  }

  Future<void> _saveAndClose() async {
    _draftSaveTimer?.cancel();

    if (!_hasChanges || widget.onSave == null) {
      Navigator.pop(context);
      return;
    }

    // Create updated entry
    final updatedEntry = widget.entry.copyWith(
      content: _contentController.text,
      title: _titleController.text,
    );

    try {
      await widget.onSave!(updatedEntry);
      await _clearDraft();

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                const Text('Saved'),
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
      debugPrint('[EntryEditModal] Error saving: $e');
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? BrandColors.charcoal : BrandColors.stone,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            _buildHeader(theme, isDark),

            const Divider(height: 1),

            // Audio player for voice entries
            if (widget.audioPlayer != null) widget.audioPlayer!,

            // Content
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title field (if editable)
                    if (widget.canEdit) ...[
                      TextField(
                        controller: _titleController,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Entry title...',
                          hintStyle: TextStyle(
                            color: BrandColors.driftwood,
                            fontWeight: FontWeight.normal,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Content field
                    if (widget.canEdit)
                      TextField(
                        controller: _contentController,
                        focusNode: _contentFocusNode,
                        maxLines: null,
                        minLines: 8,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: isDark ? BrandColors.stone : BrandColors.charcoal,
                          height: 1.6,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Write your thoughts...',
                          hintStyle: TextStyle(
                            color: BrandColors.driftwood,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      )
                    else
                      SelectableText(
                        widget.entry.content.isEmpty
                            ? 'No content'
                            : widget.entry.content,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: widget.entry.content.isEmpty
                              ? BrandColors.driftwood
                              : (isDark ? BrandColors.stone : BrandColors.charcoal),
                          height: 1.6,
                          fontStyle: widget.entry.content.isEmpty
                              ? FontStyle.italic
                              : FontStyle.normal,
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Bottom bar with save state and done button
            if (widget.canEdit) _buildBottomBar(theme, isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, bool isDark) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          // Type icon
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _getEntryColor(widget.entry.type).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              _getEntryIcon(widget.entry.type),
              color: _getEntryColor(widget.entry.type),
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!widget.canEdit)
                  Text(
                    widget.entry.title.isNotEmpty
                        ? widget.entry.title
                        : 'Untitled',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: isDark ? BrandColors.softWhite : BrandColors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else
                  Text(
                    _getEntryTypeLabel(widget.entry.type),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: BrandColors.driftwood,
                    ),
                  ),
                if (widget.entry.durationSeconds != null &&
                    widget.entry.durationSeconds! > 0)
                  Text(
                    _formatDuration(widget.entry.durationSeconds!),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: BrandColors.driftwood,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            color: BrandColors.driftwood,
            onPressed: () {
              if (_hasChanges) {
                _flushPendingSave();
              }
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(ThemeData theme, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : Colors.white,
        border: Border(
          top: BorderSide(
            color: isDark
                ? BrandColors.charcoal.withValues(alpha: 0.5)
                : BrandColors.stone.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Save state indicator
            _buildSaveStateIndicator(),
            const Spacer(),
            // Done button
            TextButton.icon(
              onPressed: _saveAndClose,
              icon: Icon(
                Icons.check,
                size: 18,
                color: BrandColors.forest,
              ),
              label: Text(
                'Done',
                style: TextStyle(
                  color: BrandColors.forest,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: TextButton.styleFrom(
                backgroundColor: BrandColors.forest.withValues(alpha: 0.1),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveStateIndicator() {
    final IconData icon;
    final String label;
    final Color color;

    switch (_saveState) {
      case EntrySaveState.saved:
        if (!_hasChanges) {
          icon = Icons.check_circle_outline;
          label = 'No changes';
          color = BrandColors.driftwood;
        } else {
          icon = Icons.check_circle_outline;
          label = 'Saved';
          color = BrandColors.forest;
        }
      case EntrySaveState.saving:
        icon = Icons.sync;
        label = 'Saving...';
        color = BrandColors.driftwood;
      case EntrySaveState.draftSaved:
        icon = Icons.save_outlined;
        label = 'Draft saved';
        color = BrandColors.turquoise;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_saveState == EntrySaveState.saving)
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: color,
            ),
          )
        else
          Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

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
        return BrandColors.warning; // warm color for photos
      case JournalEntryType.handwriting:
        return BrandColors.info; // blue for handwriting
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
      return '$minutes min ${secs > 0 ? '$secs sec' : ''}';
    }
    return '$secs sec';
  }
}
