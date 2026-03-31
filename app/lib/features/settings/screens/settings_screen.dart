import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart'
    show AppMode, appModeProvider, isDailyOnlyFlavor, isComputerFlavor;
import 'package:parachute/core/providers/server_providers.dart' show isBundledAppProvider;
import 'package:parachute/core/providers/bare_metal_provider.dart' show isBareMetalServerRunningProvider;
import '../widgets/omi_device_section.dart';
import '../widgets/api_key_section.dart';
import '../widgets/parachute_computer_section.dart';
import '../widgets/server_settings_section.dart';
import '../widgets/vault_settings_section.dart';
import '../widgets/sync_settings_section.dart';
import '../widgets/daily_agents_section.dart';
import '../widgets/trust_levels_section.dart';
import '../widgets/bot_connectors_section.dart';
import '../widgets/hooks_section.dart';
import '../widgets/credentials_section.dart';
import '../widgets/migration_section.dart';
import '../widgets/transcription_settings_section.dart';
import '../widgets/model_picker_dropdown.dart';
import '../widgets/provider_section.dart';
import '../widgets/server_control_section.dart';
import '../widgets/about_section.dart';
import '../widgets/settings_card.dart';
import 'capabilities_screen.dart';
import 'instructions_screen.dart';
import 'package:parachute/core/providers/supervisor_providers.dart';

/// Unified Settings screen for Parachute
///
/// Sections:
/// - Server Connection (enables Chat/Vault)
/// - Parachute Vault (storage location)
/// - Sync Settings
/// - Daily Agents
/// - Migration
/// - About
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// Builds model selection widget — dynamic picker when supervisor is available.
  Widget _buildModelSection() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final supervisorStatusAsync = ref.watch(supervisorStatusNotifierProvider);

    return supervisorStatusAsync.when(
      data: (status) {
        if (status.supervisorUptimeSeconds > 0) {
          return const ModelPickerDropdown();
        }
        return _buildNoSupervisorModelMessage(isDark);
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => _buildNoSupervisorModelMessage(isDark),
    );
  }

  Widget _buildNoSupervisorModelMessage(bool isDark) {
    return Row(
      children: [
        Icon(
          Icons.smart_toy_outlined,
          size: 20,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
        ),
        SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            'Start the Parachute server to configure the model.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.stone,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appMode = ref.watch(appModeProvider);
    final showChatFolder = appMode == AppMode.full;
    final isBundled = ref.watch(isBundledAppProvider);

    // Check if local server is running (auto-configured to localhost:3333)
    final bareMetalRunning = ref.watch(isBareMetalServerRunningProvider);
    final localServerRunning = bareMetalRunning;

    // Visibility flags for settings sections
    final showServerSettings = !isDailyOnlyFlavor;
    final showFullModeSettings = showServerSettings && showChatFolder;
    final showComputerControls = showServerSettings && isComputerFlavor && (Platform.isMacOS || Platform.isLinux);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Settings',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.softWhite,
        elevation: 0,
      ),
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: ListView(
        padding: EdgeInsets.all(Spacing.lg),
        children: [
          // Parachute Computer Section (macOS/Linux only)
          if (showComputerControls) ...[
            SettingsCard(
              isDark: isDark,
              child: const ParachuteComputerSection(),
            ),
            SizedBox(height: Spacing.xl),
          ],

          // Remote Server URL Section (hide when local server is running)
          if (showServerSettings && !localServerRunning) ...[
            SettingsCard(
              isDark: isDark,
              child: const ServerSettingsSection(),
            ),
            SizedBox(height: Spacing.xl),
          ],

          // Model Selection (requires server)
          if (showFullModeSettings) ...[
            SettingsCard(
              isDark: isDark,
              child: _buildModelSection(),
            ),
            SizedBox(height: Spacing.xl),
          ],

          // API Provider Selection (requires server)
          if (showFullModeSettings) ...[
            SettingsCard(
              isDark: isDark,
              child: const ProviderSection(),
            ),
            SizedBox(height: Spacing.xl),
          ],

          // Server Control (requires supervisor)
          if (showFullModeSettings) ...[
            SettingsCard(
              isDark: isDark,
              child: const ServerControlSection(),
            ),
            SizedBox(height: Spacing.xl),
          ],

          // Capabilities Section (Agents, Skills, MCP Servers)
          if (showFullModeSettings) ...[
            _CapabilitiesNavCard(isDark: isDark),
            SizedBox(height: Spacing.sm),
            _InstructionsNavCard(isDark: isDark),
            SizedBox(height: Spacing.xl),
          ],

          // Vault Section (always shown)
          SettingsCard(
            isDark: isDark,
            child: const VaultSettingsSection(),
          ),

          // Sync Section (remote clients only)
          if (showFullModeSettings && !isBundled) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const SyncSettingsSection(),
            ),
          ],

          // Daily Agents Section
          if (showFullModeSettings) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const DailyAgentsSection(),
            ),
          ],

          // Voice Transcription Mode
          if (showFullModeSettings) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const TranscriptionSettingsSection(),
            ),
          ],

          // API Keys Section
          if (showFullModeSettings) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const ApiKeySection(),
            ),
          ],

          // Credentials Section (sandbox credential helpers)
          if (showFullModeSettings) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const CredentialsSection(),
            ),
          ],

          // Trust Levels Section
          if (showFullModeSettings) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const TrustLevelsSection(),
            ),
          ],

          // Bot Connectors Section
          if (showFullModeSettings) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const BotConnectorsSection(),
            ),
          ],

          // Hooks Section
          if (showFullModeSettings) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const HooksSection(),
            ),
          ],

          // Omi Device Section (iOS/Android only) - always shown (offline feature)
          if (Platform.isIOS || Platform.isAndroid) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const OmiDeviceSection(),
            ),
          ],

          SizedBox(height: Spacing.xl),

          // Migration Section (only show if not in daily-only mode)
          if (!isDailyOnlyFlavor) ...[
            SettingsCard(
              isDark: isDark,
              child: const MigrationSection(),
            ),
            SizedBox(height: Spacing.xl),
          ],

          // About Section
          SettingsCard(
            isDark: isDark,
            child: const AboutSection(),
          ),

          SizedBox(height: Spacing.xxl),
        ],
      ),
    );
  }
}

