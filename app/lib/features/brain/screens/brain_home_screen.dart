import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/brain_providers.dart';

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
                        ref.read(brainMemoryFilterProvider.notifier).state =
                            'all',
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
                        ref.read(brainMemoryFilterProvider.notifier).state =
                            'notes',
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
                  final items = (data['items'] as List? ?? [])
                      .cast<Map<String, dynamic>>();
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
    final selectedBg =
        isDark ? BrandColors.nightForest : BrandColors.forest;
    final unselectedBg =
        isDark ? BrandColors.nightSurface : BrandColors.softWhite;
    final selectedText = Colors.white;
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
// Memory feed — grouped by date
// ─────────────────────────────────────────────────────────────────────────────

class _MemoryFeed extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final bool isDark;

  const _MemoryFeed({required this.items, required this.isDark});

  @override
  Widget build(BuildContext context) {
    // Group items by date label
    final groups = <String, List<Map<String, dynamic>>>{};
    final groupOrder = <String>[];
    final now = DateTime.now();

    for (final item in items) {
      final label = _dateLabel(item['ts'] as String? ?? '', now);
      if (!groups.containsKey(label)) {
        groups[label] = [];
        groupOrder.add(label);
      }
      groups[label]!.add(item);
    }

    // Build flat list with section headers
    final widgets = <Widget>[];
    for (final label in groupOrder) {
      widgets.add(_DateHeader(label: label, isDark: isDark));
      for (final item in groups[label]!) {
        widgets.add(_MemoryItem(item: item, isDark: isDark));
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: widgets.length,
      itemBuilder: (_, i) => widgets[i],
    );
  }

  String _dateLabel(String ts, DateTime now) {
    if (ts.isEmpty) return 'Unknown';
    try {
      final dt = DateTime.parse(ts).toLocal();
      final diff = now.difference(dt);
      if (diff.inDays == 0) return 'Today';
      if (diff.inDays == 1) return 'Yesterday';
      if (diff.inDays < 7) return 'This Week';
      if (diff.inDays < 30) return 'This Month';
      return 'Earlier';
    } catch (_) {
      return 'Unknown';
    }
  }
}

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
// Single memory item
// ─────────────────────────────────────────────────────────────────────────────

class _MemoryItem extends ConsumerWidget {
  final Map<String, dynamic> item;
  final bool isDark;

  const _MemoryItem({required this.item, required this.isDark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = item['kind'] as String? ?? 'session';
    final title = item['title'] as String? ?? '';
    final ts = item['ts'] as String? ?? '';
    final isSession = kind == 'session';

    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;
    final subColor =
        isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
    final divColor = isDark
        ? BrandColors.nightTextSecondary.withValues(alpha: 0.1)
        : BrandColors.charcoal.withValues(alpha: 0.07);

    final subtitle = _relativeTime(ts);

    return InkWell(
      onTap: () => _navigate(context, item),
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
                        : (isDark
                            ? Colors.blue.withValues(alpha: 0.15)
                            : Colors.blue.withValues(alpha: 0.08)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isSession ? Icons.chat_bubble_outline : Icons.book_outlined,
                    size: 16,
                    color: isSession
                        ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                        : Colors.blue.shade400,
                  ),
                ),
                const SizedBox(width: 12),
                // Title + subtitle
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
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
                        subtitle,
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

  void _navigate(BuildContext context, Map<String, dynamic> item) {
    final kind = item['kind'] as String? ?? 'session';
    if (kind == 'session') {
      final id = item['id'] as String? ?? '';
      if (id.isNotEmpty) context.go('/chat/$id');
    } else {
      final date = item['date'] as String? ?? '';
      if (date.isNotEmpty) {
        context.go('/daily?date=$date');
      } else {
        context.go('/daily');
      }
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
