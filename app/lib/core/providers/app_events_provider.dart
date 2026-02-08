import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/send_to_chat_event.dart';

/// Provider for cross-feature events: Send to Chat
///
/// This allows features like Daily to send content to Chat without
/// directly importing from the chat feature package.
final sendToChatEventProvider = StateProvider<SendToChatEvent?>((ref) => null);
