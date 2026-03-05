import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;
import 'package:parachute/core/theme/design_tokens.dart';
import 'package:parachute/features/vault/models/file_item.dart';
import '../providers/container_files_providers.dart';
import 'container_file_viewer_screen.dart';

/// Full-screen file browser for a container env's home directory.
///
/// Provides listing, navigation, upload, download/share, mkdir, and delete.
/// Entry point: pushed from [ChatScreen] when the active session has a [projectId].
class ContainerFileBrowserScreen extends ConsumerStatefulWidget {
  final String slug;
  final String displayName;

  const ContainerFileBrowserScreen({
    super.key,
    required this.slug,
    required this.displayName,
  });

  @override
  ConsumerState<ContainerFileBrowserScreen> createState() =>
      _ContainerFileBrowserScreenState();
}

class _ContainerFileBrowserScreenState
    extends ConsumerState<ContainerFileBrowserScreen> {
  bool _uploading = false;

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _navigateInto(String path) {
    ref.read(containerFilesPathProvider(widget.slug).notifier).state = path;
  }

  void _navigateBack() {
    final current = ref.read(containerFilesPathProvider(widget.slug));
    if (current.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final lastSlash = current.lastIndexOf('/');
    final parent = lastSlash <= 0 ? '' : current.substring(0, lastSlash);
    ref.read(containerFilesPathProvider(widget.slug).notifier).state = parent;
  }

  void _refresh() => ref.invalidate(containerFilesListProvider(widget.slug));

  // ---------------------------------------------------------------------------
  // Upload
  // ---------------------------------------------------------------------------

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final currentPath = ref.read(containerFilesPathProvider(widget.slug));
    setState(() => _uploading = true);

    try {
      final service = ref.read(containerFilesServiceProvider);
      final results = await service.uploadFiles(
        widget.slug,
        result.files,
        uploadPath: currentPath,
      );

      if (!mounted) return;

      final failed = results.where((r) => !r.success).toList();
      if (failed.isNotEmpty) {
        _showSnackBar(
          'Uploaded ${results.length - failed.length} file(s); '
          '${failed.length} failed: ${failed.map((r) => r.message).join(', ')}',
          isError: true,
        );
      } else {
        _showSnackBar('Uploaded ${results.length} file(s)');
      }
    } catch (e) {
      if (mounted) _showSnackBar('Upload failed: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
        _refresh();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Make directory
  // ---------------------------------------------------------------------------

  Future<void> _showMkdirDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final controller = TextEditingController();

    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor:
            isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        title: Text(
          'New Folder',
          style: TextStyle(
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
          decoration: InputDecoration(
            hintText: 'Folder name',
            hintStyle: TextStyle(
              color: isDark
                  ? BrandColors.nightTextSecondary
                  : BrandColors.driftwood,
            ),
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: isDark
                    ? BrandColors.nightTextSecondary
                    : BrandColors.driftwood,
              ),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name == null || name.isEmpty || !mounted) return;

    try {
      final currentPath = ref.read(containerFilesPathProvider(widget.slug));
      final newPath =
          currentPath.isEmpty ? name : '$currentPath/$name';
      final service = ref.read(containerFilesServiceProvider);
      await service.mkdir(widget.slug, newPath);
      if (!mounted) return;
      _showSnackBar('Folder "$name" created');
      _refresh();
    } catch (e) {
      if (mounted) _showSnackBar('Failed to create folder: $e', isError: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------------------

  Future<void> _confirmDelete(FileItem item) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDir = item.isFolder;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor:
            isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
        title: Text(
          'Delete ${isDir ? 'folder' : 'file'}?',
          style: TextStyle(
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        content: Text(
          isDir
              ? 'Delete "${item.name}" and all its contents? This cannot be undone.'
              : 'Delete "${item.name}"? This cannot be undone.',
          style: TextStyle(
            color: isDark ? BrandColors.nightText : BrandColors.charcoal,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: BrandColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final service = ref.read(containerFilesServiceProvider);
      await service.delete(widget.slug, item.path);
      if (!mounted) return;
      _showSnackBar('Deleted "${item.name}"');
      _refresh();
    } catch (e) {
      if (mounted) _showSnackBar('Delete failed: $e', isError: true);
    }
  }

  // ---------------------------------------------------------------------------
  // Download / Share
  // ---------------------------------------------------------------------------

  Future<void> _downloadAndShare(FileItem item) async {
    try {
      _showSnackBar('Downloading…');
      final service = ref.read(containerFilesServiceProvider);
      final bytes = await service.downloadFile(widget.slug, item.path);
      if (!mounted) return;
      await _shareBytes(bytes, item.name);
    } catch (e) {
      if (mounted) _showSnackBar('Download failed: $e', isError: true);
    }
  }

  Future<void> _shareBytes(Uint8List bytes, String fileName) async {
    final tmpDir = await getTemporaryDirectory();
    final tmpFile = File(p.join(tmpDir.path, fileName));
    await tmpFile.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(tmpFile.path)]);
  }

  // ---------------------------------------------------------------------------
  // Image preview
  // ---------------------------------------------------------------------------

  Future<void> _showImagePreview(FileItem item) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Uint8List? bytes;
    try {
      final service = ref.read(containerFilesServiceProvider);
      bytes = await service.downloadFile(widget.slug, item.path);
    } catch (e) {
      if (mounted) _showSnackBar('Failed to load image: $e', isError: true);
      return;
    }
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.md),
                child: Image.memory(bytes!, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  icon: Icon(Icons.share, color: isDark ? BrandColors.nightText : BrandColors.softWhite),
                  label: Text(
                    'Share',
                    style: TextStyle(color: isDark ? BrandColors.nightText : BrandColors.softWhite),
                  ),
                  onPressed: () async {
                    Navigator.pop(context);
                    try {
                      await _shareBytes(bytes!, item.name);
                    } catch (e) {
                      if (mounted) _showSnackBar('Share failed: $e', isError: true);
                    }
                  },
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Close',
                    style: TextStyle(
                      color: isDark
                          ? BrandColors.nightTextSecondary
                          : BrandColors.softWhite.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Item interactions
  // ---------------------------------------------------------------------------

  void _onItemTap(FileItem item) {
    if (item.isFolder) {
      _navigateInto(item.path);
    } else if (item.isMarkdown || item.isText) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ContainerFileViewerScreen(
            slug: widget.slug,
            file: item,
          ),
        ),
      );
    } else if (item.isImage) {
      _showImagePreview(item);
    } else {
      _showFileContextMenu(item);
    }
  }

  void _showFileContextMenu(FileItem item) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor:
          isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: Spacing.sm),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? BrandColors.charcoal : BrandColors.stone,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
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
            if (item.isMarkdown || item.isText || item.isImage) ...[
              ListTile(
                leading: Icon(
                  item.isImage ? Icons.image_outlined : Icons.text_snippet,
                  color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
                ),
                title: Text(
                  item.isImage ? 'Preview' : 'View',
                  style: TextStyle(
                    color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                  ),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _onItemTap(item);
                },
              ),
            ],
            ListTile(
              leading: Icon(
                Icons.download_outlined,
                color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
              ),
              title: Text(
                'Download / Share',
                style: TextStyle(
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
              ),
              onTap: () {
                Navigator.pop(context);
                _downloadAndShare(item);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: BrandColors.error),
              title: Text(
                'Delete',
                style: TextStyle(color: BrandColors.error),
              ),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(item);
              },
            ),
            const SizedBox(height: Spacing.sm),
          ],
        ),
      ),
    );
  }

  void _showFolderContextMenu(FileItem folder) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor:
          isDark ? BrandColors.nightSurfaceElevated : BrandColors.softWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.lg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: Spacing.sm),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? BrandColors.charcoal : BrandColors.stone,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: Text(
                folder.name,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: isDark ? BrandColors.nightText : BrandColors.charcoal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.delete_outline, color: BrandColors.error),
              title: Text('Delete folder', style: TextStyle(color: BrandColors.error)),
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(folder);
              },
            ),
            const SizedBox(height: Spacing.sm),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? BrandColors.error : null,
    ));
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final slug = widget.slug;
    final currentPath = ref.watch(containerFilesPathProvider(slug));
    final showHidden = ref.watch(containerFilesShowHiddenProvider(slug));
    final filesAsync = ref.watch(containerFilesListProvider(slug));

    final isAtRoot = currentPath.isEmpty;
    final folderName = isAtRoot
        ? widget.displayName
        : currentPath.split('/').last;
    final breadcrumb = isAtRoot
        ? '~/'
        : '~/${currentPath.replaceAll('/', ' / ')}';

    return PopScope(
      canPop: isAtRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !isAtRoot) _navigateBack();
      },
      child: Scaffold(
        backgroundColor:
            isDark ? BrandColors.nightSurface : BrandColors.cream,
        appBar: AppBar(
          backgroundColor:
              isDark ? BrandColors.nightSurface : BrandColors.cream,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
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
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                breadcrumb,
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
                showHidden ? Icons.visibility : Icons.visibility_off,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
              onPressed: () => ref
                  .read(containerFilesShowHiddenProvider(slug).notifier)
                  .state = !showHidden,
              tooltip: showHidden ? 'Hide hidden files' : 'Show hidden files',
            ),
            IconButton(
              icon: Icon(
                Icons.create_new_folder_outlined,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
              onPressed: _showMkdirDialog,
              tooltip: 'New folder',
            ),
            IconButton(
              icon: Icon(
                Icons.upload_file_outlined,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
              onPressed: _uploading ? null : _pickAndUpload,
              tooltip: 'Upload files',
            ),
            IconButton(
              icon: Icon(
                Icons.refresh,
                color: isDark ? BrandColors.nightText : BrandColors.charcoal,
              ),
              onPressed: _refresh,
              tooltip: 'Refresh',
            ),
          ],
          bottom: _uploading
              ? const PreferredSize(
                  preferredSize: Size.fromHeight(2),
                  child: LinearProgressIndicator(),
                )
              : null,
        ),
        body: filesAsync.when(
          data: (items) => items.isEmpty
              ? _buildEmptyState(isDark)
              : RefreshIndicator(
                  onRefresh: () async => _refresh(),
                  child: ListView.builder(
                    padding: EdgeInsets.symmetric(vertical: Spacing.sm),
                    itemCount: items.length,
                    itemBuilder: (context, index) =>
                        _buildItem(items[index], isDark),
                  ),
                ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _buildErrorState(isDark, error.toString()),
        ),
      ),
    );
  }

  Widget _buildItem(FileItem item, bool isDark) {
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
      onLongPress: item.isFolder
          ? () => _showFolderContextMenu(item)
          : () => _showFileContextMenu(item),
    );
  }

  Widget _buildItemIcon(FileItem item, bool isDark) {
    IconData icon;
    Color color;

    switch (item.type) {
      case FileItemType.folder:
        icon = Icons.folder;
        color = isDark ? BrandColors.nightForest : BrandColors.forest;
      case FileItemType.markdown:
        icon = Icons.description;
        color =
            isDark ? BrandColors.nightTurquoise : BrandColors.turquoiseDeep;
      case FileItemType.text:
        icon = Icons.code;
        color = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
      case FileItemType.audio:
        icon = Icons.audio_file;
        color = isDark
            ? BrandColors.nightForest.withValues(alpha: 0.8)
            : BrandColors.forestLight;
      case FileItemType.image:
        icon = Icons.image_outlined;
        color = isDark ? BrandColors.nightTurquoise : BrandColors.turquoise;
      case FileItemType.other:
        icon = Icons.insert_drive_file;
        color =
            isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood;
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
          SizedBox(height: Spacing.sm),
          Text(
            'Upload files or create a folder to get started.',
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
            color: isDark
                ? BrandColors.nightTextSecondary
                : BrandColors.driftwood,
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
          FilledButton(onPressed: _refresh, child: const Text('Retry')),
        ],
      ),
    );
  }
}
