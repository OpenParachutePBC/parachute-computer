import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Stub vision service provider
/// TODO: Migrate full vision service from Daily app when enabling OCR
final visionServiceProvider = Provider<dynamic>((ref) => null);

/// Status of the vision service
enum VisionServiceStatus {
  /// Vision service is ready to use
  ready,

  /// Vision service is not available (e.g., desktop without OCR)
  notAvailable,

  /// Error occurred while checking status
  error,
}

/// State for vision service status
class VisionStatusState {
  final VisionServiceStatus status;
  final bool isReady;
  final bool isProcessing;
  final String? error;

  const VisionStatusState({
    this.status = VisionServiceStatus.notAvailable,
    this.isReady = false,
    this.isProcessing = false,
    this.error,
  });

  VisionStatusState copyWith({
    VisionServiceStatus? status,
    bool? isReady,
    bool? isProcessing,
    String? error,
  }) {
    return VisionStatusState(
      status: status ?? this.status,
      isReady: isReady ?? this.isReady,
      isProcessing: isProcessing ?? this.isProcessing,
      error: error,
    );
  }
}

/// Provider for vision service status
final visionStatusProvider = StateProvider<VisionStatusState>((ref) {
  return const VisionStatusState();
});

/// Provider to check if vision (OCR) is available on this platform
final visionAvailableProvider = Provider<bool>((ref) {
  // ML Kit is available on mobile only
  return Platform.isAndroid || Platform.isIOS;
});
