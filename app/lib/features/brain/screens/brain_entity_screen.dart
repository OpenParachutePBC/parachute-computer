import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import '../providers/brain_providers.dart';
import '../widgets/brain_tag_chip.dart';

/// Detail screen for a single Brain entity.
class BrainEntityScreen extends ConsumerWidget {
  final String paraId;
  final String name;

  const BrainEntityScreen({
    super.key,
    required this.paraId,
    required this.name,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entityAsync = ref.watch(brainEntityDetailProvider(paraId));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          name,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: entityAsync.when(
        data: (entity) {
          if (entity == null) {
            return Center(
              child: Text(
                'Entity not found',
                style: TextStyle(
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            );
          }

          return SingleChildScrollView(
            padding: EdgeInsets.all(Spacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Tags
                if (entity.tags.isNotEmpty) ...[
                  Wrap(
                    spacing: Spacing.xs,
                    runSpacing: Spacing.xs,
                    children: entity.tags
                        .map((tag) => BrainTagChip(tag: tag))
                        .toList(),
                  ),
                  SizedBox(height: Spacing.lg),
                ],
                // Content
                if (entity.content != null && entity.content!.isNotEmpty)
                  MarkdownBody(
                    data: entity.content!,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet(
                      p: TextStyle(
                        fontSize: TypographyTokens.bodyLarge,
                        color: isDark ? BrandColors.nightText : BrandColors.ink,
                        height: 1.6,
                      ),
                      h1: TextStyle(
                        fontSize: TypographyTokens.headlineMedium,
                        fontWeight: FontWeight.w700,
                        color: isDark ? BrandColors.nightText : BrandColors.ink,
                      ),
                      h2: TextStyle(
                        fontSize: TypographyTokens.headlineSmall,
                        fontWeight: FontWeight.w600,
                        color: isDark ? BrandColors.nightText : BrandColors.ink,
                      ),
                      h3: TextStyle(
                        fontSize: TypographyTokens.titleLarge,
                        fontWeight: FontWeight.w600,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                      code: TextStyle(
                        fontSize: TypographyTokens.bodyMedium,
                        backgroundColor: isDark
                            ? BrandColors.nightSurfaceElevated
                            : BrandColors.cream,
                      ),
                      blockquoteDecoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: isDark ? BrandColors.nightForest : BrandColors.forest,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  Text(
                    'No content available',
                    style: TextStyle(
                      fontSize: TypographyTokens.bodyMedium,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                // Path info
                if (entity.path != null) ...[
                  SizedBox(height: Spacing.xl),
                  Text(
                    entity.path!,
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: EdgeInsets.all(Spacing.lg),
            child: Text(
              'Error loading entity: $error',
              style: TextStyle(
                color: BrandColors.error,
                fontSize: TypographyTokens.bodyMedium,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
