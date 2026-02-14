import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/journal_day.dart';
import '../models/journal_entry.dart';
import '../providers/journal_screen_state_provider.dart';
import 'journal_entry_row.dart';

/// List view of journal entries with dividers
class JournalEntryList extends ConsumerWidget {
  final JournalDay journal;
  final String? editingEntryId;
  final EntrySaveState currentSaveState;
  final ScrollController scrollController;
  final VoidCallback onSaveCurrentEdit;
  final Function(JournalEntry) onEntryTap;
  final Function(BuildContext, JournalDay, JournalEntry) onShowEntryActions;
  final Function(String, {String? entryTitle}) onPlayAudio;
  final Function(JournalEntry, JournalDay) onTranscribe;
  final Function(JournalEntry) onEnhance;
  final Function(String, String) onContentChanged;
  final Function(String, String) onTitleChanged;

  const JournalEntryList({
    super.key,
    required this.journal,
    required this.editingEntryId,
    required this.currentSaveState,
    required this.scrollController,
    required this.onSaveCurrentEdit,
    required this.onEntryTap,
    required this.onShowEntryActions,
    required this.onPlayAudio,
    required this.onTranscribe,
    required this.onEnhance,
    required this.onContentChanged,
    required this.onTitleChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenState = ref.watch(journalScreenStateProvider);

    return GestureDetector(
      // Tap empty space to save and deselect editing
      onTap: () {
        if (editingEntryId != null) {
          onSaveCurrentEdit();
        }
      },
      child: CustomScrollView(
        controller: scrollController,
        cacheExtent: 500, // Cache more entries for smoother scrolling
        slivers: [
          // Journal entries
          SliverPadding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final entry = journal.entries[index];
                  final isEditing = editingEntryId == entry.id;

                  return Column(
                    children: [
                      // Subtle divider between entries (except first)
                      if (index > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Divider(
                            height: 1,
                            thickness: 0.5,
                            color: isDark
                                ? BrandColors.charcoal.withValues(alpha: 0.3)
                                : BrandColors.stone.withValues(alpha: 0.3),
                          ),
                        ),

                      JournalEntryRow(
                        key: ValueKey(entry.id),
                        entry: entry,
                        audioPath: journal.getAudioPath(entry.id),
                        isEditing: isEditing,
                        saveState: isEditing ? currentSaveState : EntrySaveState.saved,
                        // Show transcribing for both manual transcribe and background transcription
                        isTranscribing: screenState.transcribingEntryIds.contains(entry.id) ||
                            screenState.pendingTranscriptionEntryId == entry.id,
                        transcriptionProgress: screenState.transcriptionProgress[entry.id] ?? 0.0,
                        isEnhancing: screenState.enhancingEntryIds.contains(entry.id),
                        enhancementProgress: screenState.enhancementProgress[entry.id],
                        enhancementStatus: screenState.enhancementStatus[entry.id],
                        onTap: () => onEntryTap(entry),
                        onLongPress: () => onShowEntryActions(context, journal, entry),
                        onPlayAudio: (path) => onPlayAudio(path, entryTitle: entry.title),
                        onTranscribe: () => onTranscribe(entry, journal),
                        onEnhance: () => onEnhance(entry),
                        onContentChanged: (content) => onContentChanged(entry.id, content),
                        onTitleChanged: (title) => onTitleChanged(entry.id, title),
                        onEditingComplete: onSaveCurrentEdit,
                      ),
                    ],
                  );
                },
                childCount: journal.entries.length,
              ),
            ),
          ),

          // Bottom padding
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }
}