/// Navigation card that opens the Instructions & Prompts screen.
class _InstructionsNavCard extends StatelessWidget {
  final bool isDark;
  const _InstructionsNavCard({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const InstructionsScreen()),
      ),
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: EdgeInsets.all(Spacing.lg),
        decoration: BoxDecoration(
          color: isDark
              ? BrandColors.nightSurfaceElevated
              : BrandColors.softWhite,
          borderRadius: BorderRadius.circular(Radii.md),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              Icons.tune_outlined,
              size: 28,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Instructions & Prompts',
                    style: TextStyle(
                      fontSize: TypographyTokens.titleMedium,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? BrandColors.nightText
                          : BrandColors.charcoal,
                    ),
                  ),
                  SizedBox(height: Spacing.xxs),
                  Text(
                    'Personal instructions & system prompt viewer',
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
            Icon(
              Icons.chevron_right,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
          ],
        ),
      ),
    );
  }
}

/// Navigation card that opens the Capabilities browser.
class _CapabilitiesNavCard extends StatelessWidget {
  final bool isDark;
  const _CapabilitiesNavCard({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CapabilitiesScreen()),
      ),
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: EdgeInsets.all(Spacing.lg),
        decoration: BoxDecoration(
          color: isDark
              ? BrandColors.nightSurfaceElevated
              : BrandColors.softWhite,
          borderRadius: BorderRadius.circular(Radii.md),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              Icons.extension_outlined,
              size: 28,
              color: isDark ? BrandColors.nightForest : BrandColors.forest,
            ),
            SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Capabilities',
                    style: TextStyle(
                      fontSize: TypographyTokens.titleMedium,
                      fontWeight: FontWeight.w600,
                      color: isDark
                          ? BrandColors.nightText
                          : BrandColors.charcoal,
                    ),
                  ),
                  SizedBox(height: Spacing.xxs),
                  Text(
                    'Agents, Skills & MCP Servers',
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
            Icon(
              Icons.chevron_right,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
          ],
        ),
      ),
    );
  }
}

