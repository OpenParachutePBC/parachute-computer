# Parachute App

Unified Flutter app - voice journaling, AI chat, and knowledge vault.

**Package**: `io.openparachute.app`

---

## Architecture

```
User → Parachute App → Base Server → Claude SDK → AI
              ↓
       ~/Parachute/Daily (local, offline-capable)
       ~/Parachute/Chat (server-managed)
```

**Key principle**: Daily works offline. Chat and Vault require server connection.

### Navigation

Three tabs with Daily always centered:
- **Chat** (left) - Server-powered AI conversations. Hidden until server configured.
- **Daily** (center) - Voice journaling. Always available, works offline.
- **Vault** (right) - Browse knowledge vault. Hidden until server configured.

```dart
// Tab visibility based on server configuration
final visibleTabs = serverConfigured
    ? [AppTab.chat, AppTab.daily, AppTab.vault]
    : [AppTab.daily];
```

---

## Directory Structure

```
lib/
├── main.dart
├── core/                           # Shared infrastructure
│   ├── config/                     # App configuration
│   ├── models/                     # Shared data models
│   ├── providers/                  # Core Riverpod providers
│   │   ├── app_state_provider.dart # Server config, app mode
│   │   └── file_system_provider.dart
│   ├── services/
│   │   ├── file_system_service.dart    # Unified for Daily/Chat
│   │   ├── transcription/              # Audio → text (shared)
│   │   │   ├── audio_service.dart
│   │   │   ├── streaming_transcription_service.dart
│   │   │   ├── transcription_adapter.dart
│   │   │   └── vad/
│   │   ├── embedding/                  # Semantic search
│   │   └── search/                     # Text search
│   ├── theme/
│   │   ├── design_tokens.dart
│   │   └── app_theme.dart
│   └── widgets/                    # Shared UI components
└── features/
    ├── daily/                      # Voice journaling (offline-capable)
    │   ├── journal/                # Journal CRUD, display
    │   ├── capture/                # Photo/handwriting input
    │   ├── reflections/            # AI morning reflections
    │   └── omi/                    # Omi pendant (feature-flagged)
    ├── chat/                       # AI chat (requires server)
    │   ├── sessions/               # Session management
    │   ├── streaming/              # SSE message streaming
    │   └── tools/                  # Tool call UI
    ├── vault/                      # Knowledge browser (requires server)
    ├── onboarding/                 # Setup flow
    └── settings/                   # App settings
```

---

## Conventions

### Provider Patterns

| Type | Use for | Example |
|------|---------|---------|
| `Provider<T>` | Singleton services | `fileSystemServiceProvider` |
| `FutureProvider<T>` | Async initialization | `journalServiceProvider` |
| `StateNotifierProvider` | Complex mutable state | `chatMessagesProvider` |
| `StreamProvider` | Reactive streams | `streamingTranscriptionProvider` |
| `StateProvider` | Simple UI state | `currentTabProvider` |

### Service Initialization

```dart
class MyService {
  MyService._({required this.config});

  static Future<MyService> create() async {
    final config = await _loadConfig();
    return MyService._(config: config);
  }
}
```

### Feature Flags

```dart
// Check server availability before showing features
final appMode = ref.watch(appModeProvider);
if (appMode == AppMode.full) {
  // Show chat/vault features
}
```

### Debug Logging

```dart
debugPrint('[ClassName] message');
```

---

## Vault Paths

| Module | Local Path | Purpose |
|--------|------------|---------|
| Daily | `~/Parachute/Daily/` | Journals, assets, reflections (synced) |
| Chat | `~/Parachute/Chat/` | Sessions, contexts (server-managed) |

Daily folder is offline-capable and will sync with server.
Chat folder is managed by server.

---

## Para-ID System

Portable IDs for cross-device sync:

```markdown
## para:abc123xyz 10:30 AM

Entry content here...
```

Format: `para:{12-char-alphanumeric}` - unique across all modules.

---

## Platform Notes

| Feature | Desktop | Mobile |
|---------|---------|--------|
| Transcription | FluidAudio (CoreML) | Sherpa-ONNX |
| Embeddings | Ollama | flutter_gemma |
| Omi pendant | Supported | Supported |

---

## Running

```bash
flutter run -d macos
flutter run -d android
```

Server (for Chat/Vault features):
```bash
cd ../base && ./parachute.sh start
```
