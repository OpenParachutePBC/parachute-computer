import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../models/chat_session.dart';
import 'session_list_item.dart';

/// Groups sessions by date ranges: Today, Yesterday, Last 7 Days, Last 30 Days, Older
///
/// Uses a CustomScrollView with SliverList for sticky-style section headers.
/// Reuses [SessionListItem] for each session row.
class DateGroupedSessionList extends StatelessWidget {
  final List<ChatSession> sessions;
  final void Function(ChatSession session) onTap;
  final Future<void> Function(ChatSession session)? onDelete;
  final Future<void> Function(ChatSession session)? onArchive;
  final Future<void> Function(ChatSession session)? onUnarchive;
  final bool isDark;

  const DateGroupedSessionList({
    super.key,
    required this.sessions,
    required this.onTap,
    this.onDelete,
    this.onArchive,
    this.onUnarchive,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final groups = _groupSessions(sessions);

    return CustomScrollView(
      slivers: [
        const SliverPadding(padding: EdgeInsets.only(top: Spacing.sm)),
        for (final group in groups) ...[
          SliverToBoxAdapter(
            child: _SectionHeader(label: group.label, isDark: isDark),
          ),
          SliverPadding(
            padding: const EdgeInsets.only(bottom: Spacing.sm),
            sliver: SliverList.builder(
              itemCount: group.sessions.length,
              itemBuilder: (context, index) {
                final session = group.sessions[index];
                return SessionListItem(
                  session: session,
                  onTap: () => onTap(session),
                  onDelete: onDelete != null ? () => onDelete!(session) : null,
                  onArchive:
                      onArchive != null ? () => onArchive!(session) : null,
                  onUnarchive: onUnarchive != null
                      ? () => onUnarchive!(session)
                      : null,
                  isDark: isDark,
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  /// Groups sessions into date buckets using local timezone.
  static List<_DateGroup> _groupSessions(List<ChatSession> sessions) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final last7Start = todayStart.subtract(const Duration(days: 7));
    final last30Start = todayStart.subtract(const Duration(days: 30));

    final today = <ChatSession>[];
    final yesterday = <ChatSession>[];
    final last7 = <ChatSession>[];
    final last30 = <ChatSession>[];
    final older = <ChatSession>[];

    for (final session in sessions) {
      final date = (session.updatedAt ?? session.createdAt).toLocal();
      if (date.isAfter(todayStart) || date.isAtSameMomentAs(todayStart)) {
        today.add(session);
      } else if (date.isAfter(yesterdayStart) ||
          date.isAtSameMomentAs(yesterdayStart)) {
        yesterday.add(session);
      } else if (date.isAfter(last7Start) ||
          date.isAtSameMomentAs(last7Start)) {
        last7.add(session);
      } else if (date.isAfter(last30Start) ||
          date.isAtSameMomentAs(last30Start)) {
        last30.add(session);
      } else {
        older.add(session);
      }
    }

    return [
      if (today.isNotEmpty) _DateGroup('Today', today),
      if (yesterday.isNotEmpty) _DateGroup('Yesterday', yesterday),
      if (last7.isNotEmpty) _DateGroup('Last 7 Days', last7),
      if (last30.isNotEmpty) _DateGroup('Last 30 Days', last30),
      if (older.isNotEmpty) _DateGroup('Older', older),
    ];
  }
}

class _DateGroup {
  final String label;
  final List<ChatSession> sessions;
  const _DateGroup(this.label, this.sessions);
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final bool isDark;
  const _SectionHeader({required this.label, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: Spacing.lg,
        right: Spacing.lg,
        top: Spacing.md,
        bottom: Spacing.xs,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: TypographyTokens.labelMedium,
          fontWeight: FontWeight.w600,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
        ),
      ),
    );
  }
}
