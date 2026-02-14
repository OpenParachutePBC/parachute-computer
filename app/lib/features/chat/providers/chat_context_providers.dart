import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/context_file.dart';
import '../models/context_folder.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

// ============================================================
// Context Selection
// ============================================================

/// Provider for available context files
///
/// Fetches context files from Chat/contexts/ directory.
/// Returns empty list if server is unavailable (graceful degradation).
final availableContextsProvider = FutureProvider.autoDispose<List<ContextFile>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  try {
    return await service.getContexts();
  } catch (e) {
    debugPrint('[ChatProviders] Error loading contexts: $e');
    return []; // Graceful degradation - show no contexts if server unavailable
  }
});

/// Provider for selected context file paths for new chats
///
/// Default: empty list (no pre-selected contexts)
/// Paths are relative to vault (e.g., "Chat/contexts/work-context.md")
/// Users can select contexts from the new chat sheet before starting.
final selectedContextsProvider = StateProvider<List<String>>((ref) {
  return []; // Start with no contexts - user can select from available files
});

// ============================================================
// Context Folders (CLAUDE.md hierarchy)
// ============================================================

/// Provider for available context folders
///
/// Fetches folders with CLAUDE.md files that can be
/// selected as context for a session.
final contextFoldersProvider = FutureProvider.autoDispose<List<ContextFolder>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  try {
    return await service.getContextFolders();
  } catch (e) {
    debugPrint('[ChatProviders] Error loading context folders: $e');
    return []; // Graceful degradation
  }
});

/// Provider for selected context folder paths for new chats
///
/// Default: [""] to include root CLAUDE.md (Parachute context)
/// Paths are folder paths relative to vault (e.g., "Projects/parachute")
final selectedContextFoldersProvider = StateProvider<List<String>>((ref) {
  return [""]; // Default to root CLAUDE.md (Parachute context)
});

/// Provider to get context chain for selected folders
///
/// Shows all CLAUDE.md files that will be loaded, including parent chain.
/// Pass folder paths as comma-separated string (e.g., ",Projects/parachute")
/// Empty string "" represents root folder.
final contextChainProvider =
    FutureProvider.autoDispose.family<ContextChain, String>((ref, foldersParam) async {
  final service = ref.watch(chatServiceProvider);
  try {
    if (foldersParam.isEmpty) {
      return const ContextChain(files: [], totalTokens: 0);
    }
    // Split comma-separated string back to list
    final folderPaths = foldersParam.split(',');
    return await service.getContextChain(folderPaths);
  } catch (e) {
    debugPrint('[ChatProviders] Error loading context chain: $e');
    return const ContextChain(files: [], totalTokens: 0);
  }
});
