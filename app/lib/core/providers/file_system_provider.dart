import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/file_system_service.dart';

/// Legacy provider name for backwards compatibility
/// Points to Daily module service
final fileSystemServiceProvider = Provider<FileSystemService>((ref) {
  return FileSystemService.daily();
});

/// Provider for Daily module file system service
final dailyFileSystemServiceProvider = Provider<FileSystemService>((ref) {
  return FileSystemService.daily();
});

/// Provider for Chat module file system service
final chatFileSystemServiceProvider = Provider<FileSystemService>((ref) {
  return FileSystemService.chat();
});

/// FutureProvider for Daily root path
final dailyRootPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(dailyFileSystemServiceProvider);
  return service.getRootPath();
});

/// FutureProvider for Chat root path
final chatRootPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(chatFileSystemServiceProvider);
  return service.getRootPath();
});

/// FutureProvider for Daily journals path
final dailyJournalsPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(dailyFileSystemServiceProvider);
  return service.getFolderPath('journals');
});

/// FutureProvider for Daily assets path
final dailyAssetsPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(dailyFileSystemServiceProvider);
  return service.getFolderPath('assets');
});

/// FutureProvider for Daily reflections path
final dailyReflectionsPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(dailyFileSystemServiceProvider);
  return service.getFolderPath('reflections');
});

/// FutureProvider for Chat sessions path
final chatSessionsPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(chatFileSystemServiceProvider);
  return service.getFolderPath('sessions');
});

/// FutureProvider for Chat contexts path
final chatContextsPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(chatFileSystemServiceProvider);
  return service.getFolderPath('contexts');
});

/// Check if Daily vault is configured
final isDailyConfiguredProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(dailyFileSystemServiceProvider);
  return service.isUserConfigured();
});

/// Check if Chat vault is configured
final isChatConfiguredProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(chatFileSystemServiceProvider);
  return service.isUserConfigured();
});
