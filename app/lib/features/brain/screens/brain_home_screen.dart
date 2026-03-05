import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/graph_providers.dart';

/// Graph navigator — replaces the old BrainEntity browser.
///
/// Wide (≥700px): table sidebar | row/schema panel
/// Narrow: table list → row detail (pushed route)
class BrainHomeScreen extends ConsumerWidget {
  const BrainHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return constraints.maxWidth >= 700
            ? const _GraphWideLayout()
            : const _GraphNarrowLayout();
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Wide layout
// ──────────────────────────────────────────────────────────────────────────────

class _GraphWideLayout extends ConsumerWidget {
  const _GraphWideLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedTable = ref.watch(graphSelectedTableProvider);

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: 200,
              child: _TableSidebar(
                onTableTap: (name) =>
                    ref.read(graphSelectedTableProvider.notifier).state = name,
              ),
            ),
            VerticalDivider(
              width: 1,
              color: isDark
                  ? BrandColors.nightTextSecondary.withValues(alpha: 0.2)
                  : BrandColors.charcoal.withValues(alpha: 0.1),
            ),
            Expanded(
              child: selectedTable == null
                  ? Center(
                      child: Text(
                        'Select a table to explore',
                        style: TextStyle(
                          fontSize: 14,
                          color: isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood,
                        ),
                      ),
                    )
                  : _TablePanel(tableName: selectedTable),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Narrow layout
// ──────────────────────────────────────────────────────────────────────────────

class _GraphNarrowLayout extends ConsumerWidget {
  const _GraphNarrowLayout();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        title: Text(
          'Graph',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      body: _TableSidebar(
        onTableTap: (name) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => _TableDetailPage(tableName: name),
            ),
          );
        },
      ),
    );
  }
}

