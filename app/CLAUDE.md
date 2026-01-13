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

Three-tab layout with persistent bottom navigation:
- **Chat** (left) - Server-powered AI conversations
- **Daily** (center) - Voice journaling, works offline
- **Vault** (right) - Browse knowledge vault

Each tab has its own Navigator for independent navigation stacks.

---

## Directory Structure

```
lib/
├── main.dart                        # App entry, tab shell, global nav keys
├── core/                            # Shared infrastructure
│   ├── models/                      # Shared data models (speaker_segment.dart)
│   ├── providers/                   # Core Riverpod providers
│   │   ├── app_state_provider.dart  # Server config, app mode
│   │   ├── voice_input_providers.dart
│   │   └── streaming_voice_providers.dart
│   ├── services/
│   │   ├── file_system_service.dart # Unified for Daily/Chat
│   │   ├── streaming_voice_service.dart
│   │   ├── transcription/           # Audio → text (CANONICAL location)
│   │   │   ├── audio_service.dart
│   │   │   ├── transcription_service_adapter.dart
│   │   │   ├── parakeet_service.dart
│   │   │   ├── sherpa_onnx_service.dart
│   │   │   └── sherpa_onnx_isolate.dart
│   │   ├── vad/                     # Voice activity detection (CANONICAL)
│   │   │   ├── simple_vad.dart
│   │   │   └── smart_chunker.dart
│   │   ├── audio_processing/        # Audio filters (CANONICAL)
│   │   │   └── simple_noise_filter.dart
│   │   ├── search/                  # Text search
│   │   └── vision/                  # OCR (stub)
│   ├── theme/
│   │   ├── design_tokens.dart
│   │   └── app_theme.dart
│   └── widgets/                     # Shared UI components
│       └── error_boundary.dart
└── features/
    ├── chat/                        # AI chat (requires server)
    │   ├── models/                  # ChatSession, ChatMessage, etc.
    │   ├── providers/chat_providers.dart  # All chat state
    │   ├── screens/                 # ChatHubScreen, ChatScreen
    │   ├── services/                # ChatService, BackgroundStreamManager
    │   └── widgets/                 # MessageBubble, ChatInput, etc.
    ├── daily/                       # Voice journaling (offline-capable)
    │   ├── journal/                 # Journal CRUD, display
    │   │   ├── models/              # JournalEntry, JournalDay
    │   │   ├── providers/
    │   │   ├── screens/
    │   │   ├── services/            # JournalService, ParaIdService
    │   │   └── widgets/
    │   ├── recorder/                # Audio recording & transcription
    │   │   ├── providers/           # streaming_transcription_provider
    │   │   ├── services/
    │   │   │   ├── live_transcription_service_v3.dart
    │   │   │   ├── background_recording_service.dart
    │   │   │   └── omi/             # Omi pendant support
    │   │   └── widgets/
    │   ├── capture/                 # Photo/handwriting input
    │   ├── reflections/             # AI morning reflections
    │   └── search/screens/          # Journal search
    ├── vault/                       # Knowledge browser (requires server)
    │   ├── models/
    │   ├── providers/
    │   ├── screens/
    │   └── services/
    ├── onboarding/screens/          # Setup flow
    └── settings/                    # App settings
        ├── screens/
        └── widgets/
```

---

## Conventions

### Provider Patterns

| Type | Use for | Example |
|------|---------|---------|
| `Provider<T>` | Singleton services | `fileSystemServiceProvider` |
| `FutureProvider<T>.autoDispose` | Async data that should refresh | `chatSessionsProvider` |
| `StateNotifierProvider` | Complex mutable state | `chatMessagesProvider` |
| `StreamProvider` | Reactive streams | `streamingTranscriptionProvider` |
| `StateProvider` | Simple UI state | `currentTabProvider` |

**Important**: Use `.autoDispose` for FutureProviders with dynamic/paginated content to prevent memory leaks.

### Service Location

Audio processing services have a SINGLE canonical location:
- VAD: `core/services/vad/`
- Audio processing: `core/services/audio_processing/`
- Transcription: `core/services/transcription/`

Do NOT create duplicate services in feature directories.

### Debug Logging

```dart
debugPrint('[ClassName] message');
```

### Resource Cleanup

StateNotifiers must override `dispose()` to clean up:
```dart
@override
void dispose() {
  _subscription?.cancel();
  _timer?.cancel();
  super.dispose();
}
```

Use `try-finally` for operations that must clean up even on error:
```dart
Future<void> stopRecording() async {
  try {
    await _service.stop();
  } finally {
    _stopTimer();  // Always runs
  }
}
```

---

## Vault Paths

| Module | Local Path | Purpose |
|--------|------------|---------|
| Daily | `~/Parachute/Daily/` | Journals, assets, reflections (synced) |
| Chat | `~/Parachute/Chat/` | Sessions, contexts (server-managed) |

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

| Feature | Desktop (macOS) | Mobile (Android/iOS) |
|---------|-----------------|----------------------|
| Transcription | FluidAudio (CoreML) | Sherpa-ONNX |
| Embeddings | Ollama | flutter_gemma |
| Omi pendant | Supported | Supported |

---

## Running

```bash
# Run app
flutter run -d macos
flutter run -d android

# Server (for Chat/Vault features)
cd ../base && ./parachute.sh start
```

---

## Key Files

| Purpose | File |
|---------|------|
| App entry & navigation | `lib/main.dart` |
| Chat state management | `lib/features/chat/providers/chat_providers.dart` |
| Journal state | `lib/features/daily/journal/providers/journal_providers.dart` |
| Live transcription | `lib/features/daily/recorder/services/live_transcription_service_v3.dart` |
| Server communication | `lib/features/chat/services/chat_service.dart` |
| Markdown rendering | `lib/features/chat/widgets/message_bubble.dart` |
