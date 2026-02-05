import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart'
    show AppMode, appModeProvider, isDailyOnlyFlavor, showLimaControls, isComputerFlavor;
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/server_providers.dart' show isBundledAppProvider;
import 'package:parachute/core/providers/lima_vm_provider.dart' show isLimaVMRunningProvider;
import 'package:parachute/core/providers/bare_metal_provider.dart' show isBareMetalServerRunningProvider;
import '../widgets/omi_device_section.dart';
import '../widgets/api_key_section.dart';
import '../widgets/parachute_computer_section.dart';
import '../widgets/server_settings_section.dart';
import '../widgets/vault_settings_section.dart';
import '../widgets/sync_settings_section.dart';
import '../widgets/daily_agents_section.dart';
import '../widgets/migration_section.dart';
import '../widgets/about_section.dart';
import '../widgets/settings_card.dart';

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
  bool _isLoading = true;
  String _vaultPath = '';
  String _dailyFolderName = '';
  String _chatFolderName = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    // Load vault path and folder names
    final dailyService = ref.read(dailyFileSystemServiceProvider);
    await dailyService.initialize();
    _vaultPath = await dailyService.getVaultPathDisplay();
    _dailyFolderName = await dailyService.getModuleFolderName();

    final chatService = ref.read(chatFileSystemServiceProvider);
    await chatService.initialize();
    _chatFolderName = await chatService.getModuleFolderName();

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reloadVaultInfo() async {
    final dailyService = ref.read(dailyFileSystemServiceProvider);
    final displayPath = await dailyService.getVaultPathDisplay();
    if (mounted) {
      setState(() => _vaultPath = displayPath);
    }
  }


  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appMode = ref.watch(appModeProvider);
    final showChatFolder = appMode == AppMode.full;
    final isBundled = ref.watch(isBundledAppProvider);

    // Check if local server is running (auto-configured to localhost:3333)
    final limaVMRunning = ref.watch(isLimaVMRunningProvider);
    final bareMetalRunning = ref.watch(isBareMetalServerRunningProvider);
    final localServerRunning = limaVMRunning || bareMetalRunning;

    // Visibility flags for settings sections
    final showServerSettings = !isDailyOnlyFlavor;
    final showFullModeSettings = showServerSettings && showChatFolder;
    final showComputerControls = showServerSettings && (showLimaControls || isComputerFlavor) && (Platform.isMacOS || Platform.isLinux);

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

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

          // Vault Section (always shown)
          SettingsCard(
            isDark: isDark,
            child: VaultSettingsSection(
              vaultPath: _vaultPath,
              dailyFolderName: _dailyFolderName,
              chatFolderName: _chatFolderName,
              showChatFolder: showChatFolder,
              onVaultChanged: _reloadVaultInfo,
            ),
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

          // API Keys Section
          if (showFullModeSettings) ...[
            SizedBox(height: Spacing.xl),
            SettingsCard(
              isDark: isDark,
              child: const ApiKeySection(),
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

