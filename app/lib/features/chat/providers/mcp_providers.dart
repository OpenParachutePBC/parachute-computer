import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/core/providers/connectivity_provider.dart'
    show isServerAvailableProvider;
import '../models/mcp_server_info.dart';
import '../models/mcp_tool.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Provider that fetches configured MCP servers from the server.
/// Returns empty list if offline to avoid timeout.
final mcpServersProvider =
    FutureProvider.autoDispose<List<McpServerInfo>>((ref) async {
  // Check connectivity before API call — avoid timeout if offline
  final isAvailable = ref.watch(isServerAvailableProvider);
  if (!isAvailable) {
    return [];
  }

  final service = ref.watch(chatServiceProvider);
  return service.getMcpServers();
});

/// Provider that discovers tools exposed by an MCP server.
/// Returns empty list if offline to avoid timeout.
final mcpToolsProvider =
    FutureProvider.autoDispose.family<List<McpTool>, String>((ref, name) async {
  // Check connectivity before API call — avoid timeout if offline
  final isAvailable = ref.watch(isServerAvailableProvider);
  if (!isAvailable) {
    return [];
  }

  final service = ref.watch(chatServiceProvider);
  return service.getMcpTools(name);
});
