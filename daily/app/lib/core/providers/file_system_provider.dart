import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/file_system_service.dart';

/// Provider family for FileSystemService instances by module type
///
/// This replaces the static singleton pattern with proper dependency injection.
/// Usage: ref.watch(fileSystemServiceFamilyProvider(ModuleType.daily))
final fileSystemServiceFamilyProvider = Provider.family<FileSystemService, ModuleType>((ref, moduleType) {
  return FileSystemService(moduleType);
});

/// Legacy provider name for backwards compatibility
/// Points to Daily module service
final fileSystemServiceProvider = Provider<FileSystemService>((ref) {
  return ref.watch(fileSystemServiceFamilyProvider(ModuleType.daily));
});

/// Provider for Daily module file system service
final dailyFileSystemServiceProvider = Provider<FileSystemService>((ref) {
  return ref.watch(fileSystemServiceFamilyProvider(ModuleType.daily));
});

/// FutureProvider for Daily root path
final dailyRootPathProvider = FutureProvider<String>((ref) async {
  final service = ref.watch(dailyFileSystemServiceProvider);
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
