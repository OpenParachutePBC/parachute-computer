import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart'
    show appVersionProvider, isDailyOnlyFlavor, isComputerFlavor, resetSetup;

/// About app information section
class AboutSection extends ConsumerWidget {
  const AboutSection({super.key});

  void _showResetConfirmation(BuildContext context, WidgetRef ref, bool isDark) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Setup?'),
        content: const Text(
          'This will clear your server configuration and return to the setup wizard.\n\n'
          'Your vault data (journals, chats, files) will NOT be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
            onPressed: () async {
              Navigator.pop(ctx);
              await resetSetup(ref);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Setup reset. Restart the app to begin setup again.')),
                );
              }
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final versionAsync = ref.watch(appVersionProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.info_outline,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'About',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        SizedBox(height: Spacing.lg),

        _AboutRow(
          label: 'App',
          value: isDailyOnlyFlavor ? 'Parachute Daily' : 'Parachute',
          isDark: isDark,
        ),
        _AboutRow(
          label: 'Version',
          value: versionAsync.when(
            data: (version) => version,
            loading: () => '...',
            error: (_, __) => 'Unknown',
          ),
          isDark: isDark,
        ),
        _AboutRow(label: 'Company', value: 'Open Parachute, PBC', isDark: isDark),

        SizedBox(height: Spacing.lg),
        Text(
          isDailyOnlyFlavor
              ? 'Simple voice journaling, locally stored'
              : 'Open & interoperable extended mind technology',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            fontStyle: FontStyle.italic,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),

        // Reset Setup button (for Computer flavor or troubleshooting)
        if (isComputerFlavor) ...[
          SizedBox(height: Spacing.xl),
          Divider(color: isDark ? BrandColors.nightTextSecondary.withValues(alpha: 0.3) : BrandColors.stone),
          SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Reset setup to start fresh',
                  style: TextStyle(
                    fontSize: TypographyTokens.bodySmall,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _showResetConfirmation(context, ref, isDark),
                child: Text(
                  'Reset Setup',
                  style: TextStyle(color: BrandColors.error),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Row for about section info
class _AboutRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;

  const _AboutRow({required this.label, required this.value, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: Spacing.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w500,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
        ],
      ),
    );
  }
}
