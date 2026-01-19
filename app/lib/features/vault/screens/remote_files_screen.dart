import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/core/providers/feature_flags_provider.dart';
import 'package:parachute/core/providers/app_state_provider.dart';
import 'package:parachute/features/vault/models/file_item.dart';
import 'package:parachute/features/vault/services/remote_file_browser_service.dart';
import 'package:parachute/features/vault/screens/remote_markdown_viewer_screen.dart';
import 'package:parachute/features/vault/screens/remote_text_viewer_screen.dart';
import 'package:parachute/features/settings/screens/settings_screen.dart';

/// Provider for remote file browser service
/// Watches both server URL and API key to create authenticated service
final remoteFileBrowserServiceProvider = Provider<RemoteFileBrowserService?>((ref) {
  final serverUrl = ref.watch(aiServerUrlProvider).valueOrNull;
  final apiKey = ref.watch(apiKeyProvider).valueOrNull;

  if (serverUrl == null || serverUrl.isEmpty) return null;
  return RemoteFileBrowserService(baseUrl: serverUrl, apiKey: apiKey);
});

/// Current remote browse path
final remoteCurrentPathProvider = StateProvider<String>((ref) => '');

/// Whether to show hidden files in the vault browser
final remoteShowHiddenFilesProvider = StateProvider<bool>((ref) => false);

/// Remote folder contents
final remoteFolderContentsProvider = FutureProvider<List<FileItem>>((ref) async {
  final service = ref.watch(remoteFileBrowserServiceProvider);
  if (service == null) return [];

  final path = ref.watch(remoteCurrentPathProvider);
  final includeHidden = ref.watch(remoteShowHiddenFilesProvider);
  return service.listFolder(path, includeHidden: includeHidden);
});

/// File browser screen for navigating the remote vault
class RemoteFilesScreen extends ConsumerStatefulWidget {
  const RemoteFilesScreen({super.key});

  @override
  ConsumerState<RemoteFilesScreen> createState() => _RemoteFilesScreenState();
}

class _RemoteFilesScreenState extends ConsumerState<RemoteFilesScreen> {
  void _navigateToFolder(String path) {
    ref.read(remoteCurrentPathProvider.notifier).state = path;
  }

  void _navigateBack() {
    final currentPath = ref.read(remoteCurrentPathProvider);
    final service = ref.read(remoteFileBrowserServiceProvider);
    if (service == null) return;

    final parentPath = service.getParentPath(currentPath);
    ref.read(remoteCurrentPathProvider.notifier).state = parentPath;
  }

  void _onItemTap(FileItem item) {
    if (item.isFolder) {
      _navigateToFolder(item.path);
    } else if (item.isMarkdown) {
      _openMarkdownFile(item);
    } else if (item.isText) {
      _openTextFile(item);
    } else {
      _showFileInfo(item);
    }
  }

