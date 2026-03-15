import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/backend_health_provider.dart'
    show serverTranscriptionAvailableProvider;
import 'package:parachute/features/daily/recorder/providers/service_providers.dart';

/// Settings section for transcription mode (auto / server / local).
class TranscriptionSettingsSection extends ConsumerWidget {
  const TranscriptionSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final modeAsync = ref.watch(transcriptionModeProvider);
    final serverAvailable = ref.watch(serverTranscriptionAvailableProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.mic,
              color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
            ),
            SizedBox(width: Spacing.sm),
            Text(
              'Voice Transcription',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: TypographyTokens.bodyLarge,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            const Spacer(),
            // Status indicator
            _StatusChip(
              serverAvailable: serverAvailable,
              isDark: isDark,
            ),
          ],
        ),
        SizedBox(height: Spacing.sm),
        Text(
          'Choose where voice notes are transcribed and cleaned up.',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(height: Spacing.lg),

        // Mode selector
        modeAsync.when(
          data: (currentMode) => _ModeSelector(
            currentMode: currentMode,
            serverAvailable: serverAvailable,
            isDark: isDark,
            onChanged: (mode) {
              setTranscriptionMode(mode);
              ref.invalidate(transcriptionModeProvider);
            },
          ),
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final bool serverAvailable;
  final bool isDark;

  const _StatusChip({
    required this.serverAvailable,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final color = serverAvailable ? BrandColors.success : BrandColors.driftwood;
    final label = serverAvailable ? 'Server ready' : 'Local only';

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: Spacing.xs),
          Text(
            label,
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeSelector extends StatelessWidget {
  final TranscriptionMode currentMode;
  final bool serverAvailable;
  final bool isDark;
  final ValueChanged<TranscriptionMode> onChanged;

  const _ModeSelector({
    required this.currentMode,
    required this.serverAvailable,
    required this.isDark,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ModeOption(
          title: 'Auto (recommended)',
          subtitle: 'Server when connected, local when offline',
          icon: Icons.auto_awesome,
          isSelected: currentMode == TranscriptionMode.auto,
          isDark: isDark,
          onTap: () => onChanged(TranscriptionMode.auto),
        ),
        SizedBox(height: Spacing.sm),
        _ModeOption(
          title: 'Server only',
          subtitle: serverAvailable
              ? 'Transcription + LLM cleanup on server'
              : 'Server transcription not available',
          icon: Icons.cloud,
          isSelected: currentMode == TranscriptionMode.server,
          isDark: isDark,
          enabled: serverAvailable,
          onTap: () => onChanged(TranscriptionMode.server),
        ),
        SizedBox(height: Spacing.sm),
        _ModeOption(
          title: 'Local only',
          subtitle: 'Always transcribe on this device',
          icon: Icons.phone_android,
          isSelected: currentMode == TranscriptionMode.local,
          isDark: isDark,
          onTap: () => onChanged(TranscriptionMode.local),
        ),
      ],
    );
  }
}

class _ModeOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final bool isDark;
  final bool enabled;
  final VoidCallback onTap;

  const _ModeOption({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.isDark,
    this.enabled = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
    final borderColor = isSelected
        ? accentColor
        : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood)
            .withValues(alpha: 0.3);
    final bgColor = isSelected ? accentColor.withValues(alpha: 0.1) : Colors.transparent;
    final opacity = enabled ? 1.0 : 0.5;

    return Opacity(
      opacity: opacity,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: borderColor, width: isSelected ? 2 : 1),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                color: isSelected
                    ? accentColor
                    : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
                size: 20,
              ),
              SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: TypographyTokens.bodyMedium,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                    SizedBox(height: 2),
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
              if (isSelected)
                Icon(Icons.check_circle, color: accentColor, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
