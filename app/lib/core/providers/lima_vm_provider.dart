import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/lima_vm_service.dart';
import 'app_state_provider.dart';

/// Provider for the Lima VM service singleton
final limaVMServiceProvider = Provider<LimaVMService>((ref) {
  final service = LimaVMService();
  ref.onDispose(() => service.dispose());

  // Listen for custom base path changes
  ref.listen(customBasePathProvider, (previous, next) {
    next.whenData((customPath) {
      service.setCustomBasePath(customPath);
    });
  });

  return service;
});

/// Provider that initializes LimaVMService with custom path if set
final limaVMServiceInitializedProvider = FutureProvider<LimaVMService>((ref) async {
  final service = ref.watch(limaVMServiceProvider);

  // Get custom base path if set
  final customPath = await ref.watch(customBasePathProvider.future);
  service.setCustomBasePath(customPath);

  return service;
});

/// Provider for the current Lima VM status
final limaVMStatusProvider = StreamProvider<LimaVMStatus>((ref) {
  final service = ref.watch(limaVMServiceProvider);
  // Check initial status
  service.checkStatus();
  return service.statusStream;
});

/// Provider to check if Lima is available on this system
final isLimaAvailableProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(limaVMServiceProvider);
  return service.isLimaInstalled();
});

/// Provider to check if the VM is running
final isLimaVMRunningProvider = Provider<bool>((ref) {
  final statusAsync = ref.watch(limaVMStatusProvider);
  return statusAsync.valueOrNull == LimaVMStatus.running;
});
