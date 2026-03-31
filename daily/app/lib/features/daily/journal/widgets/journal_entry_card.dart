import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import '../../recorder/providers/transcription_init_provider.dart';
import '../models/journal_entry.dart';
import '../providers/journal_screen_state_provider.dart';

/// Card widget displaying a single journal entry
///
/// Shows the entry title, content preview, and type indicator.
/// The para ID is hidden from the user.
///
/// Special handling for "preamble" and "plain_*" entries which are
/// markdown content imported from Obsidian without para:IDs.
class JournalEntryCard extends ConsumerWidget {
  final JournalEntry entry;
  final String? audioPath;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onTranscribe;
  final VoidCallback? onEnhance;

  const JournalEntryCard({
    super.key,
    required this.entry,
    this.audioPath,
    this.onTap,
    this.onEdit,
    this.onDelete,
    this.onTranscribe,
    this.onEnhance,
  });

  /// Check if this is imported markdown content (no para:ID)
  bool get _isImportedMarkdown =>
      entry.id == 'preamble' || entry.id.startsWith('plain_');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final transcriptionState = ref.watch(transcriptionInitProvider);
    final screenState = ref.watch(journalScreenStateProvider);
    final isActivelyTranscribing = screenState.transcribingEntryIds.contains(entry.id);
    final transcriptionProgress = screenState.transcriptionProgress[entry.id] ?? 0.0;
    final canTranscribe = transcriptionState.isReady && entry.isPendingTranscription && !isActivelyTranscribing && onTranscribe != null;

    // Use different layout for imported markdown vs para:ID entries
    if (_isImportedMarkdown) {
      return _buildMarkdownCard(context, theme, isDark);
    }

