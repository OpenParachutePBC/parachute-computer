import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/chat_import_service.dart';
import 'package:parachute/core/services/file_system_service.dart';
import 'package:parachute/core/providers/file_system_provider.dart';

// ============================================================
// Import Service
// ============================================================

/// Provider for the chat import service
///
/// Used to import chat history from ChatGPT, Claude, and other sources.
final chatImportServiceProvider = Provider<ChatImportService>((ref) {
  final fileSystemService = ref.watch(fileSystemServiceProvider);
  return ChatImportService(fileSystemService);
});
