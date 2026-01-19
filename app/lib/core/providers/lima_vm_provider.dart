import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/lima_vm_service.dart';

/// Provider for the Lima VM service singleton
final limaVMServiceProvider = Provider<LimaVMService>((ref) {
  final service = LimaVMService();
  ref.onDispose(() => service.dispose());
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

/// Provider to check if server in VM is healthy
final isLimaServerHealthyProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(limaVMServiceProvider);
  return service.isServerHealthy();
});
