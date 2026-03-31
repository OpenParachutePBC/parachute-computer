import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/logging_service.dart';
import '../services/transcription/sherpa_onnx_isolate.dart';
import '../services/transcription/transcription_service_adapter.dart' show setGlobalSherpaIsolate;

/// Provider for the logging service
final loggingServiceProvider = Provider<LoggingService>((ref) {
  final service = LoggingService.internal();
  setGlobalLogger(service);
  ref.onDispose(() {
    service.dispose();
  });
  return service;
});

/// Provider for the Sherpa ONNX isolate transcription service
final sherpaOnnxIsolateProvider = Provider<SherpaOnnxIsolate>((ref) {
  final isolate = SherpaOnnxIsolate.internal();
  setGlobalSherpaIsolate(isolate);
  ref.onDispose(() {
    isolate.dispose();
  });
  return isolate;
});

/// Initialize global services — call once at app startup
Future<void> initializeGlobalServices(ProviderContainer container) async {
  final loggingService = container.read(loggingServiceProvider);
  await loggingService.initialize();
}