  void _openMarkdownFile(FileItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RemoteMarkdownViewerScreen(file: item),
      ),
    );
  }

  void _openTextFile(FileItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RemoteTextViewerScreen(file: item),
      ),
    );
  }

  void _showFileInfo(FileItem item) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        title: Text(item.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Type: ${item.type.name}'),
            if (item.sizeBytes != null)
              Text('Size: ${_formatFileSize(item.sizeBytes!)}'),
            if (item.modified != null)
              Text('Modified: ${_formatDate(item.modified!)}'),
            const SizedBox(height: 8),
            Text(
              item.path,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _refresh() {
    ref.invalidate(remoteFolderContentsProvider);
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final currentPath = ref.watch(remoteCurrentPathProvider);
    final service = ref.watch(remoteFileBrowserServiceProvider);

    // Check if service is available (requires server URL)
    if (service == null) {
      return _buildNoServerState(isDark);
    }

    final folderContents = ref.watch(remoteFolderContentsProvider);
    final isAtRoot = service.isAtRoot(currentPath);
    final displayPath = service.getDisplayPath(currentPath);
    final folderName = service.getFolderName(currentPath);

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
        surfaceTintColor: Colors.transparent,
        leading: isAtRoot
            ? null
            : IconButton(
                icon: Icon(
                  Icons.arrow_back,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
                onPressed: _navigateBack,
              ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              folderName,
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                fontWeight: FontWeight.bold,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
            ),
            Text(
              displayPath,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              ref.watch(remoteShowHiddenFilesProvider)
                  ? Icons.visibility
                  : Icons.visibility_off,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
            onPressed: () {
              ref.read(remoteShowHiddenFilesProvider.notifier).state =
                  !ref.read(remoteShowHiddenFilesProvider);
            },
            tooltip: ref.watch(remoteShowHiddenFilesProvider)
                ? 'Hide hidden files'
                : 'Show hidden files',
          ),
          IconButton(
            icon: Icon(
              Icons.refresh,
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
            onPressed: _refresh,
          ),
          IconButton(
            icon: Icon(
              Icons.settings_outlined,
              color: isDark ? BrandColors.driftwood : BrandColors.charcoal,
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsScreen()),
            ),
            tooltip: 'Settings',
          ),
        ],
      ),
      body: folderContents.when(
        data: (items) => items.isEmpty
            ? _buildEmptyState(isDark)
            : RefreshIndicator(
                onRefresh: () async => _refresh(),
                child: ListView.builder(
                  padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _buildFileItem(items[index], isDark),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _buildErrorState(isDark, error.toString()),
      ),
    );
  }

  Widget _buildNoServerState(bool isDark) {
    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.cloud_off,
              size: 64,
              color: isDark
                  ? BrandColors.nightTextSecondary.withValues(alpha: 0.5)
                  : BrandColors.driftwood.withValues(alpha: 0.5),
            ),
            SizedBox(height: Spacing.lg),
            Text(
              'No server configured',
              style: TextStyle(
                fontSize: TypographyTokens.titleMedium,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
            SizedBox(height: Spacing.sm),
            Text(
              'Configure a server in Settings to browse your vault',
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_open,
            size: 64,
            color: isDark
                ? BrandColors.nightTextSecondary.withValues(alpha: 0.5)
                : BrandColors.driftwood.withValues(alpha: 0.5),
          ),
          SizedBox(height: Spacing.lg),
          Text(
            'This folder is empty',
            style: TextStyle(
              fontSize: TypographyTokens.titleMedium,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(bool isDark, String error) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.error_outline,
            size: 48,
            color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
          ),
          SizedBox(height: Spacing.md),
          Text(
            'Error loading folder',
            style: TextStyle(
              color: isDark ? BrandColors.nightText : BrandColors.charcoal,
            ),
          ),
          SizedBox(height: Spacing.sm),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Spacing.xl),
            child: Text(
              error,
              style: TextStyle(
                fontSize: TypographyTokens.bodySmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          SizedBox(height: Spacing.lg),
          FilledButton(
            onPressed: _refresh,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildFileItem(FileItem item, bool isDark) {
    return ListTile(
      leading: _buildItemIcon(item, isDark),
      title: Text(
        item.name,
        style: TextStyle(
          color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          fontWeight: item.isFolder ? FontWeight.w500 : FontWeight.normal,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: item.isFolder
          ? null
          : Text(
              item.sizeBytes != null
                  ? _formatFileSize(item.sizeBytes!)
                  : item.type.name,
              style: TextStyle(
                fontSize: TypographyTokens.labelSmall,
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
      trailing: item.isFolder
          ? Icon(
              Icons.chevron_right,
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            )
          : null,
      onTap: () => _onItemTap(item),
    );
  }

  Widget _buildItemIcon(FileItem item, bool isDark) {
    IconData icon;
    Color color;

    switch (item.type) {
      case FileItemType.folder:
        icon = Icons.folder;
        color = isDark ? BrandColors.nightForest : BrandColors.forest;
        break;
      case FileItemType.markdown:
        icon = Icons.description;
        color = isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep;
        break;
      case FileItemType.text:
        icon = Icons.code;
        color = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
        break;
      case FileItemType.audio:
        icon = Icons.audio_file;
        color = isDark
            ? BrandColors.nightForest.withValues(alpha: 0.8)
            : BrandColors.forestLight;
        break;
      case FileItemType.other:
        icon = Icons.insert_drive_file;
        color = isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
        break;
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Icon(icon, color: color, size: 22),
    );
  }
}