    return Card(
      elevation: 0,
      color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isDark ? BrandColors.charcoal : BrandColors.stone,
          width: 0.5,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: title + type icon + menu
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Type indicator
                  _buildTypeIcon(isDark),
                  const SizedBox(width: 12),

                  // Title
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title.isNotEmpty ? entry.title : 'Untitled',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: isDark ? BrandColors.softWhite : BrandColors.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (entry.durationSeconds != null && entry.durationSeconds! > 0)
                          Text(
                            _formatDuration(entry.durationSeconds!),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: BrandColors.driftwood,
                            ),
                          ),
                      ],
                    ),
                  ),

                  // Menu button
                  _buildMenuButton(),
                ],
              ),

              // Active transcription progress (local transcription in progress)
              if (isActivelyTranscribing) ...[
                const SizedBox(height: 12),
                _buildTranscribingIndicator(isDark, transcriptionProgress),
              ]
              // Server processing (no text yet — transcription in progress on server)
              else if (entry.isServerProcessing && entry.content.isEmpty) ...[
                const SizedBox(height: 12),
                _buildServerStatusIndicator(isDark,
                  icon: null,
                  label: 'Transcribing on server...',
                  color: BrandColors.turquoise,
                  showSpinner: true,
                ),
              ]
              // Server transcription failed
              else if (entry.isTranscriptionFailed) ...[
                const SizedBox(height: 12),
                _buildServerStatusIndicator(isDark,
                  icon: Icons.error_outline,
                  label: 'Transcription failed',
                  color: BrandColors.error,
                ),
              ]
              // Content preview (with cleanup status indicator)
              else if (entry.content.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _truncateContent(entry.content),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isDark ? BrandColors.stone : BrandColors.charcoal,
                    height: 1.5,
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                if (entry.isCleanupInProgress) ...[
                  const SizedBox(height: 8),
                  _buildCleanupIndicator(isDark),
                ] else if (entry.isCleanedUp) ...[
                  const SizedBox(height: 8),
                  _buildCleanupStatusChip(isDark, enhanced: true),
                ] else if (entry.needsCleanup && entry.content.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildCleanupStatusChip(isDark, enhanced: false),
                ],
              ],

              // Linked file indicator
              if (entry.isLinked && entry.linkedFilePath != null) ...[
                const SizedBox(height: 12),
                _buildLinkedFileChip(context, isDark),
              ],

              // Audio indicator
              if (entry.hasAudio && audioPath != null) ...[
                const SizedBox(height: 12),
                _buildAudioChip(context, isDark),
              ],

              // Image thumbnail for photo/handwriting entries
              if (entry.hasImage) ...[
                const SizedBox(height: 12),
                _buildImageThumbnail(context, ref, isDark),
              ],

              // Transcribe button for pending transcription entries
              // Don't show when server is actively processing or cleanup is running
              if (entry.isPendingTranscription && !entry.isServerProcessing) ...[
                const SizedBox(height: 12),
                _buildTranscribeButton(context, isDark, canTranscribe),
              ]
              // Smart action: Re-transcribe (has audio) or Clean up (text only)
              else if (entry.needsCleanup && entry.content.isNotEmpty && !entry.isServerProcessing) ...[
                const SizedBox(height: 8),
                if (entry.hasAudio && onTranscribe != null)
                  _buildActionChip(
                    isDark,
                    icon: Icons.replay,
                    label: 'Re-transcribe',
                    color: BrandColors.forest,
                    onTap: onTranscribe!,
                  )
                else if (onEnhance != null)
                  _buildActionChip(
                    isDark,
                    icon: Icons.auto_fix_high,
                    label: 'Clean up',
                    color: BrandColors.turquoise,
                    onTap: onEnhance!,
                  ),
              ],

              // Sync status indicators
              if (entry.isPending || entry.hasPendingEdit) ...[
                const SizedBox(height: 8),
                if (entry.isPending) _buildSyncChip(isDark, isPendingUpload: true),
                if (entry.hasPendingEdit) _buildSyncChip(isDark, isPendingUpload: false),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSyncChip(bool isDark, {required bool isPendingUpload}) {
    final icon = isPendingUpload ? Icons.cloud_upload_outlined : Icons.edit_outlined;
    final label = isPendingUpload ? 'Not uploaded yet' : 'Edit not synced';
    final color = isPendingUpload ? BrandColors.warning : BrandColors.driftwood;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.15 : 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// Build card for imported markdown content (preamble/plain entries)
  Widget _buildMarkdownCard(BuildContext context, ThemeData theme, bool isDark) {
    // For preamble (content before any H1), show as markdown block
    // For plain_* entries (H1 without para:ID), show title + markdown content
    final hasTitle = entry.title.isNotEmpty && entry.id != 'preamble';

    return Card(
      elevation: 0,
      color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isDark
              ? BrandColors.charcoal.withValues(alpha: 0.5)
              : BrandColors.stone.withValues(alpha: 0.5),
          width: 0.5,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header with markdown icon and optional title
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Markdown icon
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: BrandColors.driftwood.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.article_outlined,
                      size: 18,
                      color: BrandColors.driftwood,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hasTitle ? entry.title : 'Note',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: isDark ? BrandColors.softWhite : BrandColors.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'Pre-Parachute',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: BrandColors.driftwood,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _buildMenuButton(),
                ],
              ),

              // Rendered markdown content
              if (entry.content.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: MarkdownBody(
                      data: entry.content,
                      shrinkWrap: true,
                      softLineBreak: true,
                      styleSheet: MarkdownStyleSheet(
                        p: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.stone : BrandColors.charcoal,
                          height: 1.5,
                        ),
                        h1: theme.textTheme.titleMedium?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.bold,
                        ),
                        h2: theme.textTheme.titleSmall?.copyWith(
                          color: isDark ? BrandColors.softWhite : BrandColors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        listBullet: theme.textTheme.bodyMedium?.copyWith(
                          color: isDark ? BrandColors.stone : BrandColors.charcoal,
                        ),
                        code: TextStyle(
                          fontFamily: 'monospace',
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
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuButton() {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_vert,
        color: BrandColors.driftwood,
        size: 20,
      ),
      onSelected: (value) {
        switch (value) {
          case 'edit':
            onEdit?.call();
            break;
          case 'delete':
            onDelete?.call();
            break;
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 18),
              SizedBox(width: 8),
              Text('Edit'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: BrandColors.error),
              const SizedBox(width: 8),
              Text('Delete', style: TextStyle(color: BrandColors.error)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTypeIcon(bool isDark) {
    IconData icon;
    Color color;

    switch (entry.type) {
      case JournalEntryType.voice:
        icon = Icons.mic;
        color = BrandColors.turquoise;
      case JournalEntryType.linked:
        icon = Icons.link;
        color = BrandColors.forest;
      case JournalEntryType.text:
        icon = Icons.edit_note;
        color = BrandColors.driftwood;
      case JournalEntryType.photo:
        icon = Icons.photo_camera;
        color = BrandColors.forest;
      case JournalEntryType.handwriting:
        icon = Icons.draw;
        color = BrandColors.turquoise;
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        icon,
        size: 18,
        color: color,
      ),
    );
  }

  Widget _buildLinkedFileChip(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: BrandColors.forestMist.withValues(alpha: isDark ? 0.2 : 1.0),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.description_outlined,
            size: 14,
            color: BrandColors.forest,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              entry.linkedFilePath!.split('/').last,
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

  Widget _buildAudioChip(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: BrandColors.turquoiseMist.withValues(alpha: isDark ? 0.2 : 1.0),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.play_circle_outline,
            size: 14,
            color: BrandColors.turquoise,
          ),
          const SizedBox(width: 6),
          Text(
            'Play audio',
            style: TextStyle(
              fontSize: 12,
              color: BrandColors.turquoise,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageThumbnail(BuildContext context, WidgetRef ref, bool isDark) {
    if (entry.imagePath == null) return const SizedBox.shrink();

    return FutureBuilder<String>(
      future: _getFullImagePath(ref),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Container(
            height: 120,
            decoration: BoxDecoration(
              color: isDark ? BrandColors.charcoal : BrandColors.stone,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        final fullPath = snapshot.data!;
        final file = File(fullPath);

        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: file.existsSync()
              ? Image.file(
                  file,
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      height: 120,
                      decoration: BoxDecoration(
                        color: isDark ? BrandColors.charcoal : BrandColors.stone,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.broken_image_outlined,
                              color: BrandColors.driftwood,
                              size: 24,
                            ),
                            const SizedBox(height: 4),
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
                )
              : Container(
                  height: 120,
                  decoration: BoxDecoration(
                    color: isDark ? BrandColors.charcoal : BrandColors.stone,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.image_not_supported_outlined,
                          color: BrandColors.driftwood,
                          size: 24,
                        ),
                        const SizedBox(height: 4),
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
      },
    );
  }

  Future<String> _getFullImagePath(WidgetRef ref) async {
    final fileSystemService = ref.read(fileSystemServiceProvider);
    final vaultPath = await fileSystemService.getRootPath();
    return '$vaultPath/${entry.imagePath}';
  }

  /// Progress indicator shown while transcription is actively running
  Widget _buildTranscribingIndicator(bool isDark, double progress) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: BrandColors.turquoise.withValues(alpha: isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress > 0 ? progress : null,
                  valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                  backgroundColor: BrandColors.turquoise.withValues(alpha: 0.2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                progress > 0
                    ? 'Transcribing... ${(progress * 100).toInt()}%'
                    : 'Transcribing...',
                style: TextStyle(
                  fontSize: 13,
                  color: BrandColors.turquoise,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (progress > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: BrandColors.turquoise.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(BrandColors.turquoise),
                minHeight: 3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Status indicator chip for server transcription states (processing, failed).
  Widget _buildServerStatusIndicator(bool isDark, {
    required IconData? icon,
    required String label,
    required Color color,
    bool showSpinner = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.15 : 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (showSpinner)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(color),
                backgroundColor: color.withValues(alpha: 0.2),
              ),
            )
          else if (icon != null)
            Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// Raw text available, LLM cleanup still running
  Widget _buildCleanupIndicator(bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            valueColor: AlwaysStoppedAnimation<Color>(BrandColors.driftwood),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'Cleaning up...',
          style: TextStyle(
            fontSize: 11,
            color: BrandColors.driftwood,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Widget _buildCleanupStatusChip(bool isDark, {required bool enhanced}) {
    final color = enhanced ? BrandColors.forest : BrandColors.driftwood;
    final icon = enhanced ? Icons.auto_awesome : Icons.notes;
    final label = enhanced ? 'Enhanced' : 'Raw';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.15 : 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionChip(
    bool isDark, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: isDark ? 0.2 : 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscribeButton(BuildContext context, bool isDark, bool canTranscribe) {
    if (canTranscribe) {
      // Parakeet ready - show actionable transcribe button
      return InkWell(
        onTap: onTranscribe,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: BrandColors.forest.withValues(alpha: isDark ? 0.2 : 0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: BrandColors.forest.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.record_voice_over,
                size: 14,
                color: BrandColors.forest,
              ),
              const SizedBox(width: 6),
              Text(
                'Transcribe',
                style: TextStyle(
                  fontSize: 12,
                  color: BrandColors.forest,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      // Parakeet not ready - show status message
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: BrandColors.warning.withValues(alpha: isDark ? 0.15 : 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hourglass_empty,
              size: 14,
              color: BrandColors.warning,
            ),
            const SizedBox(width: 6),
            Text(
              'Awaiting transcription',
              style: TextStyle(
                fontSize: 12,
                color: BrandColors.warning,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }
  }

  String _truncateContent(String content) {
    // Remove excessive whitespace
    final cleaned = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned;
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
