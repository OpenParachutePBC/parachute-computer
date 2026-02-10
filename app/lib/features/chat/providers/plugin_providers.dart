import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/plugin_info.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Provider that fetches installed plugins from the server.
final pluginsProvider = FutureProvider.autoDispose<List<PluginInfo>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  return service.getPlugins();
});
