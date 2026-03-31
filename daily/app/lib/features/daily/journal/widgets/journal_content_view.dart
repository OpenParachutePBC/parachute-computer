import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/journal_day.dart';
import '../models/journal_entry.dart';
import '../providers/journal_providers.dart';
import '../providers/journal_screen_state_provider.dart';
import 'journal_entry_row.dart';

/// Main content view showing journal entries, agent outputs, and chat log
class JournalContentView extends ConsumerWidget {
  final JournalDay journal;
  final DateTime selectedDate;
  final bool isToday;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final Function(JournalEntry) onEntryTap;
  final Function(BuildContext, JournalDay, JournalEntry) onShowEntryActions;
  final Function(String, {String? entryTitle}) onPlayAudio;
  final Function(JournalEntry, JournalDay) onTranscribe;
  final Function(JournalEntry) onEnhance;

  const JournalContentView({
    super.key,
    required this.journal,
    required this.selectedDate,
    required this.isToday,
    required this.scrollController,
    required this.onRefresh,
    required this.onEntryTap,
    required this.onShowEntryActions,
    required this.onPlayAudio,
    required this.onTranscribe,
    required this.onEnhance,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return RefreshIndicator(
      onRefresh: onRefresh,
      color: BrandColors.forest,
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
                  return _buildJournalEntry(context, ref, entry, index, isDark);
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

  String _dateStr(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  Widget _buildJournalEntry(
    BuildContext context,
    WidgetRef ref,
    JournalEntry entry,
    int index,
    bool isDark,
  ) {
    final screenState = ref.watch(journalScreenStateProvider);

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
        ),
      ],
    );
  }
}
