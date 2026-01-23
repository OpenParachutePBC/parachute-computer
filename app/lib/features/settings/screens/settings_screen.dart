import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart'
    show AppMode, appModeProvider, serverUrlProvider, apiKeyProvider, syncModeProvider, SyncMode, isDailyOnlyFlavor, showLimaControls, isComputerFlavor, serverModeProvider, ServerMode, isLimaVMModeProvider, isBareMetalModeProvider;
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/providers/server_providers.dart';
import 'package:parachute/core/providers/sync_provider.dart';
import 'package:parachute/core/providers/lima_vm_provider.dart';
import 'package:parachute/core/providers/bare_metal_provider.dart';
import 'package:parachute/core/services/lima_vm_service.dart' show LimaVMStatus;
import 'package:parachute/core/services/sync_service.dart';
import 'package:parachute/core/services/backend_health_service.dart';
import 'package:parachute/features/daily/journal/providers/journal_providers.dart';
import 'package:parachute/features/daily/journal/screens/curator_log_screen.dart';
import '../widgets/omi_device_section.dart';
import '../widgets/api_key_section.dart';
import '../widgets/lima_vm_section.dart';
import '../widgets/bare_metal_section.dart';

/// Unified Settings screen for Parachute
///
/// Sections:
/// - Server Connection (enables Chat/Vault)
/// - Parachute Vault (storage location)
/// - About
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _serverUrlController = TextEditingController();
  bool _isLoading = true;
  String _vaultPath = '';
  String _dailyFolderName = '';
  String _chatFolderName = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    // Load server URL from FeatureFlagsService (same key as working chat app)
    final featureFlags = ref.read(featureFlagsServiceProvider);
    final serverUrl = await featureFlags.getAiServerUrl();
    _serverUrlController.text = serverUrl;

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

  Future<void> _saveServerUrl() async {
    final url = _serverUrlController.text.trim();
    final featureFlags = ref.read(featureFlagsServiceProvider);

    // Save using FeatureFlagsService (same key as working chat app)
    await featureFlags.setAiServerUrl(url.isEmpty ? 'http://localhost:3333' : url);
    featureFlags.clearCache();

    // Invalidate the provider so ChatService rebuilds with the new URL
    ref.invalidate(aiServerUrlProvider);

    // Also update serverUrlProvider for app mode detection
    await ref.read(serverUrlProvider.notifier).setServerUrl(url.isEmpty ? null : url);

    // Reinitialize sync with new server URL
    if (url.isNotEmpty) {
      final apiKey = await ref.read(apiKeyProvider.future);
      await ref.read(syncProvider.notifier).reinitialize(url, apiKey: apiKey);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(url.isEmpty
              ? 'Server URL cleared - Daily only mode'
              : 'Server URL saved - Chat & Vault enabled'),
          backgroundColor: BrandColors.success,
        ),
      );
    }
  }

  Future<void> _testServerConnection() async {
    final url = _serverUrlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Enter a server URL first'),
          backgroundColor: BrandColors.warning,
        ),
      );
      return;
    }

    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(BrandColors.softWhite),
              ),
            ),
            SizedBox(width: Spacing.md),
            const Text('Testing connection...'),
          ],
        ),
        duration: const Duration(seconds: 10),
      ),
    );

    // Actually test the connection
    final healthService = BackendHealthService(baseUrl: url);
    try {
      final status = await healthService.checkHealth();

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        if (status.isHealthy) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(status.serverVersion != null
                  ? 'Connected to Parachute Base v${status.serverVersion}'
                  : 'Connected to Parachute Base'),
              backgroundColor: BrandColors.success,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${status.message}: ${status.helpText}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection failed: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    } finally {
      healthService.dispose();
    }
  }

  Future<void> _openFolder(String path) async {
    try {
      // Resolve ~ to home directory
      String resolvedPath = path;
      if (path.startsWith('~')) {
        final home = Platform.environment['HOME'];
        if (home != null) {
          resolvedPath = path.replaceFirst('~', home);
        }
      }

      final uri = Uri.file(resolvedPath);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Could not open folder'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  Future<void> _changeVaultFolder() async {
    final dailyService = ref.read(dailyFileSystemServiceProvider);
    final chatService = ref.read(chatFileSystemServiceProvider);

    // Handle Android permissions
    if (Platform.isAndroid) {
      final hasPermission = await dailyService.hasStoragePermission();
      if (!hasPermission) {
        final granted = await dailyService.requestStoragePermission();
        if (!granted) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Storage permission required'),
                backgroundColor: BrandColors.error,
              ),
            );
          }
          return;
        }
      }
    }

    debugPrint('[Settings] Opening folder picker...');

    try {
      final selectedDirectory = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose Parachute Folder',
      );

      debugPrint('[Settings] Folder picker returned: $selectedDirectory');

      if (selectedDirectory != null) {
        // Update both services to use the same vault location
        final dailySuccess = await dailyService.setVaultPath(selectedDirectory, migrateFiles: false);
        final chatSuccess = await chatService.setVaultPath(selectedDirectory, migrateFiles: false);

        if (dailySuccess && chatSuccess) {
          final displayPath = await dailyService.getVaultPathDisplay();
          setState(() => _vaultPath = displayPath);

          // Invalidate all providers that depend on file paths so they refresh
          ref.invalidate(journalServiceFutureProvider);
          ref.invalidate(todayJournalProvider);
          ref.invalidate(selectedJournalProvider);
          ref.invalidate(journalDatesProvider);
          ref.invalidate(chatLogServiceFutureProvider);
          ref.invalidate(selectedChatLogProvider);
          ref.invalidate(reflectionServiceFutureProvider);
          ref.invalidate(selectedReflectionProvider);
          ref.invalidate(dailyRootPathProvider);
          ref.invalidate(chatRootPathProvider);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Parachute vault: $displayPath'),
                backgroundColor: BrandColors.success,
              ),
            );
          }
        }
      } else {
        debugPrint('[Settings] User cancelled folder picker or picker failed');
      }
    } catch (e, stackTrace) {
      debugPrint('[Settings] Error in folder picker: $e');
      debugPrint('[Settings] Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening folder picker: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appMode = ref.watch(appModeProvider);
    final showChatFolder = appMode == AppMode.full;
    final isBundled = ref.watch(isBundledAppProvider);

    // Check server mode for Computer flavor
    final isLimaVMMode = ref.watch(isLimaVMModeProvider);
    final isBareMetalMode = ref.watch(isBareMetalModeProvider);

    // Check if Lima VM is running (for auto-configuring server URL)
    final limaVMRunning = ref.watch(isLimaVMRunningProvider);
    // Check if bare metal server is running
    final bareMetalRunning = ref.watch(isBareMetalServerRunningProvider);
    // Server is running in either mode
    final serverRunning = limaVMRunning || bareMetalRunning;

    // Daily flavor: Hide all server-related UI
    final showServerSettings = !isDailyOnlyFlavor;

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
          // Show appropriate section based on server mode
          if (showServerSettings && (showLimaControls || isComputerFlavor) && (Platform.isMacOS || Platform.isLinux)) ...[
            // Server Mode Selection (allows switching between Lima VM and Bare Metal)
            _buildServerModeSection(isDark, isLimaVMMode, isBareMetalMode),
            SizedBox(height: Spacing.lg),
            // Show Lima VM section if in Lima mode
            if (isLimaVMMode)
              _SettingsCard(
                isDark: isDark,
                child: const LimaVMSection(),
              )
            // Show Bare Metal section if in bare metal mode
            else if (isBareMetalMode)
              _SettingsCard(
                isDark: isDark,
                child: const BareMetalSection(),
              )
            // Default: show Lima section (for backward compatibility or initial setup)
            else
              _SettingsCard(
                isDark: isDark,
                child: const LimaVMSection(),
              ),
            SizedBox(height: Spacing.xl),
          ],

          // Server Connection Section (full flavor only)
          // Hide when any local server is running (auto-configured to localhost:3333)
          if (showServerSettings && !serverRunning) ...[
            _buildServerSection(isDark),
            SizedBox(height: Spacing.xl),
          ],

          // Parachute Vault Section (unified storage) - always shown
          _buildVaultSection(isDark, showChatFolder),

          // Sync Section (only for remote clients with server configured)
          if (showServerSettings && showChatFolder && !isBundled) ...[
            SizedBox(height: Spacing.xl),
            _buildSyncSection(isDark),
          ],

          // Daily Agents Section (full flavor only, when server is connected)
          if (showServerSettings && showChatFolder) ...[
            SizedBox(height: Spacing.xl),
            _buildSchedulerSection(isDark),
          ],

          // API Keys Section (for multi-device auth, full flavor only)
          if (showServerSettings && showChatFolder) ...[
            SizedBox(height: Spacing.xl),
            _SettingsCard(
              isDark: isDark,
              child: const ApiKeySection(),
            ),
          ],

          // Omi Device Section (iOS/Android only) - always shown (offline feature)
          if (Platform.isIOS || Platform.isAndroid) ...[
            SizedBox(height: Spacing.xl),
            _SettingsCard(
              isDark: isDark,
              child: const OmiDeviceSection(),
            ),
          ],

          SizedBox(height: Spacing.xl),

          // About Section
          _buildAboutSection(isDark),

          SizedBox(height: Spacing.xxl),
        ],
      ),
    );
  }

  Widget _buildServerSection(bool isDark) {
    return _SettingsCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_outlined,
                color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
              SizedBox(width: Spacing.sm),
              Text(
                'Parachute Base Server',
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
            'Connect to a Parachute Base server to enable AI Chat and Vault features. '
            'Leave empty for offline Daily-only mode.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.lg),

          TextField(
            controller: _serverUrlController,
            decoration: InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://localhost:3333',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.link),
              suffixIcon: IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _serverUrlController.clear();
                  _saveServerUrl();
                },
              ),
            ),
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _saveServerUrl(),
          ),
          SizedBox(height: Spacing.lg),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testServerConnection,
                  icon: const Icon(Icons.wifi_tethering, size: 18),
                  label: const Text('Test Connection'),
                ),
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saveServerUrl,
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('Save'),
                  style: FilledButton.styleFrom(
                    backgroundColor: BrandColors.turquoise,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildServerModeSection(bool isDark, bool isLimaVMMode, bool isBareMetalMode) {
    final serverModeAsync = ref.watch(serverModeProvider);
    final currentMode = serverModeAsync.valueOrNull ?? ServerMode.limaVM;

    return _SettingsCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.settings_suggest,
                color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
              SizedBox(width: Spacing.sm),
              Text(
                'Server Mode',
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
            'Choose how Parachute runs its backend server.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.lg),

          // Server mode options
          _ServerModeOption(
            icon: Icons.security,
            title: 'Lima VM',
            subtitle: 'Isolated virtual machine. Claude can only access your vault.',
            isSelected: currentMode == ServerMode.limaVM,
            isDark: isDark,
            onTap: currentMode != ServerMode.limaVM
                ? () => _switchServerMode(ServerMode.limaVM)
                : null,
          ),
          SizedBox(height: Spacing.sm),
          _ServerModeOption(
            icon: Icons.speed,
            title: 'Bare Metal',
            subtitle: 'Direct on macOS. Best performance with native ML and Metal.',
            isSelected: currentMode == ServerMode.bareMetal,
            isDark: isDark,
            onTap: currentMode != ServerMode.bareMetal
                ? () => _switchServerMode(ServerMode.bareMetal)
                : null,
          ),
        ],
      ),
    );
  }

  Future<void> _switchServerMode(ServerMode newMode) async {
    final currentModeAsync = ref.read(serverModeProvider);
    final currentMode = currentModeAsync.valueOrNull;

    if (currentMode == newMode) return;

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AlertDialog(
          title: Text(
            newMode == ServerMode.limaVM
                ? 'Switch to Lima VM?'
                : 'Switch to Bare Metal?',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                newMode == ServerMode.limaVM
                    ? 'This will use an isolated virtual machine for added security. Claude will only be able to access files in your vault.'
                    : 'This will run the server directly on macOS for better performance. Claude will have access to native ML acceleration.',
              ),
              SizedBox(height: Spacing.md),
              Container(
                padding: EdgeInsets.all(Spacing.sm),
                decoration: BoxDecoration(
                  color: BrandColors.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(color: BrandColors.warning.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: BrandColors.warning),
                    SizedBox(width: Spacing.xs),
                    Expanded(
                      child: Text(
                        'The current server will be stopped. You may need to set up the new mode.',
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                backgroundColor: BrandColors.turquoise,
              ),
              child: const Text('Switch'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) return;

    // Stop current server based on old mode
    if (currentMode == ServerMode.limaVM) {
      final limaService = ref.read(limaVMServiceProvider);
      final status = await limaService.checkStatus();
      if (status == LimaVMStatus.running) {
        await limaService.stop();
      }
    } else if (currentMode == ServerMode.bareMetal) {
      final bareMetalService = ref.read(bareMetalServiceProvider);
      await bareMetalService.stopServer();
    }

    // Switch the mode
    await ref.read(serverModeProvider.notifier).setServerMode(newMode);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            newMode == ServerMode.limaVM
                ? 'Switched to Lima VM mode'
                : 'Switched to Bare Metal mode',
          ),
          backgroundColor: BrandColors.success,
        ),
      );
    }
  }

  Widget _buildVaultSection(bool isDark, bool showChatFolder) {
    return _SettingsCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.folder_special,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              SizedBox(width: Spacing.sm),
              Text(
                'Parachute Vault',
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
            'Your Parachute data is stored locally in this folder.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.lg),

          // Vault path display
          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightForest : BrandColors.forest)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_open, size: 20),
                SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    _vaultPath,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: Spacing.md),

          // Subfolder info
          Container(
            padding: EdgeInsets.all(Spacing.sm),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightSurface : BrandColors.cream)
                  .withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FolderInfoRow(
                  icon: Icons.wb_sunny,
                  iconColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                  folderName: _dailyFolderName,
                  description: 'journals & recordings',
                  isDark: isDark,
                ),
                if (showChatFolder) ...[
                  SizedBox(height: Spacing.xs),
                  _FolderInfoRow(
                    icon: Icons.chat_bubble,
                    iconColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                    folderName: _chatFolderName,
                    description: 'AI sessions & content',
                    isDark: isDark,
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: Spacing.lg),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _changeVaultFolder,
                  icon: const Icon(Icons.folder, size: 18),
                  label: const Text('Change'),
                ),
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _openFolder(_vaultPath),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open'),
                  style: FilledButton.styleFrom(
                    backgroundColor: isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSyncSection(bool isDark) {
    final syncState = ref.watch(syncProvider);
    final syncNotifier = ref.read(syncProvider.notifier);
    final syncModeAsync = ref.watch(syncModeProvider);
    final syncModeNotifier = ref.read(syncModeProvider.notifier);

    return _SettingsCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.sync,
                color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
              SizedBox(width: Spacing.sm),
              Text(
                'Daily Sync',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: TypographyTokens.bodyLarge,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              // Conflict badge
              if (syncState.hasConflicts) ...[
                SizedBox(width: Spacing.xs),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: Spacing.xs,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: BrandColors.warning,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Text(
                    '${syncState.unresolvedConflicts.length}',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      fontWeight: FontWeight.bold,
                      color: BrandColors.softWhite,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              if (syncState.isSyncing)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                    ),
                  ),
                )
              else if (syncState.hasConflicts)
                Icon(Icons.warning_amber_rounded, color: BrandColors.warning, size: 20)
              else if (syncState.status == SyncStatus.success)
                Icon(Icons.check_circle, color: BrandColors.success, size: 20)
              else if (syncState.hasError)
                Icon(Icons.error, color: BrandColors.error, size: 20),
            ],
          ),
          SizedBox(height: Spacing.sm),
          Text(
            'Sync your Daily journals with your Parachute Base server.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.lg),

          // Sync Mode Toggle
          syncModeAsync.when(
            data: (syncMode) => Container(
              padding: EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(
                color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                    .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(
                  color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                      .withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Include media files',
                        style: TextStyle(
                          fontSize: TypographyTokens.bodyMedium,
                          fontWeight: FontWeight.w500,
                          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                        ),
                      ),
                      Switch(
                        value: syncMode == SyncMode.full,
                        onChanged: (value) {
                          syncModeNotifier.setSyncMode(
                            value ? SyncMode.full : SyncMode.textOnly,
                          );
                        },
                        activeColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                      ),
                    ],
                  ),
                  SizedBox(height: Spacing.xs),
                  Text(
                    syncMode == SyncMode.full
                        ? 'Syncing all files including audio and images (uses more bandwidth)'
                        : 'Syncing text files only (faster, less bandwidth)',
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          SizedBox(height: Spacing.md),

          // Last sync info
          if (syncState.lastSyncTime != null) ...[
            Container(
              padding: EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                    .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.history,
                    size: 16,
                    color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                  ),
                  SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Text(
                      _formatLastSync(syncState.lastSyncTime!, syncState.lastResult),
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: Spacing.md),
          ],

          // Error message
          if (syncState.hasError && syncState.errorMessage != null) ...[
            Container(
              padding: EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: BrandColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: BrandColors.error),
                  SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Text(
                      syncState.errorMessage!,
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: BrandColors.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: Spacing.md),
          ],

          // Conflicts info
          if (syncState.hasConflicts) ...[
            Container(
              padding: EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: BrandColors.warning.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(
                  color: BrandColors.warning.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 16, color: BrandColors.warning),
                      SizedBox(width: Spacing.xs),
                      Text(
                        '${syncState.unresolvedConflicts.length} conflict${syncState.unresolvedConflicts.length == 1 ? '' : 's'} detected',
                        style: TextStyle(
                          fontSize: TypographyTokens.bodySmall,
                          fontWeight: FontWeight.w600,
                          color: BrandColors.warning,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: Spacing.xs),
                  Text(
                    'Conflicting edits were saved with .sync-conflict suffix. Check your Daily folder for conflict files.',
                    style: TextStyle(
                      fontSize: TypographyTokens.labelSmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                  SizedBox(height: Spacing.sm),
                  // Show conflict file list (truncated)
                  ...syncState.unresolvedConflicts.take(3).map((conflict) => Padding(
                    padding: EdgeInsets.only(top: Spacing.xs),
                    child: Row(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 12,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                        SizedBox(width: Spacing.xs),
                        Expanded(
                          child: Text(
                            conflict.split('/').last,
                            style: TextStyle(
                              fontSize: TypographyTokens.labelSmall,
                              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  )),
                  if (syncState.unresolvedConflicts.length > 3)
                    Padding(
                      padding: EdgeInsets.only(top: Spacing.xs),
                      child: Text(
                        '+${syncState.unresolvedConflicts.length - 3} more',
                        style: TextStyle(
                          fontSize: TypographyTokens.labelSmall,
                          fontStyle: FontStyle.italic,
                          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(height: Spacing.md),
          ],

          // Sync button
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: syncState.isSyncing
                  ? null
                  : () async {
                      final result = await syncNotifier.sync(pattern: '*');
                      if (mounted && result.success) {
                        // Build message with optional conflict info
                        final mergedStr = result.merged > 0 ? ', ${result.merged} merged' : '';
                        final conflictStr = result.conflicts.isNotEmpty
                            ? ' (${result.conflicts.length} conflict${result.conflicts.length == 1 ? '' : 's'})'
                            : '';
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Synced: ${result.pushed} pushed, ${result.pulled} pulled$mergedStr$conflictStr',
                            ),
                            backgroundColor: result.conflicts.isNotEmpty
                                ? BrandColors.warning
                                : BrandColors.success,
                          ),
                        );
                      }
                    },
              icon: syncState.isSyncing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(BrandColors.softWhite),
                      ),
                    )
                  : const Icon(Icons.sync, size: 18),
              label: Text(syncState.isSyncing ? 'Syncing...' : 'Sync Now'),
              style: FilledButton.styleFrom(
                backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatLastSync(DateTime time, SyncResult? result) {
    final now = DateTime.now();
    final diff = now.difference(time);

    String timeAgo;
    if (diff.inMinutes < 1) {
      timeAgo = 'just now';
    } else if (diff.inMinutes < 60) {
      timeAgo = '${diff.inMinutes}m ago';
    } else if (diff.inHours < 24) {
      timeAgo = '${diff.inHours}h ago';
    } else {
      timeAgo = '${diff.inDays}d ago';
    }

    if (result != null && result.success) {
      return 'Last sync: $timeAgo (↑${result.pushed} ↓${result.pulled})';
    }
    return 'Last sync: $timeAgo';
  }

  bool _isReloadingScheduler = false;
  List<Map<String, dynamic>>? _agents;
  bool _isLoadingAgents = false;
  String? _agentsError;

  Future<void> _loadAgents() async {
    setState(() {
      _isLoadingAgents = true;
      _agentsError = null;
    });

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();

      final response = await http.get(
        Uri.parse('$serverUrl/api/modules/daily/agents'),
      );

      if (mounted) {
        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          setState(() {
            _agents = List<Map<String, dynamic>>.from(data['agents'] ?? []);
            _isLoadingAgents = false;
          });
        } else {
          setState(() {
            _agentsError = 'Failed to load agents: ${response.statusCode}';
            _isLoadingAgents = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _agentsError = 'Error: $e';
          _isLoadingAgents = false;
        });
      }
    }
  }

  Future<void> _triggerAgent(String agentName) async {
    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Running $agentName...'),
          backgroundColor: BrandColors.turquoise,
        ),
      );

      final response = await http.post(
        Uri.parse('$serverUrl/api/modules/daily/agents/$agentName/run'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'force': true}),
      );

      if (mounted) {
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$agentName completed'),
              backgroundColor: BrandColors.success,
            ),
          );
          _loadAgents(); // Refresh to show updated state
        } else {
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to run $agentName: ${response.body}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  Future<void> _resetAgent(String agentName) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Reset $agentName?'),
        content: const Text(
          'This will clear the agent\'s conversation history. '
          'The next run will start fresh without any previous context.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();

      final response = await http.post(
        Uri.parse('$serverUrl/api/modules/daily/agents/$agentName/reset'),
      );

      if (mounted) {
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$agentName reset - next run will start fresh'),
              backgroundColor: BrandColors.success,
            ),
          );
          _loadAgents(); // Refresh to show updated state
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to reset: ${response.body}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    }
  }

  void _viewAgentTranscript(String agentName, String displayName) {
    // Navigate to the existing CuratorLogScreen which handles transcript display properly
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CuratorLogScreen(
          agentName: agentName,
          displayName: displayName,
        ),
      ),
    );
  }

  Future<void> _reloadScheduler() async {
    setState(() => _isReloadingScheduler = true);

    try {
      final featureFlags = ref.read(featureFlagsServiceProvider);
      final serverUrl = await featureFlags.getAiServerUrl();

      final response = await http.post(
        Uri.parse('$serverUrl/api/scheduler/reload'),
      );

      if (mounted) {
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Scheduler reloaded - agents rescanned'),
              backgroundColor: BrandColors.success,
            ),
          );
          // Refresh agents list
          _loadAgents();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to reload: ${response.body}'),
              backgroundColor: BrandColors.error,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: BrandColors.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isReloadingScheduler = false);
      }
    }
  }

  Widget _buildSchedulerSection(bool isDark) {
    // Load agents on first render if not loaded
    if (_agents == null && !_isLoadingAgents && _agentsError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAgents());
    }

    return _SettingsCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.schedule,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  'Daily Agents',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: TypographyTokens.bodyLarge,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
              // Reload button (compact)
              IconButton(
                onPressed: _isReloadingScheduler ? null : () async {
                  await _reloadScheduler();
                },
                icon: _isReloadingScheduler
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isDark ? BrandColors.nightForest : BrandColors.forest,
                          ),
                        ),
                      )
                    : Icon(
                        Icons.refresh,
                        size: 20,
                        color: isDark ? BrandColors.nightForest : BrandColors.forest,
                      ),
                tooltip: 'Reload scheduler',
              ),
            ],
          ),
          SizedBox(height: Spacing.sm),
          Text(
            'Scheduled agents run automatically. Reload after adding or editing agents.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.lg),

          // Agent list
          if (_isLoadingAgents)
            Center(
              child: Padding(
                padding: EdgeInsets.all(Spacing.lg),
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isDark ? BrandColors.nightForest : BrandColors.forest,
                  ),
                ),
              ),
            )
          else if (_agentsError != null)
            Container(
              padding: EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(
                color: BrandColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: BrandColors.error),
                  SizedBox(width: Spacing.xs),
                  Expanded(
                    child: Text(
                      _agentsError!,
                      style: TextStyle(
                        fontSize: TypographyTokens.bodySmall,
                        color: BrandColors.error,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loadAgents,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          else if (_agents == null || _agents!.isEmpty)
            Container(
              padding: EdgeInsets.all(Spacing.md),
              decoration: BoxDecoration(
                color: (isDark ? BrandColors.nightSurface : BrandColors.cream),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                'No agents found in Daily/.agents/',
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            )
          else
            ..._agents!.map((agent) => _buildAgentCard(agent, isDark)),
        ],
      ),
    );
  }

  Widget _buildAgentCard(Map<String, dynamic> agent, bool isDark) {
    final name = agent['name'] as String? ?? 'unknown';
    final displayName = agent['displayName'] as String? ?? name;
    final description = agent['description'] as String? ?? '';
    final schedule = agent['schedule'] as Map<String, dynamic>? ?? {};
    final state = agent['state'] as Map<String, dynamic>? ?? {};
    final scheduleTime = schedule['time'] as String? ?? '--:--';
    final scheduleEnabled = schedule['enabled'] as bool? ?? true;
    final lastRunAt = state['lastRunAt'] as String?;
    final runCount = state['runCount'] as int? ?? 0;

    // Format last run time
    String lastRunDisplay = 'Never run';
    if (lastRunAt != null) {
      try {
        final dt = DateTime.parse(lastRunAt);
        final now = DateTime.now();
        final diff = now.difference(dt);
        if (diff.inMinutes < 60) {
          lastRunDisplay = '${diff.inMinutes}m ago';
        } else if (diff.inHours < 24) {
          lastRunDisplay = '${diff.inHours}h ago';
        } else {
          lastRunDisplay = '${diff.inDays}d ago';
        }
      } catch (_) {
        lastRunDisplay = 'Unknown';
      }
    }

    return Container(
      margin: EdgeInsets.only(bottom: Spacing.md),
      padding: EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: (isDark ? BrandColors.nightSurface : BrandColors.cream),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(
          color: (isDark ? BrandColors.nightForest : BrandColors.forest)
              .withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: name + schedule time
          Row(
            children: [
              Expanded(
                child: Text(
                  displayName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: TypographyTokens.bodyMedium,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Spacing.sm,
                  vertical: Spacing.xs,
                ),
                decoration: BoxDecoration(
                  color: scheduleEnabled
                      ? (isDark ? BrandColors.nightForest : BrandColors.forest)
                          .withValues(alpha: 0.15)
                      : (isDark ? BrandColors.nightSurface : BrandColors.cream),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      scheduleEnabled ? Icons.schedule : Icons.schedule_outlined,
                      size: 12,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                    SizedBox(width: Spacing.xs),
                    Text(
                      scheduleTime,
                      style: TextStyle(
                        fontSize: TypographyTokens.labelSmall,
                        color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Description (if any)
          if (description.isNotEmpty) ...[
            SizedBox(height: Spacing.xs),
            Text(
              description,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],

          // Stats row: last run + run count
          SizedBox(height: Spacing.sm),
          Row(
            children: [
              Icon(
                Icons.history,
                size: 12,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
              SizedBox(width: Spacing.xs),
              Text(
                '$lastRunDisplay ($runCount runs)',
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                ),
              ),
            ],
          ),

          // Action buttons
          SizedBox(height: Spacing.sm),
          Row(
            children: [
              // Run now button
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _triggerAgent(name),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('Run'),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                    textStyle: TextStyle(fontSize: TypographyTokens.labelSmall),
                  ),
                ),
              ),
              SizedBox(width: Spacing.sm),
              // History button
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _viewAgentTranscript(name, displayName),
                  icon: const Icon(Icons.chat_bubble_outline, size: 16),
                  label: const Text('History'),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                    textStyle: TextStyle(fontSize: TypographyTokens.labelSmall),
                  ),
                ),
              ),
              SizedBox(width: Spacing.sm),
              // Reset button
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _resetAgent(name),
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label: const Text('Reset'),
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                    textStyle: TextStyle(fontSize: TypographyTokens.labelSmall),
                    foregroundColor: BrandColors.warning,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAboutSection(bool isDark) {
    return _SettingsCard(
      isDark: isDark,
      child: Column(
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
          _AboutRow(label: 'Version', value: '0.1.0', isDark: isDark),
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
        ],
      ),
    );
  }
}

/// Card container for settings sections
class _SettingsCard extends StatelessWidget {
  final bool isDark;
  final Widget child;

  const _SettingsCard({required this.isDark, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        borderRadius: BorderRadius.circular(Radii.md),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
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

/// Row showing module folder info within the vault
class _FolderInfoRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String folderName;
  final String description;
  final bool isDark;

  const _FolderInfoRow({
    required this.icon,
    required this.iconColor,
    required this.folderName,
    required this.description,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: iconColor),
        SizedBox(width: Spacing.xs),
        Text(
          folderName,
          style: TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.w500,
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        Text(
          '/',
          style: TextStyle(
            fontSize: TypographyTokens.bodySmall,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
        ),
        SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            description,
            style: TextStyle(
              fontSize: TypographyTokens.labelSmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Option card for server mode selection
class _ServerModeOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isSelected;
  final bool isDark;
  final VoidCallback? onTap;

  const _ServerModeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isSelected,
    required this.isDark,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Container(
        padding: EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: isSelected
              ? accentColor.withValues(alpha: 0.15)
              : (isDark ? BrandColors.nightSurface : BrandColors.stone).withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: isSelected
                ? accentColor
                : (isDark ? BrandColors.nightSurface : BrandColors.stone),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: EdgeInsets.all(Spacing.sm),
              decoration: BoxDecoration(
                color: isSelected
                    ? accentColor.withValues(alpha: 0.2)
                    : (isDark ? BrandColors.nightSurface : BrandColors.stone),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(
                icon,
                size: 20,
                color: isSelected
                    ? accentColor
                    : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
              ),
            ),
            SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: TypographyTokens.bodyMedium,
                      color: isSelected
                          ? (isDark ? BrandColors.nightText : BrandColors.charcoal)
                          : (isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood),
                    ),
                  ),
                  SizedBox(height: Spacing.xs),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: TypographyTokens.bodySmall,
                      color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(
                Icons.check_circle,
                size: 20,
                color: accentColor,
              ),
          ],
        ),
      ),
    );
  }
}
