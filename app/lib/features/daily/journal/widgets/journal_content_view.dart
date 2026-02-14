import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/journal_day.dart';
import '../models/journal_entry.dart';
import '../providers/journal_providers.dart';
import '../providers/journal_screen_state_provider.dart';
import 'journal_agent_outputs_section.dart';
import 'collapsible_chat_log_section.dart';
import 'journal_entry_row.dart';

/// Main content view showing journal entries, agent outputs, and chat log
class JournalContentView extends ConsumerWidget {
  final JournalDay journal;
  final DateTime selectedDate;
  final bool isToday;
  final String? editingEntryId;
  final EntrySaveState currentSaveState;
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final VoidCallback onSaveCurrentEdit;
  final Function(JournalEntry) onEntryTap;
  final Function(BuildContext, JournalDay, JournalEntry) onShowEntryActions;
  final Function(String, {String? entryTitle}) onPlayAudio;
  final Function(JournalEntry, JournalDay) onTranscribe;
  final Function(JournalEntry) onEnhance;
  final Function(String, String) onContentChanged;
  final Function(String, String) onTitleChanged;

  const JournalContentView({
    super.key,
    required this.journal,
    required this.selectedDate,
    required this.isToday,
    required this.editingEntryId,
    required this.currentSaveState,
    required this.scrollController,
    required this.onRefresh,
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

    // Watch agent outputs and chat log for the selected date
    final agentOutputsAsync = ref.watch(agentOutputsForDateProvider(selectedDate));
    final chatLogAsync = ref.watch(selectedChatLogProvider);

    // Check if we have any content at all
    final hasJournalEntries = journal.entries.isNotEmpty;
    final agentOutputs = agentOutputsAsync.valueOrNull ?? [];
    final hasAgentOutputs = agentOutputs.isNotEmpty;
    final hasChatLog = chatLogAsync.valueOrNull?.hasContent ?? false;

    return RefreshIndicator(
      onRefresh: onRefresh,
      color: BrandColors.forest,
      child: GestureDetector(
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
            // Agent Outputs (reflections, content ideas, etc.)
            // These are shown at the top, each in their own expandable header
            if (hasAgentOutputs)
              SliverToBoxAdapter(
                child: JournalAgentOutputsSection(
                  outputs: agentOutputs,
                  date: selectedDate,
                ),
              ),

            // AI Conversations (if available) - collapsible section at top
            if (hasChatLog)
              SliverToBoxAdapter(
                child: CollapsibleChatLogSection(
                  chatLog: chatLogAsync.value!,
                  initiallyExpanded: false,
                ),
              ),

            // Journal section header (if there are entries)
            if (hasJournalEntries && (hasAgentOutputs || hasChatLog))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.book_outlined,
                        size: 18,
                        color: BrandColors.forest,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Journal',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const Spacer(),
                      Text(
                        '${journal.entries.length} entr${journal.entries.length == 1 ? 'y' : 'ies'}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: BrandColors.driftwood,
                            ),
                      ),
                    ],
                  ),
                ),
              ),

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
      ),
    );
  }

  Widget _buildJournalEntry(
    BuildContext context,
    WidgetRef ref,
    JournalEntry entry,
    int index,
    bool isDark,
  ) {
    final isEditing = editingEntryId == entry.id;
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
  }
}
