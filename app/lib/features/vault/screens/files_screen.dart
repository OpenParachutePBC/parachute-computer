import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/vault/models/file_item.dart';
import 'package:parachute/features/vault/providers/file_browser_provider.dart';
import 'package:parachute/features/vault/screens/markdown_viewer_screen.dart';
import 'package:parachute/features/vault/screens/text_viewer_screen.dart';
import 'package:parachute/features/settings/screens/settings_screen.dart';

/// File browser screen for navigating the vault
class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> with WidgetsBindingObserver {
  String? _lastKnownRootPath;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize path to root on first load
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initializeOrRefresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Refresh when app comes back to foreground
      _checkForVaultChange();
    }
  }

  Future<void> _initializeOrRefresh() async {
    final service = ref.read(fileBrowserServiceProvider);
    final rootPath = await service.getInitialPath();

    // Check if widget is still mounted after async operation
    if (!mounted) return;

    _lastKnownRootPath = rootPath;

    final currentPath = ref.read(currentBrowsePathProvider);
    if (currentPath.isEmpty || !currentPath.startsWith(rootPath)) {
      ref.read(currentBrowsePathProvider.notifier).state = rootPath;
    }
  }

  Future<void> _checkForVaultChange() async {
    final service = ref.read(fileBrowserServiceProvider);
    final currentRootPath = await service.getInitialPath();

    // Check if widget is still mounted after async operation
    if (!mounted) return;

    if (_lastKnownRootPath != null && _lastKnownRootPath != currentRootPath) {
      // Vault changed, reset to new root
      _lastKnownRootPath = currentRootPath;
      ref.read(currentBrowsePathProvider.notifier).state = currentRootPath;
      ref.read(folderRefreshTriggerProvider.notifier).state++;
    }
  }

  void _navigateToFolder(String path) {
    debugPrint('[FilesScreen] Navigating to folder: "$path"');
    ref.read(currentBrowsePathProvider.notifier).state = path;
  }

  void _navigateBack() {
    final service = ref.read(fileBrowserServiceProvider);
    final currentPath = ref.read(currentBrowsePathProvider);
    final parentPath = service.getParentPath(currentPath);
    ref.read(currentBrowsePathProvider.notifier).state = parentPath;
  }

  void _onItemTap(FileItem item) {
    if (item.isFolder) {
      _navigateToFolder(item.path);
    } else if (item.isMarkdown) {
      _openMarkdownFile(item);
    } else if (item.isText) {
      _openTextFile(item);
    } else if (item.isAudio) {
      _playAudioFile(item);
    } else {
      _showFileInfo(item);
    }
  }

  void _openMarkdownFile(FileItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MarkdownViewerScreen(file: item),
      ),
    );
  }

  void _openTextFile(FileItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TextViewerScreen(file: item),
      ),
    );
  }

  void _playAudioFile(FileItem item) {
    // TODO: Play audio file
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Audio playback coming soon: ${item.name}')),
    );
  }

  void _showFileInfo(FileItem item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
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
    // Check for vault changes when manually refreshing
    _checkForVaultChange();
    ref.read(folderRefreshTriggerProvider.notifier).state++;
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
    final folderContents = ref.watch(folderContentsProvider);
    final isAtRoot = ref.watch(isAtRootProvider);
    final displayPath = ref.watch(displayPathProvider);
    final folderName = ref.watch(currentFolderNameProvider);

    return Scaffold(
      backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
      appBar: AppBar(
        backgroundColor: isDark ? BrandColors.nightSurface : BrandColors.cream,
        surfaceTintColor: Colors.transparent,
        leading: isAtRoot.when(
          data: (atRoot) => atRoot
              ? null
              : IconButton(
                  icon: Icon(
                    Icons.arrow_back,
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                  onPressed: _navigateBack,
                ),
          loading: () => null,
          error: (_, __) => null,
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
            displayPath.when(
              data: (path) => Text(
                path,
                style: TextStyle(
                  fontSize: TypographyTokens.labelSmall,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                  fontFamily: 'monospace',
                ),
                overflow: TextOverflow.ellipsis,
              ),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
          ],
        ),
        actions: [
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
        error: (error, _) => Center(
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
              Text(
                error.toString(),
                style: TextStyle(
                  fontSize: TypographyTokens.bodySmall,
                  color: isDark
                      ? BrandColors.nightTextSecondary
                      : BrandColors.driftwood,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: Spacing.lg),
              FilledButton(
                onPressed: _refresh,
                child: const Text('Retry'),
              ),
            ],
          ),
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
      onLongPress: item.isFolder ? null : () => _showFileContextMenu(item, isDark),
    );
  }

  void _showFileContextMenu(FileItem item, bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: Spacing.sm),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? BrandColors.charcoal : BrandColors.stone,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // File name header
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Text(
                item.name,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            // View as Text option
            ListTile(
              leading: Icon(
                Icons.text_snippet,
                color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
              title: Text(
                'View as Text',
                style: TextStyle(
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              subtitle: item.sizeBytes != null && item.sizeBytes! > 1024 * 1024
                  ? Text(
                      'Large file (${_formatFileSize(item.sizeBytes!)}) - may be slow',
                      style: TextStyle(
                        color: BrandColors.warning,
                        fontSize: TypographyTokens.labelSmall,
                      ),
                    )
                  : null,
              onTap: () {
                Navigator.pop(context);
                _viewAsText(item);
              },
            ),
            // File info option
            ListTile(
              leading: Icon(
                Icons.info_outline,
                color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
              ),
              title: Text(
                'File Info',
                style: TextStyle(
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _showFileInfo(item);
              },
            ),
            SizedBox(height: Spacing.md),
          ],
        ),
      ),
    );
  }

  void _viewAsText(FileItem item) {
    // Warn for very large files (> 5MB)
    if (item.sizeBytes != null && item.sizeBytes! > 5 * 1024 * 1024) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
          title: const Text('Large File Warning'),
          content: Text(
            'This file is ${_formatFileSize(item.sizeBytes!)}. Opening it may cause the app to become slow or unresponsive.\n\nDo you want to continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _openTextFile(item);
              },
              child: const Text('Open Anyway'),
            ),
          ],
        ),
      );
    } else {
      _openTextFile(item);
    }
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
