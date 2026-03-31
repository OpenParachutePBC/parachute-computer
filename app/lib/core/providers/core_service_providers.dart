import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/logging_service.dart';
import '../services/transcription/sherpa_onnx_isolate.dart';
import '../services/transcription/transcription_service_adapter.dart' show setGlobalSherpaIsolate;
import '../../features/chat/services/background_stream_manager.dart';

/// Provider for the logging service
///
/// This replaces the singleton pattern with proper Riverpod dependency injection.
/// The service is initialized once and disposed when the app closes.
final loggingServiceProvider = Provider<LoggingService>((ref) {
  final service = LoggingService.internal();

  // Set as global instance for backward compatibility
  setGlobalLogger(service);

  // Dispose when provider is destroyed
  ref.onDispose(() {
    service.dispose();
  });

  return service;
});

/// Provider for the background stream manager
///
/// This replaces the singleton pattern with proper Riverpod dependency injection.
final backgroundStreamManagerProvider = Provider<BackgroundStreamManager>((ref) {
  return BackgroundStreamManager.internal();
});

/// Provider for the Sherpa ONNX isolate transcription service
///
/// This replaces the singleton pattern with proper Riverpod dependency injection.
final sherpaOnnxIsolateProvider = Provider<SherpaOnnxIsolate>((ref) {
  final isolate = SherpaOnnxIsolate.internal();

  // Set as global instance for backward compatibility with TranscriptionServiceAdapter
  setGlobalSherpaIsolate(isolate);

  // Dispose when provider is destroyed
  ref.onDispose(() {
    isolate.dispose();
  });

  return isolate;
});

/// Initialize global services
///
/// Call this once at app startup (in main()) to initialize the global
/// logging service instance.
Future<void> initializeGlobalServices(ProviderContainer container) async {
  // Initialize logging service
  final loggingService = container.read(loggingServiceProvider);
  await loggingService.initialize();
}
