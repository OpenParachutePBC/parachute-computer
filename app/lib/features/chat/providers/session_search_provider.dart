import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_session.dart';
import '../services/chat_service.dart';
import 'chat_session_providers.dart';

/// Current search query text for session list filtering.
final sessionSearchQueryProvider = StateProvider<String>((ref) => '');

/// Sessions filtered by search query.
///
/// When query is empty, delegates to chatSessionsProvider.
/// When query is non-empty, calls the server with search parameter.
final searchedSessionsProvider =
    FutureProvider.autoDispose<List<ChatSession>>((ref) async {
  final query = ref.watch(sessionSearchQueryProvider);

  if (query.isEmpty) {
    try {
      return await ref.watch(chatSessionsProvider.future);
    } catch (_) {
      // chatSessionsProvider can throw when both server and local fail;
      // search view degrades gracefully to empty list
      return [];
    }
  }

  final service = ref.watch(chatServiceProvider);
  return service.getSessions(search: query);
});
