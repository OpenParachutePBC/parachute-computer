import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import '../models/journal_entry.dart';

/// Save state for journal entry editing
enum EntrySaveState {
  /// No unsaved changes
  saved,
  /// Changes pending save (debounce timer running)
  saving,
  /// Draft saved to local storage
  draftSaved,
}

/// Minimal, markdown-native entry display
///
/// Displays entries as document sections rather than cards,
/// making the journal feel more like a native markdown editor.
class JournalEntryRow extends ConsumerStatefulWidget {
  final JournalEntry entry;
  final String? audioPath;
  final bool isEditing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Function(String)? onContentChanged;
  final Function(String)? onTitleChanged;
  final VoidCallback? onEditingComplete;
  final VoidCallback? onDelete;
  final Future<void> Function(String audioPath)? onPlayAudio;
  final Future<void> Function()? onTranscribe;
  final Future<void> Function()? onEnhance;
  final bool isTranscribing;
  final double transcriptionProgress; // 0.0-1.0, only relevant when isTranscribing
  final bool isEnhancing;
  final double? enhancementProgress; // 0.0-1.0, null for indeterminate
  final String? enhancementStatus; // Status message during enhancement
  final EntrySaveState saveState; // Current save state when editing

  const JournalEntryRow({
    super.key,
    required this.entry,
    this.audioPath,
    this.isEditing = false,
    this.onTap,
    this.onLongPress,
    this.onContentChanged,
    this.onTitleChanged,
    this.onEditingComplete,
    this.onDelete,
    this.onPlayAudio,
    this.onTranscribe,
    this.onEnhance,
    this.isTranscribing = false,
    this.transcriptionProgress = 0.0,
    this.isEnhancing = false,
    this.enhancementProgress,
    this.enhancementStatus,
    this.saveState = EntrySaveState.saved,
  });

  @override
  ConsumerState<JournalEntryRow> createState() => _JournalEntryRowState();
}

class _JournalEntryRowState extends ConsumerState<JournalEntryRow> {
  late TextEditingController _contentController;
  late TextEditingController _titleController;
  final FocusNode _contentFocusNode = FocusNode();
  final FocusNode _titleFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(text: widget.entry.content);
    _titleController = TextEditingController(text: widget.entry.title);
    if (widget.isEditing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _contentFocusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(JournalEntryRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entry.content != oldWidget.entry.content && !widget.isEditing) {
      _contentController.text = widget.entry.content;
    }
    if (widget.entry.title != oldWidget.entry.title && !widget.isEditing) {
      _titleController.text = widget.entry.title;
    }
    if (widget.isEditing && !oldWidget.isEditing) {
      _contentFocusNode.requestFocus();
    }
  }

  @override
  void dispose() {
    _contentController.dispose();
    _titleController.dispose();
    _contentFocusNode.dispose();
    _titleFocusNode.dispose();
    super.dispose();
  }

  /// Check if this is imported markdown content (no para:ID)
  bool get _isImportedMarkdown =>
      widget.entry.id == 'preamble' || widget.entry.id.startsWith('plain_');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final entry = widget.entry;

