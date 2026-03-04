import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/daily/journal/providers/journal_providers.dart';

/// Provider for markdown import status. Invalidated after a successful import.
final _importStatusProvider = FutureProvider.autoDispose<Map<String, dynamic>?>((ref) async {
  final api = ref.watch(dailyApiServiceProvider);
  return api.getImportStatus();
});

/// Journal import settings section.
///
/// Allows users to trigger markdown-to-graph import for existing Parachute
/// journal files. The vault path concept is no longer user-configurable;
/// audio files are now stored on the server at ~/.parachute/daily/assets/.
class VaultSettingsSection extends ConsumerStatefulWidget {
  // Parameters kept for API compatibility but no longer used in the UI.
  // They will be removed in a follow-up cleanup once all callers are updated.
  final String vaultPath;
  final String dailyFolderName;
  final String chatFolderName;
  final bool showChatFolder;

  const VaultSettingsSection({
    super.key,
    required this.vaultPath,
    required this.dailyFolderName,
    required this.chatFolderName,
    required this.showChatFolder,
  });

  @override
  ConsumerState<VaultSettingsSection> createState() => _VaultSettingsSectionState();
}

class _VaultSettingsSectionState extends ConsumerState<VaultSettingsSection> {
  bool _importing = false;

  Future<void> _triggerImport() async {
    setState(() => _importing = true);
    try {
      final api = ref.read(dailyApiServiceProvider);
      final result = await api.triggerImport();
      if (mounted) {
        final msg = result?['message'] as String? ?? 'Import complete';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
        ref.invalidate(_importStatusProvider);
        ref.invalidate(todayJournalProvider);
        ref.invalidate(selectedJournalProvider);
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusAsync = ref.watch(_importStatusProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.download_for_offline,
                color: isDark ? BrandColors.nightForest : BrandColors.forest),
            SizedBox(width: Spacing.sm),
            Text(
              'Journal Import',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.md),
        const _FlexibleImportSection(),
        SizedBox(height: Spacing.lg),
        Divider(
          color: (isDark ? BrandColors.nightSurface : BrandColors.cream)
              .withValues(alpha: 0.8),
        ),
        SizedBox(height: Spacing.md),
        Row(
          children: [
            Icon(Icons.folder_special,
                color: isDark ? BrandColors.nightForest : BrandColors.forest),
            SizedBox(width: Spacing.sm),
            Text(
              'Parachute Vault Import',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Import entries from your Parachute vault\'s Daily folder.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.md),
        statusAsync.when(
          loading: () => const LinearProgressIndicator(),
          error: (err, st) => Text(
            'Server unavailable — start Parachute server to import.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          data: (status) {
            if (status == null) {
              return Text(
                'Server unavailable — start Parachute server to import.',
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              );
            }
            final totalFiles = status['total_md_files'] as int? ?? 0;
            final totalSections = status['total_sections'] as int? ?? totalFiles;
            final imported = status['imported'] as int? ?? 0;
            final pending = status['pending'] as int? ?? 0;
            if (totalFiles == 0) {
              return Text(
                'No markdown journal files found in vault.',
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: EdgeInsets.all(Spacing.sm),
                  decoration: BoxDecoration(
                    color: (isDark ? BrandColors.nightSurface : BrandColors.cream)
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ImportStat(
                            label: 'Total', value: '$totalSections', isDark: isDark),
                      ),
                      Expanded(
                        child: _ImportStat(
                            label: 'Imported', value: '$imported', isDark: isDark),
                      ),
                      Expanded(
                        child: _ImportStat(
                            label: 'Pending',
                            value: '$pending',
                            isDark: isDark,
                            highlight: pending > 0),
                      ),
                    ],
                  ),
                ),
                if (pending > 0) ...[
                  SizedBox(height: Spacing.md),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _importing ? null : _triggerImport,
                      icon: _importing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.download, size: 18),
                      label: Text(_importing
                          ? 'Importing...'
                          : 'Import $pending entries'),
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            isDark ? BrandColors.nightForest : BrandColors.forest,
                      ),
                    ),
                  ),
                ] else ...[
                  SizedBox(height: Spacing.sm),
                  Row(
                    children: [
                      Icon(Icons.check_circle,
                          size: 16,
                          color: isDark ? BrandColors.nightForest : BrandColors.forest),
                      SizedBox(width: Spacing.xs),
                      Text(
                        'All entries imported',
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark ? BrandColors.nightForest : BrandColors.forest,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

/// Flexible journal importer — lets users import from Obsidian, Logseq,
/// plain markdown, or Parachute-format folders.
class _FlexibleImportSection extends ConsumerStatefulWidget {
  const _FlexibleImportSection();

  @override
  ConsumerState<_FlexibleImportSection> createState() =>
      _FlexibleImportSectionState();
}

class _FlexibleImportSectionState
    extends ConsumerState<_FlexibleImportSection> {
  String? _sourceDir;
  String _format = 'obsidian';
  bool _previewing = false;
  bool _importing = false;
  Map<String, dynamic>? _previewResult;

  static const _formats = [
    ('obsidian', 'Obsidian'),
    ('logseq', 'Logseq'),
    ('parachute', 'Parachute'),
    ('plain', 'Plain'),
  ];

  Future<void> _pickDirectory() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select journal folder',
    );
    if (dir != null && mounted) {
      setState(() {
        _sourceDir = dir;
        _previewResult = null;
      });
    }
  }

  Future<void> _preview() async {
    if (_sourceDir == null) return;
    setState(() => _previewing = true);
    try {
      final api = ref.read(dailyApiServiceProvider);
      final result = await api.flexibleImport(
        sourceDir: _sourceDir!,
        format: _format,
        dryRun: true,
      );
      if (mounted) setState(() => _previewResult = result);
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _import() async {
    if (_sourceDir == null) return;
    setState(() => _importing = true);
    try {
      final api = ref.read(dailyApiServiceProvider);
      final result = await api.flexibleImport(
        sourceDir: _sourceDir!,
        format: _format,
        dryRun: false,
      );
      if (mounted) {
        final imported = result?['imported'] as int? ?? 0;
        final msg = result != null
            ? 'Imported $imported entries'
            : 'Import failed — check server logs';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        setState(() => _previewResult = result);
        if (result != null) {
          ref.invalidate(todayJournalProvider);
          ref.invalidate(selectedJournalProvider);
        }
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondary =
        isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
    final surface = (isDark ? BrandColors.nightSurface : BrandColors.cream)
        .withValues(alpha: 0.5);

    final toImport = _previewResult?['to_import'] as int? ?? 0;
    final busy = _previewing || _importing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Directory picker row
        Container(
          padding: EdgeInsets.symmetric(
              horizontal: Spacing.sm, vertical: Spacing.xs),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _sourceDir ?? 'No folder selected',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: _sourceDir != null
                        ? (isDark ? BrandColors.nightText : BrandColors.charcoal)
                        : textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              SizedBox(width: Spacing.xs),
              TextButton.icon(
                onPressed: busy ? null : _pickDirectory,
                icon: const Icon(Icons.folder_open, size: 16),
                label: const Text('Browse'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(
                      horizontal: Spacing.sm, vertical: Spacing.xs),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: Spacing.sm),
        // Format selector
        Wrap(
          spacing: Spacing.xs,
          children: _formats.map((pair) {
            final (value, label) = pair;
            final selected = _format == value;
            return ChoiceChip(
              label: Text(label),
              selected: selected,
              onSelected: busy
                  ? null
                  : (v) {
                      if (v) setState(() { _format = value; _previewResult = null; });
                    },
              selectedColor:
                  isDark ? BrandColors.nightForest : BrandColors.forest,
              labelStyle: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: selected ? Colors.white : null,
              ),
            );
          }).toList(),
        ),
        SizedBox(height: Spacing.sm),
        // Preview button
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: (_sourceDir == null || busy) ? null : _preview,
            icon: _previewing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.preview, size: 16),
            label: const Text('Preview'),
          ),
        ),
        // Preview result
        if (_previewResult != null) ...[
          SizedBox(height: Spacing.sm),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: _PreviewResultSummary(
                result: _previewResult!, isDark: isDark),
          ),
          if (toImport > 0) ...[
            SizedBox(height: Spacing.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _importing ? null : _import,
                icon: _importing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.download, size: 16),
                label: Text(
                    _importing ? 'Importing...' : 'Import $toImport entries'),
                style: FilledButton.styleFrom(
                  backgroundColor:
                      isDark ? BrandColors.nightForest : BrandColors.forest,
                ),
              ),
            ),
          ] else if (!(_previewResult?['dry_run'] as bool? ?? true)) ...[
            SizedBox(height: Spacing.xs),
            Row(
              children: [
                Icon(Icons.check_circle,
                    size: 14,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest),
                SizedBox(width: Spacing.xs),
                Text(
                  'All entries already imported',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }
}

class _PreviewResultSummary extends StatelessWidget {
  final Map<String, dynamic> result;
  final bool isDark;

  const _PreviewResultSummary({required this.result, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final filesFound = result['files_found'] as int? ?? 0;
    final entriesParsed = result['entries_parsed'] as int? ?? 0;
    final toImport = result['to_import'] as int? ?? 0;
    final imported = result['imported'] as int? ?? 0;
    final isDryRun = result['dry_run'] as bool? ?? true;

    final stats = isDryRun
        ? [
            ('Files', '$filesFound'),
            ('Entries', '$entriesParsed'),
            ('New', '$toImport'),
          ]
        : [
            ('Files', '$filesFound'),
            ('Parsed', '$entriesParsed'),
            ('Imported', '$imported'),
          ];

    return Row(
      children: stats
          .map((pair) => Expanded(
                child: _ImportStat(
                  label: pair.$1,
                  value: pair.$2,
                  isDark: isDark,
                  highlight: isDryRun
                      ? pair.$1 == 'New' && toImport > 0
                      : pair.$1 == 'Imported' && imported > 0,
                ),
              ))
          .toList(),
    );
  }
}

class _ImportStat extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;
  final bool highlight;

  const _ImportStat({
    required this.label,
    required this.value,
    required this.isDark,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = highlight
        ? (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
        : (isDark ? BrandColors.nightText : BrandColors.charcoal);
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 18, color: color)),
        Text(label,
            style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood)),
      ],
    );
  }
}
