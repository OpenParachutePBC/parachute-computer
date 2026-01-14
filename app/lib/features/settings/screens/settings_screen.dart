import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/services/backend_health_service.dart';
import 'package:parachute/features/daily/journal/providers/journal_providers.dart';
import '../widgets/omi_device_section.dart';
import '../widgets/api_key_section.dart';
import '../widgets/bundled_server_section.dart';

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
          // Bundled Server Section (desktop only - shows when server is bundled)
          if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) ...[
            _SettingsCard(
              isDark: isDark,
              child: const BundledServerSection(),
            ),
            SizedBox(height: Spacing.xl),
          ],

          // Server Connection Section
          _buildServerSection(isDark),

          SizedBox(height: Spacing.xl),

          // Parachute Vault Section (unified storage)
          _buildVaultSection(isDark, showChatFolder),

          // API Keys Section (for multi-device auth)
          if (showChatFolder) ...[
            SizedBox(height: Spacing.xl),
            _SettingsCard(
              isDark: isDark,
              child: const ApiKeySection(),
            ),
          ],

          // Omi Device Section (iOS/Android only)
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

          _AboutRow(label: 'App', value: 'Parachute', isDark: isDark),
          _AboutRow(label: 'Version', value: '0.1.0', isDark: isDark),
          _AboutRow(label: 'Company', value: 'Open Parachute, PBC', isDark: isDark),

          SizedBox(height: Spacing.lg),
          Text(
            'Open & interoperable extended mind technology',
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
