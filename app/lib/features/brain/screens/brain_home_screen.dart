import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart'
    show currentTabIndexProvider, visibleTabsProvider, AppTab;
import 'package:parachute/features/chat/providers/chat_session_actions.dart'
    show switchSessionProvider;
import 'package:parachute/features/daily/journal/providers/journal_providers.dart'
    show selectedJournalDateProvider;
import '../providers/brain_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Value object — typed memory item
// ─────────────────────────────────────────────────────────────────────────────

enum MemoryKind { session, note }

@immutable
class MemoryItem {
  final MemoryKind kind;
  final String id;
  final String title;
  final String ts;
  final String module;
  final String? date; // non-null for notes only

  const MemoryItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.ts,
    required this.module,
    this.date,
  });

  factory MemoryItem.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] == 'note' ? MemoryKind.note : MemoryKind.session;
    final dateStr = json['date'] as String?;
    return MemoryItem(
      kind: kind,
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      ts: json['ts'] as String? ?? '',
      module: json['module'] as String? ?? 'chat',
      date: (dateStr != null && dateStr.isNotEmpty) ? dateStr : null,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

/// Brain — your extended mind.
///
/// A unified, chronological view of your conversations and journal entries.
/// Search, filter by type, tap to open in Chat or Daily.
class BrainHomeScreen extends ConsumerStatefulWidget {
  const BrainHomeScreen({super.key});

  @override
  ConsumerState<BrainHomeScreen> createState() => _BrainHomeScreenState();
}

class _BrainHomeScreenState extends ConsumerState<BrainHomeScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final filter = ref.watch(brainMemoryFilterProvider);
    final search = ref.watch(brainMemorySearchProvider);
    final memoryAsync = ref.watch(brainMemoryProvider((filter, search)));

    final bgColor = isDark ? BrandColors.nightSurface : BrandColors.cream;
    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;
    final subColor = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            // ── Search bar ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                controller: _searchController,
                onChanged: (val) =>
                    ref.read(brainMemorySearchProvider.notifier).state = val,
                style: TextStyle(fontSize: 14, color: textColor),
                decoration: InputDecoration(
                  hintText: 'Search your memory...',
                  hintStyle: TextStyle(fontSize: 14, color: subColor),
                  prefixIcon: Icon(Icons.search, size: 20, color: subColor),
                  suffixIcon: search.isNotEmpty
                      ? IconButton(
                          icon: Icon(Icons.clear, size: 18, color: subColor),
                          onPressed: () {
                            _searchController.clear();
                            ref.read(brainMemorySearchProvider.notifier).state = '';
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: isDark
                      ? BrandColors.nightSurface.withValues(alpha: 0.6)
                      : BrandColors.softWhite,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),

            // ── Filter chips ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                children: [
                  _FilterChip(
                    label: 'All',
                    selected: filter == 'all',
                    isDark: isDark,
                    onTap: () =>
                        ref.read(brainMemoryFilterProvider.notifier).state = 'all',
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Conversations',
                    selected: filter == 'sessions',
                    isDark: isDark,
                    onTap: () =>
                        ref.read(brainMemoryFilterProvider.notifier).state =
                            'sessions',
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Notes',
                    selected: filter == 'notes',
                    isDark: isDark,
                    onTap: () =>
                        ref.read(brainMemoryFilterProvider.notifier).state = 'notes',
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ── Memory feed ─────────────────────────────────────────────────
            Expanded(
              child: memoryAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.cloud_off, size: 40, color: subColor),
                        const SizedBox(height: 12),
                        Text(
                          'Brain unavailable',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: textColor),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Make sure the server is running.',
                          style: TextStyle(fontSize: 13, color: subColor),
                        ),
                      ],
                    ),
                  ),
                ),
                data: (data) {
                  final rawItems = (data['items'] as List? ?? [])
                      .cast<Map<String, dynamic>>();
                  final items = rawItems.map(MemoryItem.fromJson).toList();
                  if (items.isEmpty) {
                    return Center(
                      child: Text(
                        search.isNotEmpty
                            ? 'No memories match "$search"'
                            : 'No memories yet',
                        style: TextStyle(fontSize: 14, color: subColor),
                      ),
                    );
                  }
                  return _MemoryFeed(items: items, isDark: isDark);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter chip
// ─────────────────────────────────────────────────────────────────────────────

@immutable
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool isDark;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final selectedBg = isDark ? BrandColors.nightForest : BrandColors.forest;
    final unselectedBg = isDark ? BrandColors.nightSurface : BrandColors.softWhite;
    const selectedText = Colors.white;
    final unselectedText =
        isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? selectedBg : unselectedBg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? selectedText : unselectedText,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Memory feed — date-grouped, truly lazy
// ─────────────────────────────────────────────────────────────────────────────

/// Lightweight discriminated union for the flat list.
sealed class _FeedRow {
  const _FeedRow();
}

@immutable
class _HeaderRow extends _FeedRow {
  final String label;
  const _HeaderRow(this.label);
}

@immutable
class _ItemRow extends _FeedRow {
  final MemoryItem item;
  const _ItemRow(this.item);
}

@immutable
class _MemoryFeed extends StatelessWidget {
  final List<MemoryItem> items;
  final bool isDark;

  const _MemoryFeed({required this.items, required this.isDark});

  @override
  Widget build(BuildContext context) {
    // Build a flat list of lightweight value objects — no widgets here.
    final rows = <_FeedRow>[];
    String? currentLabel;
    final now = DateTime.now();

    for (final item in items) {
      final label = _dateLabel(item.ts, now);
      if (label != currentLabel) {
        rows.add(_HeaderRow(label));
        currentLabel = label;
      }
      rows.add(_ItemRow(item));
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rows.length,
      itemBuilder: (context, i) {
        return switch (rows[i]) {
          _HeaderRow r => _DateHeader(label: r.label, isDark: isDark),
          _ItemRow r => _MemoryItemTile(item: r.item, isDark: isDark),
        };
      },
    );
  }

  /// Calendar-day grouping (not 24-hour periods).
  /// e.g. an item from 11:30pm yesterday is "Yesterday", not "Today".
  String _dateLabel(String ts, DateTime now) {
    if (ts.isEmpty) return 'Unknown';
    try {
      final dt = DateTime.parse(ts).toLocal();
      final today = DateTime(now.year, now.month, now.day);
      final itemDay = DateTime(dt.year, dt.month, dt.day);
      final diffDays = today.difference(itemDay).inDays;
      if (diffDays == 0) return 'Today';
      if (diffDays == 1) return 'Yesterday';
      if (diffDays < 7) return 'This Week';
      if (diffDays < 30) return 'This Month';
      return 'Earlier';
    } catch (_) {
      return 'Unknown';
    }
  }
}

@immutable
class _DateHeader extends StatelessWidget {
  final String label;
  final bool isDark;

  const _DateHeader({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Single memory item tile
// ─────────────────────────────────────────────────────────────────────────────

@immutable
class _MemoryItemTile extends ConsumerWidget {
  final MemoryItem item;
  final bool isDark;

  const _MemoryItemTile({required this.item, required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isSession = item.kind == MemoryKind.session;

    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;
    final subColor = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
    final divColor = isDark
        ? BrandColors.nightTextSecondary.withValues(alpha: 0.1)
        : BrandColors.charcoal.withValues(alpha: 0.07);

    // Notes use the same forest palette as sessions but slightly muted
    final noteColor = isDark ? BrandColors.nightForest : BrandColors.forest;

    return InkWell(
      onTap: () => _navigate(ref),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Icon
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: isSession
                        ? (isDark
                            ? BrandColors.nightForest.withValues(alpha: 0.15)
                            : BrandColors.forest.withValues(alpha: 0.08))
                        : noteColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isSession ? Icons.chat_bubble_outline : Icons.book_outlined,
                    size: 16,
                    color: isSession
                        ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                        : noteColor.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(width: 12),
                // Title + relative time
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: textColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 1),
                      Text(
                        _relativeTime(item.ts),
                        style: TextStyle(fontSize: 12, color: subColor),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: subColor),
              ],
            ),
          ),
          Divider(height: 1, color: divColor, indent: 60),
        ],
      ),
    );
  }

  /// Navigate to the item using provider-based tab switching.
  ///
  /// NOTE: visibleTabs index order matches the IndexedStack child order
  /// in main.dart ([AppTab.chat, AppTab.daily, AppTab.brain] at indices 0, 1, 2).
  /// If either ordering changes, navigation will silently switch to the wrong tab.
  void _navigate(WidgetRef ref) {
    final visibleTabs = ref.read(visibleTabsProvider);

    if (item.kind == MemoryKind.session && item.id.isNotEmpty) {
      final chatIndex = visibleTabs.indexOf(AppTab.chat);
      if (chatIndex < 0) return;
      // unawaited: tab switches immediately; session loads in background.
      // Errors from loadSession are handled inside switchSessionProvider.
      unawaited(ref.read(switchSessionProvider)(item.id));
      ref.read(currentTabIndexProvider.notifier).state = chatIndex;
    } else if (item.kind == MemoryKind.note && item.date != null) {
      final dailyIndex = visibleTabs.indexOf(AppTab.daily);
      if (dailyIndex < 0) return;
      try {
        final parts = item.date!.split('-');
        if (parts.length == 3) {
          final date = DateTime(
            int.parse(parts[0]),
            int.parse(parts[1]),
            int.parse(parts[2]),
          );
          ref.read(selectedJournalDateProvider.notifier).state = date;
        }
      } catch (e, _) {
        debugPrint('[BrainHomeScreen] Failed to parse note date "${item.date}": $e');
      }
      ref.read(currentTabIndexProvider.notifier).state = dailyIndex;
    }
  }

  String _relativeTime(String ts) {
    if (ts.isEmpty) return '';
    try {
      final dt = DateTime.parse(ts).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return '${diff.inHours}h ago';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      return '${dt.day}/${dt.month}/${dt.year}';
    } catch (_) {
      return '';
    }
  }
}
