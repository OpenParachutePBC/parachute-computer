import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Placeholder for tool editing — will be rebuilt for v2 declarative tools.
class AgentEditScreen extends ConsumerWidget {
  final String? agentName;
  final bool isNew;

  const AgentEditScreen({
    super.key,
    this.agentName,
    this.isNew = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isNew ? 'New Tool' : (agentName ?? 'Edit Tool'),
          style: TextStyle(
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.build_outlined,
                size: 48,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
              SizedBox(height: Spacing.lg),
              Text(
                'Tool Editor Coming Soon',
                style: TextStyle(
                  fontSize: TypographyTokens.titleLarge,
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              SizedBox(height: Spacing.sm),
              Text(
                'In v2, tools are declarative graph queries and mutations.\nThe tool editor will let you create custom MCP tools.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: TypographyTokens.bodyMedium,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
