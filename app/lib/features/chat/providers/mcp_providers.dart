import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mcp_server_info.dart';
import '../models/mcp_tool.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Provider that fetches configured MCP servers from the server.
final mcpServersProvider =
    FutureProvider.autoDispose<List<McpServerInfo>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  return service.getMcpServers();
});

/// Provider that discovers tools exposed by an MCP server.
final mcpToolsProvider =
    FutureProvider.autoDispose.family<List<McpTool>, String>((ref, name) async {
  final service = ref.watch(chatServiceProvider);
  return service.getMcpTools(name);
});
