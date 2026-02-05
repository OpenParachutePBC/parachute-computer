// ============================================================
// Barrel File - Re-exports all chat providers
// ============================================================
//
// This file acts as a single import point for all chat-related providers.
// Instead of importing from individual files, widgets can import this file
// to access all providers.
//
// The providers have been split into focused files by domain:
// - chat_session_providers.dart: Session list, active session, CRUD
// - chat_message_providers.dart: Message list, streaming, sending
// - chat_context_providers.dart: Context folders and context files
// - chat_streaming_providers.dart: SSE streaming state
// - chat_ui_providers.dart: UI state (scroll, input, vault browsing)
// - chat_curator_providers.dart: Session curation, chat log, titles
// - chat_import_providers.dart: Import service
//
// ============================================================

// Session providers
export 'chat_session_providers.dart';

// Session action providers (separate to avoid circular dependency)
export 'chat_session_actions.dart';

// Message providers
export 'chat_message_providers.dart';

// Context providers
export 'chat_context_providers.dart';

// Streaming providers
export 'chat_streaming_providers.dart';

// UI providers
export 'chat_ui_providers.dart';

// Curator providers
export 'chat_curator_providers.dart';

// Import providers
export 'chat_import_providers.dart';
