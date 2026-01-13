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
import '../widgets/omi_device_section.dart';

/// Unified Settings screen for Parachute
///
/// Sections:
/// - Server Connection (enables Chat/Vault)
/// - Daily Storage
/// - Chat Storage (when server enabled)
/// - About
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _serverUrlController = TextEditingController();
  bool _isLoading = true;
  String _dailyPath = '';
  String _chatPath = '';

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

    // Load paths
    final dailyService = ref.read(dailyFileSystemServiceProvider);
    await dailyService.initialize();
    _dailyPath = await dailyService.getRootPathDisplay();

    final chatService = ref.read(chatFileSystemServiceProvider);
    await chatService.initialize();
    _chatPath = await chatService.getRootPathDisplay();

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

  Future<void> _changeDailyFolder() async {
    final service = ref.read(dailyFileSystemServiceProvider);

    // Handle Android permissions
    if (Platform.isAndroid) {
      final hasPermission = await service.hasStoragePermission();
      if (!hasPermission) {
        final granted = await service.requestStoragePermission();
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

    final selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Daily Folder',
    );

    if (selectedDirectory != null) {
      final success = await service.setRootPath(selectedDirectory, migrateFiles: false);
      if (success) {
        final displayPath = await service.getRootPathDisplay();
        setState(() => _dailyPath = displayPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Daily folder: $displayPath'),
              backgroundColor: BrandColors.success,
            ),
          );
        }
      }
    }
  }

  Future<void> _changeChatFolder() async {
    final service = ref.read(chatFileSystemServiceProvider);

    // Handle Android permissions
    if (Platform.isAndroid) {
      final hasPermission = await service.hasStoragePermission();
      if (!hasPermission) {
        final granted = await service.requestStoragePermission();
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

    final selectedDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Chat Folder',
    );

    if (selectedDirectory != null) {
      final success = await service.setRootPath(selectedDirectory, migrateFiles: false);
      if (success) {
        final displayPath = await service.getRootPathDisplay();
        setState(() => _chatPath = displayPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Chat folder: $displayPath'),
              backgroundColor: BrandColors.success,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final appMode = ref.watch(appModeProvider);
    final showChatSettings = appMode == AppMode.full;

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
          // Server Connection Section
          _buildServerSection(isDark),

          SizedBox(height: Spacing.xl),

          // Daily Storage Section
          _buildDailyStorageSection(isDark),

          // Omi Device Section (iOS/Android only)
          if (Platform.isIOS || Platform.isAndroid) ...[
            SizedBox(height: Spacing.xl),
            _SettingsCard(
              isDark: isDark,
              child: const OmiDeviceSection(),
            ),
          ],

          // Chat Storage Section (only when server configured)
          if (showChatSettings) ...[
            SizedBox(height: Spacing.xl),
            _buildChatStorageSection(isDark),
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

  Widget _buildDailyStorageSection(bool isDark) {
    return _SettingsCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.wb_sunny,
                color: isDark ? BrandColors.nightForest : BrandColors.forest,
              ),
              SizedBox(width: Spacing.sm),
              Text(
                'Daily Storage',
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
            'Your journal entries, voice recordings, and reflections are stored here.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.lg),

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
                    _dailyPath,
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
          SizedBox(height: Spacing.lg),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _changeDailyFolder,
                  icon: const Icon(Icons.folder, size: 18),
                  label: const Text('Change'),
                ),
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _openFolder(_dailyPath),
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

  Widget _buildChatStorageSection(bool isDark) {
    return _SettingsCard(
      isDark: isDark,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.chat_bubble,
                color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
              SizedBox(width: Spacing.sm),
              Text(
                'Chat Storage',
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
            'AI chat sessions and generated content are stored here.',
            style: TextStyle(
              fontSize: TypographyTokens.bodySmall,
              color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
            ),
          ),
          SizedBox(height: Spacing.lg),

          Container(
            padding: EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: (isDark ? BrandColors.nightTurquoise : BrandColors.turquoise)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_open, size: 20),
                SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    _chatPath,
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
          SizedBox(height: Spacing.lg),

          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _changeChatFolder,
                  icon: const Icon(Icons.folder, size: 18),
                  label: const Text('Change'),
                ),
              ),
              SizedBox(width: Spacing.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _openFolder(_chatPath),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open'),
                  style: FilledButton.styleFrom(
                    backgroundColor: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
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