class _TableDetailPage extends StatelessWidget {
  final String tableName;
  const _TableDetailPage({required this.tableName});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        title: Text(
          tableName,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            fontSize: 15,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      body: _TablePanel(tableName: tableName),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Table sidebar
// ──────────────────────────────────────────────────────────────────────────────

class _TableSidebar extends ConsumerWidget {
  final void Function(String name) onTableTap;
  const _TableSidebar({required this.onTableTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final schemaAsync = ref.watch(graphSchemaProvider);
    final selectedTable = ref.watch(graphSelectedTableProvider);

    return Container(
      color: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
      child: schemaAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Schema error:\n$e',
            style: const TextStyle(fontSize: 12, color: Colors.red),
          ),
        ),
        data: (schema) {
          final nodeTables = (schema['node_tables'] as List? ?? [])
              .cast<Map<String, dynamic>>();
          final relTables = (schema['rel_tables'] as List? ?? [])
              .cast<Map<String, dynamic>>();

          return ListView(
            children: [
              _SectionLabel(isDark: isDark, label: 'NODE TABLES'),
              for (final t in nodeTables)
                _TableTile(
                  name: t['name'] as String,
                  isSelected: selectedTable == t['name'],
                  isDark: isDark,
                  onTap: () => onTableTap(t['name'] as String),
                ),
              if (relTables.isNotEmpty) ...[
                _SectionLabel(isDark: isDark, label: 'REL TABLES'),
                for (final t in relTables)
                  _TableTile(
                    name: t['name'] as String,
                    isSelected: selectedTable == t['name'],
                    isDark: isDark,
                    onTap: () => onTableTap(t['name'] as String),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

}

class _SectionLabel extends StatelessWidget {
  final bool isDark;
  final String label;
  const _SectionLabel({required this.isDark, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
        ),
      ),
    );
  }
}

class _TableTile extends StatelessWidget {
  final String name;
  final bool isSelected;
  final bool isDark;
  final VoidCallback onTap;

  const _TableTile({
    required this.name,
    required this.isSelected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isSelected
        ? (isDark
            ? BrandColors.nightForest.withValues(alpha: 0.2)
            : BrandColors.forest.withValues(alpha: 0.08))
        : Colors.transparent;

    return InkWell(
      onTap: onTap,
      child: Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          name,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: isSelected
                ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                : (isDark ? BrandColors.nightText : BrandColors.charcoal),
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Table panel
// ──────────────────────────────────────────────────────────────────────────────

class _TablePanel extends ConsumerWidget {
  final String tableName;
  const _TablePanel({required this.tableName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dataAsync = ref.watch(graphTableDataProvider(tableName));
    final schemaAsync = ref.watch(graphSchemaProvider);

    final columns = _findColumns(schemaAsync.valueOrNull, tableName);

    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Error: $e',
            style: TextStyle(
              color: isDark ? Colors.red.shade300 : Colors.red,
              fontSize: 13,
            ),
          ),
        ),
      ),
      data: (data) {
        final hasEndpoint = !data.containsKey('note');
        final rows = _extractRows(data);

        if (!hasEndpoint || rows.isEmpty) {
          return _SchemaView(
            tableName: tableName,
            columns: columns,
            isDark: isDark,
            note: data['note'] as String?,
          );
        }

        return _RowsView(
          tableName: tableName,
          rows: rows,
          isDark: isDark,
        );
      },
    );
  }

  List<Map<String, dynamic>> _findColumns(
      Map<String, dynamic>? schema, String name) {
    if (schema == null) return [];
    final all = [
      ...(schema['node_tables'] as List? ?? []),
      ...(schema['rel_tables'] as List? ?? []),
    ].cast<Map<String, dynamic>>();
    final match = all.where((t) => t['name'] == name).firstOrNull;
    return (match?['columns'] as List? ?? []).cast<Map<String, dynamic>>();
  }

  List<Map<String, dynamic>> _extractRows(Map<String, dynamic> data) {
    for (final key in ['sessions', 'projects', 'entries', 'rows']) {
      if (data.containsKey(key)) {
        return (data[key] as List? ?? []).cast<Map<String, dynamic>>();
      }
    }
    return [];
  }
}

class _SchemaView extends StatelessWidget {
  final String tableName;
  final List<Map<String, dynamic>> columns;
  final bool isDark;
  final String? note;

  const _SchemaView({
    required this.tableName,
    required this.columns,
    required this.isDark,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;
    final subColor = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
    final divColor = isDark
        ? BrandColors.nightTextSecondary.withValues(alpha: 0.15)
        : BrandColors.charcoal.withValues(alpha: 0.08);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tableName,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            note ?? 'Schema definition',
            style: TextStyle(fontSize: 12, color: subColor),
          ),
          const SizedBox(height: 16),
          Text(
            'COLUMNS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
              color: subColor,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.separated(
              itemCount: columns.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: divColor),
              itemBuilder: (_, i) {
                final col = columns[i];
                final isPk = col['primary_key'] == true;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      if (isPk) ...[
                        Icon(Icons.key, size: 12, color: subColor),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        col['name'] as String? ?? '',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isPk ? FontWeight.w600 : FontWeight.normal,
                          color: textColor,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        col['type'] as String? ?? '',
                        style: TextStyle(fontSize: 11, color: subColor),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RowsView extends StatelessWidget {
  final String tableName;
  final List<Map<String, dynamic>> rows;
  final bool isDark;

  const _RowsView({
    required this.tableName,
    required this.rows,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;
    final subColor = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
    final divColor = isDark
        ? BrandColors.nightTextSecondary.withValues(alpha: 0.15)
        : BrandColors.charcoal.withValues(alpha: 0.08);

    final (primaryKey, secondaryKey) = _previewKeys(tableName);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                tableName,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
              const Spacer(),
              Text(
                '${rows.length} rows',
                style: TextStyle(fontSize: 12, color: subColor),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: divColor),
        Expanded(
          child: ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => Divider(height: 1, color: divColor),
            itemBuilder: (context, i) {
              final row = rows[i];
              final primary = _clip(row[primaryKey]?.toString() ?? '—', 60);
              final secondary = secondaryKey != null
                  ? _clip(row[secondaryKey]?.toString() ?? '', 80)
                  : null;

              return ListTile(
                dense: true,
                title: Text(
                  primary,
                  style: TextStyle(fontSize: 13, color: textColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: (secondary != null && secondary.isNotEmpty)
                    ? Text(
                        secondary,
                        style: TextStyle(fontSize: 12, color: subColor),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : null,
                onTap: () => _showDetail(context, row),
              );
            },
          ),
        ),
      ],
    );
  }

  (String, String?) _previewKeys(String table) => switch (table) {
        'Parachute_Session' => ('title', 'session_id'),
        'Project' => ('display_name', 'slug'),
        'Journal_Entry' => ('snippet', 'date'),
        _ => ('name', null),
      };

  String _clip(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}…' : s;

  void _showDetail(BuildContext context, Map<String, dynamic> row) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RowDetailSheet(row: row),
    );
  }
}

class _RowDetailSheet extends StatelessWidget {
  final Map<String, dynamic> row;
  const _RowDetailSheet({required this.row});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? BrandColors.nightText : BrandColors.charcoal;
    final subColor = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
    final bgColor = isDark ? BrandColors.nightSurface : BrandColors.softWhite;
    final divColor = isDark
        ? BrandColors.nightTextSecondary.withValues(alpha: 0.15)
        : BrandColors.charcoal.withValues(alpha: 0.08);

    final entries = row.entries
        .where((e) => e.value != null && e.value.toString().isNotEmpty)
        .toList();

    return Container(
      color: bgColor,
      padding: const EdgeInsets.only(top: 8),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
      ),
      child: Column(
        children: [
          Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: subColor.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              itemCount: entries.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: divColor),
              itemBuilder: (_, i) {
                final e = entries[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.key,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                          color: subColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        e.value.toString(),
                        style: TextStyle(fontSize: 13, color: textColor),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