    // Preamble entries have no header
    final showHeader = entry.id != 'preamble';

    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        margin: widget.isEditing
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
            : EdgeInsets.zero,
        decoration: widget.isEditing
            ? BoxDecoration(
                color: isDark
                    ? BrandColors.forestDeep.withValues(alpha: 0.2)
                    : BrandColors.forestMist.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: BrandColors.forest.withValues(alpha: 0.3),
                  width: 1.5,
                ),
              )
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row (timestamp/title + indicators)
            if (showHeader) _buildHeader(context, theme, isDark),

            // Content
            if (entry.content.isNotEmpty || widget.isEditing)
              _buildContent(context, theme, isDark),

            // Audio indicator
            if (entry.hasAudio && widget.audioPath != null)
              _buildAudioIndicator(context, isDark),

            // Linked file indicator
            if (entry.isLinked && entry.linkedFilePath != null)
              _buildLinkedIndicator(context, isDark),

            // Image thumbnail for photo/handwriting entries
            if (entry.hasImage)
              _buildImageThumbnail(context, isDark),

            // Done button when editing
            if (widget.isEditing) _buildEditActions(context, isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildEditActions(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          // Save state indicator
          _buildSaveStateIndicator(isDark),
          const Spacer(),
          TextButton.icon(
            onPressed: widget.onEditingComplete,
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
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSaveStateIndicator(bool isDark) {
    final IconData icon;
    final String label;
    final Color color;

    switch (widget.saveState) {
      case EntrySaveState.saved:
        icon = Icons.check_circle_outline;
        label = 'Saved';
        color = BrandColors.forest;
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
        if (widget.saveState == EntrySaveState.saving)
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
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, ThemeData theme, bool isDark) {
    final entry = widget.entry;
    final title = entry.title.isNotEmpty ? entry.title : 'Untitled';

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Type indicator (subtle)
          if (!_isImportedMarkdown) ...[
            _buildTypeIndicator(isDark),
            const SizedBox(width: 8),
          ],

          // Title/timestamp - editable when in edit mode
          Expanded(
            child: widget.isEditing && !_isImportedMarkdown
                ? TextField(
                    controller: _titleController,
                    focusNode: _titleFocusNode,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: isDark ? BrandColors.softWhite : BrandColors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                      hintText: 'Title',
                      hintStyle: TextStyle(
                        color: BrandColors.driftwood.withValues(alpha: 0.5),
                      ),
                    ),
                    onChanged: widget.onTitleChanged,
                  )
                : Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: isDark ? BrandColors.softWhite : BrandColors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),

          // Duration badge for voice entries
          if (entry.type == JournalEntryType.voice &&
              entry.durationSeconds != null &&
              entry.durationSeconds! > 0)
            _buildDurationBadge(isDark),

          // Copy button - show for entries with content
          if (widget.entry.content.isNotEmpty && !widget.isEditing) ...[
            const SizedBox(width: 8),
            _buildCopyButton(context, isDark),
          ],

          // AI enhance button - show for entries with content
          if (_canEnhance) ...[
            const SizedBox(width: 8),
            _buildEnhanceButton(isDark),
          ],

          // Pre-Parachute badge for imported content
          if (_isImportedMarkdown) _buildImportedBadge(isDark),
        ],
      ),
    );
  }

  /// Check if this entry can be enhanced with AI
  /// Only voice entries benefit from cleanup (typed text is already clean)
  bool get _canEnhance =>
      widget.entry.type == JournalEntryType.voice &&
      !_isImportedMarkdown &&
      !widget.entry.isPendingTranscription &&
      widget.entry.content.isNotEmpty &&
      widget.onEnhance != null;

  Widget _buildCopyButton(BuildContext context, bool isDark) {
    return Tooltip(
      message: 'Copy text',
      child: InkWell(
        onTap: () => _copyToClipboard(context),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 28,
          height: 28,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: BrandColors.forest.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            Icons.copy_outlined,
            size: 16,
            color: BrandColors.forest,
          ),
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context) {
    if (widget.entry.content.isEmpty) return;

    Clipboard.setData(ClipboardData(text: widget.entry.content));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            const Text('Copied to clipboard'),
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

  Widget _buildEnhanceButton(bool isDark) {
    if (widget.isEnhancing) {
      final hasProgress = widget.enhancementProgress != null;
      final progressPercent = hasProgress ? (widget.enhancementProgress! * 100).toInt() : 0;

      return Tooltip(
        message: widget.enhancementStatus ?? 'Enhancing...',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: BrandColors.turquoise.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: hasProgress
                    ? CircularProgressIndicator(
                        strokeWidth: 2,
                        value: widget.enhancementProgress,
                        valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                        backgroundColor: BrandColors.turquoise.withValues(alpha: 0.2),
                      )
                    : CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                      ),
              ),
              if (hasProgress) ...[
                const SizedBox(width: 4),
                Text(
                  '$progressPercent%',
                  style: TextStyle(
                    fontSize: 10,
                    color: BrandColors.turquoise,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Tooltip(
      message: 'AI enhance: clean up text & generate title',
      child: InkWell(
        onTap: widget.onEnhance,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 28,
          height: 28,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: BrandColors.turquoise.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            Icons.auto_awesome,
            size: 16,
            color: BrandColors.turquoise,
          ),
        ),
      ),
    );
  }

  Widget _buildTypeIndicator(bool isDark) {
    IconData icon;
    Color color;

    switch (widget.entry.type) {
      case JournalEntryType.voice:
        icon = Icons.mic_none;
        color = BrandColors.turquoise;
      case JournalEntryType.linked:
        icon = Icons.link;
        color = BrandColors.forest;
      case JournalEntryType.text:
        icon = Icons.edit_note;
        color = isDark ? BrandColors.driftwood : BrandColors.stone;
      case JournalEntryType.photo:
        icon = Icons.photo_camera;
        color = BrandColors.forest;
      case JournalEntryType.handwriting:
        icon = Icons.draw;
        color = BrandColors.turquoise;
    }

    return Icon(icon, size: 16, color: color);
  }

  Widget _buildDurationBadge(bool isDark) {
    final seconds = widget.entry.durationSeconds!;
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    final text = minutes > 0 ? '${minutes}m${secs > 0 ? ' ${secs}s' : ''}' : '${secs}s';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: BrandColors.turquoise.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: BrandColors.turquoise,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildImportedBadge(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: BrandColors.driftwood.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Pre-Parachute',
        style: TextStyle(
          fontSize: 10,
          color: BrandColors.driftwood,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, ThemeData theme, bool isDark) {
    if (widget.isEditing) {
      return TextField(
        controller: _contentController,
        focusNode: _contentFocusNode,
        maxLines: null,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: isDark ? BrandColors.stone : BrandColors.charcoal,
          height: 1.6,
        ),
        decoration: InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          isDense: true,
          hintText: 'Write something...',
          hintStyle: TextStyle(
            color: BrandColors.driftwood.withValues(alpha: 0.5),
          ),
        ),
        onChanged: widget.onContentChanged,
        onEditingComplete: widget.onEditingComplete,
      );
    }

    // Show transcription progress (for both initial and re-transcription)
    if (widget.isTranscribing) {
      final isRetranscribing = widget.entry.content.isNotEmpty;
      final progressPercent = (widget.transcriptionProgress * 100).toInt();
      final progressText = progressPercent > 0
          ? (isRetranscribing ? 'Re-transcribing... $progressPercent%' : 'Transcribing... $progressPercent%')
          : (isRetranscribing ? 'Re-transcribing...' : 'Transcribing...');

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Show determinate progress when we have progress data
              SizedBox(
                width: 14,
                height: 14,
                child: widget.transcriptionProgress > 0
                    ? CircularProgressIndicator(
                        strokeWidth: 2,
                        value: widget.transcriptionProgress,
                        valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                        backgroundColor: BrandColors.turquoise.withValues(alpha: 0.2),
                      )
                    : CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                      ),
              ),
              const SizedBox(width: 8),
              Text(
                progressText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: BrandColors.turquoise,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
          // Show linear progress bar for visual feedback
          if (widget.transcriptionProgress > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: widget.transcriptionProgress,
                backgroundColor: BrandColors.turquoise.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                minHeight: 3,
              ),
            ),
          ],
          // Show existing content dimmed during re-transcription
          if (isRetranscribing) ...[
            const SizedBox(height: 8),
            Opacity(
              opacity: 0.5,
              child: Text(
                widget.entry.content,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isDark ? BrandColors.stone : BrandColors.charcoal,
                  height: 1.6,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      );
    }

    // Show pending transcription UI for voice entries with empty content
    if (widget.entry.isPendingTranscription) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Audio recorded but not transcribed',
            style: theme.textTheme.bodySmall?.copyWith(
              color: BrandColors.driftwood,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 8),
          if (widget.onTranscribe != null)
            OutlinedButton.icon(
              onPressed: widget.onTranscribe,
              icon: Icon(Icons.transcribe, size: 18, color: BrandColors.forest),
              label: Text(
                'Transcribe',
                style: TextStyle(color: BrandColors.forest),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: BrandColors.forest),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
        ],
      );
    }

    // Truncate long content in list view (show 4 lines max)
    const maxLines = 4;
    final contentStyle = theme.textTheme.bodyMedium?.copyWith(
      color: isDark ? BrandColors.stone : BrandColors.charcoal,
      height: 1.6,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Create a text painter to measure if we need truncation
        final textSpan = TextSpan(
          text: widget.entry.content,
          style: contentStyle,
        );
        final textPainter = TextPainter(
          text: textSpan,
          maxLines: maxLines,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: constraints.maxWidth);

        final isOverflowing = textPainter.didExceedMaxLines;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.entry.content,
              style: contentStyle,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
            if (isOverflowing)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Tap to read more',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: BrandColors.turquoise,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildAudioIndicator(BuildContext context, bool isDark) {
    final canPlay = widget.onPlayAudio != null && widget.audioPath != null;

    return GestureDetector(
      onTap: canPlay
          ? () => widget.onPlayAudio!(widget.audioPath!)
          : null,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.play_circle_outline,
              size: 16,
              color: canPlay ? BrandColors.turquoise : BrandColors.driftwood,
            ),
            const SizedBox(width: 4),
            Text(
              'Play audio',
              style: TextStyle(
                fontSize: 12,
                color: canPlay ? BrandColors.turquoise : BrandColors.driftwood,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLinkedIndicator(BuildContext context, bool isDark) {
    final filename = widget.entry.linkedFilePath!.split('/').last;

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.description_outlined,
            size: 16,
            color: BrandColors.forest,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              filename,
              style: TextStyle(
                fontSize: 12,
                color: BrandColors.forest,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageThumbnail(BuildContext context, bool isDark) {
    if (widget.entry.imagePath == null) return const SizedBox.shrink();

    return FutureBuilder<String>(
      future: _getFullImagePath(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              height: 80,
              decoration: BoxDecoration(
                color: isDark ? BrandColors.charcoal : BrandColors.stone,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          );
        }

        final file = File(snapshot.data!);

        if (!file.existsSync()) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              height: 80,
              decoration: BoxDecoration(
                color: isDark ? BrandColors.charcoal : BrandColors.stone,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.image_not_supported_outlined,
                      color: BrandColors.driftwood,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Image not found',
                      style: TextStyle(
                        fontSize: 12,
                        color: BrandColors.driftwood,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        // Use different display for handwriting vs photos
        final isHandwriting = widget.entry.type == JournalEntryType.handwriting;

        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: GestureDetector(
            onTap: () => _showFullScreenImage(context, file, isDark),
            child: Container(
              decoration: BoxDecoration(
                color: isHandwriting
                    ? (isDark ? BrandColors.nightSurfaceElevated : Colors.white)
                    : (isDark ? BrandColors.charcoal : BrandColors.stone),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark
                      ? BrandColors.charcoal.withValues(alpha: 0.5)
                      : BrandColors.stone.withValues(alpha: 0.5),
                  width: 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: isHandwriting ? 300 : 200,
                    minHeight: 80,
                  ),
                  child: Image.file(
                    file,
                    width: double.infinity,
                    fit: isHandwriting ? BoxFit.contain : BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return SizedBox(
                        height: 80,
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.broken_image_outlined,
                                color: BrandColors.driftwood,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Image not available',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: BrandColors.driftwood,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showFullScreenImage(BuildContext context, File file, bool isDark) {
    final isHandwriting = widget.entry.type == JournalEntryType.handwriting;

    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Image
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width - 32,
                  maxHeight: MediaQuery.of(context).size.height - 100,
                ),
                decoration: BoxDecoration(
                  color: isHandwriting
                      ? (isDark ? BrandColors.nightSurfaceElevated : Colors.white)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4.0,
                    child: Image.file(
                      file,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              // Close button
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _getFullImagePath() async {
    final fileSystemService = ref.read(fileSystemServiceProvider);
    final vaultPath = await fileSystemService.getRootPath();
    return '$vaultPath/${widget.entry.imagePath}';
  }
}
