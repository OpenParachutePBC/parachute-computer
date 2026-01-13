import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/file_system_provider.dart';
import 'package:parachute/features/vault/models/file_item.dart';
import 'package:parachute/features/vault/services/file_browser_service.dart';

/// Provider for the FileBrowserService
final fileBrowserServiceProvider = Provider<FileBrowserService>((ref) {
  final fileSystem = ref.watch(fileSystemServiceProvider);
  return FileBrowserService(fileSystem);
});

/// Provider for the current vault root path
/// This is used to detect when the vault changes
final vaultRootPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(fileBrowserServiceProvider);
  // Also watch the refresh trigger so we re-fetch when vault changes
  ref.watch(folderRefreshTriggerProvider);
  return service.getInitialPath();
});

/// Current path being browsed
/// Empty string means "not initialized yet" - will be set to root on first load
final currentBrowsePathProvider = StateProvider<String>((ref) => '');

/// Trigger to force refresh of folder contents
final folderRefreshTriggerProvider = StateProvider<int>((ref) => 0);

/// Contents of the current folder
final folderContentsProvider = FutureProvider<List<FileItem>>((ref) async {
  final service = ref.watch(fileBrowserServiceProvider);
  final path = ref.watch(currentBrowsePathProvider);
  final rootPath = await ref.watch(vaultRootPathProvider.future);

  // Watch refresh trigger to allow manual refresh
  ref.watch(folderRefreshTriggerProvider);

  debugPrint('[FileBrowser] Provider rebuild - path: "$path", rootPath: "$rootPath"');

  // If path is empty or doesn't start with current root, reset to root
  String browsePath = path;
  if (browsePath.isEmpty || !browsePath.startsWith(rootPath)) {
    debugPrint('[FileBrowser] Resetting to root - path empty: ${browsePath.isEmpty}, startsWith: ${browsePath.startsWith(rootPath)}');
    browsePath = rootPath;
    // Schedule path update for after this build
    Future.microtask(() {
      ref.read(currentBrowsePathProvider.notifier).state = rootPath;
    });
  }

  debugPrint('[FileBrowser] Listing folder: "$browsePath"');
  final items = await service.listFolder(browsePath);
  debugPrint('[FileBrowser] Found ${items.length} items');
  return items;
});

/// Whether we're at the root of the vault
final isAtRootProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(fileBrowserServiceProvider);
  final path = ref.watch(currentBrowsePathProvider);
  final rootPath = await ref.watch(vaultRootPathProvider.future);

  if (path.isEmpty) return true;
  // Also check if path equals root (handles vault changes)
  if (path == rootPath) return true;
  return service.isAtRoot(path);
});

/// Display path for the current location
final displayPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(fileBrowserServiceProvider);
  final path = ref.watch(currentBrowsePathProvider);

  if (path.isEmpty) {
    final rootPath = await service.getInitialPath();
    return service.getDisplayPath(rootPath);
  }

  return service.getDisplayPath(path);
});

/// Current folder name (for app bar title)
final currentFolderNameProvider = Provider<String>((ref) {
  final path = ref.watch(currentBrowsePathProvider);
  if (path.isEmpty) return 'Vault';
  return path.split('/').last;
});

/// Contents of the current folder with optional hidden files
/// Family provider that takes a boolean to show/hide hidden files
final folderContentsWithHiddenProvider = FutureProvider.family<List<FileItem>, bool>((ref, showHidden) async {
  final service = ref.watch(fileBrowserServiceProvider);
  final path = ref.watch(currentBrowsePathProvider);
  final rootPath = await ref.watch(vaultRootPathProvider.future);

  // Watch refresh trigger to allow manual refresh
  ref.watch(folderRefreshTriggerProvider);

  debugPrint('[FileBrowser] Provider rebuild - path: "$path", rootPath: "$rootPath", showHidden: $showHidden');

  // If path is empty or doesn't start with current root, reset to root
  String browsePath = path;
  if (browsePath.isEmpty || !browsePath.startsWith(rootPath)) {
    debugPrint('[FileBrowser] Resetting to root - path empty: ${browsePath.isEmpty}, startsWith: ${browsePath.startsWith(rootPath)}');
    browsePath = rootPath;
    // Schedule path update for after this build
    Future.microtask(() {
      ref.read(currentBrowsePathProvider.notifier).state = rootPath;
    });
  }

  debugPrint('[FileBrowser] Listing folder: "$browsePath"');
  final items = await service.listFolder(browsePath, includeHidden: showHidden);
  debugPrint('[FileBrowser] Found ${items.length} items (showHidden: $showHidden)');
  return items;
});
