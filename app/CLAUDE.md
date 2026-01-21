# Parachute App

Unified Flutter app - voice journaling, AI chat, and knowledge vault.

**Package**: `io.openparachute.parachute`

**Related**: [Base Server](../base/CLAUDE.md) | [Parent Project](../CLAUDE.md)

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
| Daily | `~/Parachute/Daily/` | Journals, assets, agent outputs (local-first) |
| Chat | `~/Parachute/Chat/` | Sessions, contexts (server-managed) |

Agent outputs (reflections, content-scout, etc.) are stored in `Daily/` subdirectories, generated by the multi-agent pipeline on the server.

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

### Sherpa-ONNX Version Pin

**IMPORTANT**: The app uses `dependency_overrides` to pin sherpa_onnx to version **1.12.20**.

Version 1.12.21 has a native library crash (SIGSEGV at 0x3f800000) on certain ARM devices (e.g., Daylight DC-1 with MediaTek chipset). Do NOT upgrade sherpa_onnx without testing on affected devices.

---

## Running

```bash
# Desktop development
flutter run -d macos

# Android development
flutter run -d android --flavor full

# Server (for Chat/Vault features)
cd ../base && ./parachute.sh start
```

---

## Build Flavors

The app uses `--dart-define=FLAVOR=` to set compile-time behavior (works on ALL platforms). Default is `client`.

| Flavor | Use Case |
|--------|----------|
| `client` | **Default** - connects to external server (any platform) |
| `computer` | Desktop with bundled Lima VM (Parachute Computer) |
| `daily` | Standalone offline journal app |

**Android product flavors** (in `build.gradle.kts`) - controls app ID only:
- `daily` → `io.openparachute.daily` (Parachute Daily)
- `full` → `io.openparachute.parachute` (Parachute)

**Examples:**
```bash
# Standard build (client flavor is default)
flutter build apk --release --flavor full
flutter run -d macos
flutter run -d chrome

# Daily-only standalone app
flutter build apk --release --flavor daily --dart-define=FLAVOR=daily

# Parachute Computer (macOS only)
flutter build macos --release --dart-define=FLAVOR=computer
```

---

## Parachute Computer (Lima VM Distribution)

The app can be built as "Parachute Computer" - a self-contained distribution that runs the base server in an isolated Lima VM.

### Building the DMG

```bash
# Standard distribution (base at ~/Library/Application Support/Parachute/base)
./scripts/build_computer_dmg.sh

# Developer distribution (uses your local base repo)
./scripts/build_computer_dmg.sh --dev-base-path ~/Parachute/projects/parachute/base
```

### Key Files

| File | Purpose |
|------|---------|
| `lima/parachute.yaml` | Lima VM configuration |
| `scripts/build_computer_dmg.sh` | DMG build script |
| `lib/core/services/lima_vm_service.dart` | VM lifecycle management |
| `lib/features/settings/widgets/computer_setup_wizard.dart` | Setup UI |

### How It Works

1. App detects `FLAVOR=computer` and shows Lima setup wizard
2. User installs Homebrew → Lima → creates VM
3. VM mounts `~/Parachute` as `/vault` (HOME for the VM user)
4. Base server runs inside VM, accessible at `localhost:3333`
5. Claude Code CLI runs in VM with filesystem access limited to vault

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
