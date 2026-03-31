import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Brand-styled section header for settings screens
class SettingsSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;

  const SettingsSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 28,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              SizedBox(width: Spacing.md),
            ],
            Text(
              title,
              style: TextStyle(
                fontSize: TypographyTokens.headlineLarge,
                fontWeight: FontWeight.bold,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ],
        ),
        if (subtitle != null) ...[
          SizedBox(height: Spacing.sm),
          Text(
            subtitle!,
            style: TextStyle(
              fontSize: TypographyTokens.bodyMedium,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
          ),
        ],
      ],
    );
  }
}

/// Brand-styled subsection header for settings screens
class SettingsSubsectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const SettingsSubsectionHeader({
    super.key,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: TypographyTokens.titleLarge,
            fontWeight: FontWeight.bold,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        if (subtitle != null) ...[
          SizedBox(height: Spacing.xs),
          Text(
            subtitle!,
            style: TextStyle(
              fontSize: TypographyTokens.bodyMedium,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
          ),
        ],
      ],
    );
  }
}

/// Brand-styled toggle card for settings
class SettingsToggleCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? activeColor;
  final bool enabled;

  const SettingsToggleCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.value,
    required this.onChanged,
    this.activeColor,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveActiveColor = activeColor ??
        (isDark ? BrandColors.nightForest : BrandColors.forest);

    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Container(
        padding: EdgeInsets.all(Spacing.lg),
        decoration: BoxDecoration(
          color: value
              ? effectiveActiveColor.withValues(alpha: 0.1)
              : (isDark
                    ? BrandColors.nightSurfaceElevated
                    : BrandColors.stone.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: value
                ? effectiveActiveColor
                : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
                    .withValues(alpha: 0.3),
            width: value ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: value
                  ? effectiveActiveColor
                  : (isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood),
              size: 32,
            ),
            SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: TypographyTokens.bodyLarge,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                  SizedBox(height: Spacing.xs),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: enabled ? onChanged : null,
              activeTrackColor: effectiveActiveColor,
            ),
          ],
        ),
      ),
    );
  }
}

/// Brand-styled info banner for settings sections
class SettingsInfoBanner extends StatelessWidget {
  final String message;
  final IconData icon;
  final Color? color;

  const SettingsInfoBanner({
    super.key,
    required this.message,
    this.icon = Icons.info_outline,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveColor = color ??
        (isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep);

    return Container(
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: effectiveColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: effectiveColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: effectiveColor, size: 16),
          SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Brand-styled status card for settings (like Omi device, server status)
class SettingsStatusCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isActive;
  final Color? activeColor;
  final Color? inactiveColor;
  final VoidCallback? onTap;
  final Widget? trailing;
  final List<Widget>? additionalContent;

  const SettingsStatusCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isActive,
    this.activeColor,
    this.inactiveColor,
    this.onTap,
    this.trailing,
    this.additionalContent,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final effectiveActiveColor = activeColor ?? BrandColors.success;
    final effectiveInactiveColor = inactiveColor ??
        (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood);

    final statusColor = isActive ? effectiveActiveColor : effectiveInactiveColor;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: EdgeInsets.all(Spacing.lg),
        decoration: BoxDecoration(
          color: statusColor.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: statusColor,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: statusColor, size: 32),
                SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: statusColor,
                        ),
                      ),
                      SizedBox(height: Spacing.xs),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark
                              ? BrandColors.nightTextSecondary
                              : BrandColors.driftwood,
                        ),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
                if (onTap != null && trailing == null)
                  Icon(
                    Icons.chevron_right,
                    color: isDark
                        ? BrandColors.nightTextSecondary
                        : BrandColors.driftwood,
                  ),
              ],
            ),
            if (additionalContent != null) ...[
              SizedBox(height: Spacing.md),
              ...additionalContent!,
            ],
          ],
        ),
      ),
    );
  }
}
