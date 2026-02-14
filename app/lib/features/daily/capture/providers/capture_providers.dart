import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:parachute/core/services/file_system_service.dart';
import '../services/photo_capture_service.dart';

/// Provider for the FileSystemService singleton
final fileSystemServiceProvider = Provider<FileSystemService>((ref) {
  return FileSystemService.daily();
});

/// Provider for the photo capture service.
final photoCaptureServiceProvider = Provider<PhotoCaptureService>((ref) {
  final fileSystem = ref.watch(fileSystemServiceProvider);
  return PhotoCaptureService(fileSystem);
});
