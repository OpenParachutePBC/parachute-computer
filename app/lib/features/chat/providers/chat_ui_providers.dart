import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/vault_entry.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

// ============================================================
// Vault Browsing
// ============================================================

/// Provider for browsing vault directories
///
/// Use with .family to specify the path:
/// - ref.watch(vaultDirectoryProvider('')) - vault root
/// - ref.watch(vaultDirectoryProvider('Projects')) - Projects folder
/// - ref.watch(vaultDirectoryProvider('Projects/myapp')) - specific project
final vaultDirectoryProvider = FutureProvider.autoDispose.family<List<VaultEntry>, String>((ref, path) async {
  final service = ref.watch(chatServiceProvider);
  return service.listDirectory(path: path);
});

/// Provider for the current working directory path being browsed
final currentBrowsePathProvider = StateProvider<String>((ref) => '');

/// Provider for the selected working directory for new chats
///
/// This is the working directory that will be used when starting a new chat.
/// null means use the default (Chat/).
final selectedWorkingDirectoryProvider = StateProvider<String?>((ref) => null);
