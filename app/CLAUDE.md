# Parachute App

Unified Flutter app - voice journaling, AI chat, knowledge vault, and brain search.

**Package**: `io.openparachute.parachute`

**Related**: [Base Server](../base/CLAUDE.md) | [Parent Project](../CLAUDE.md)

---

## Architecture

```
User → Parachute App → Base Server → Claude Agent SDK → AI
              ↓
       ~/Parachute/Daily (local, offline-capable)
       ~/Parachute/Chat (server-managed)
       ~/Parachute/Brain (server-managed)
```

**Key principle**: Daily works offline. Chat, Vault, and Brain require server connection.

### Navigation

Four-tab layout with persistent bottom navigation:
- **Chat** (left) - Server-powered AI conversations
- **Daily** (center-left) - Voice journaling, works offline
- **Vault** (center-right) - Browse knowledge vault
- **Brain** (right) - Knowledge graph search and entity viewer

Each tab has its own Navigator for independent navigation stacks.

---

## Directory Structure

```
lib/
├── main.dart                        # App entry, tab shell, global nav keys
├── core/                            # Shared infrastructure (inlined, no separate package)
│   ├── models/                      # Shared data models
│   ├── providers/                   # Core Riverpod providers
│   │   ├── app_state_provider.dart  # Server config, app mode, AppTab enum
│   │   ├── voice_input_providers.dart
│   │   └── streaming_voice_providers.dart
│   ├── services/
│   │   ├── file_system_service.dart
│   │   ├── transcription/           # Audio → text (CANONICAL location)
│   │   ├── vad/                     # Voice activity detection (CANONICAL)
│   │   └── audio_processing/        # Audio filters (CANONICAL)
│   ├── theme/
│   │   ├── design_tokens.dart       # BrandColors (use BrandColors.forest, NOT DesignTokens)
│   │   └── app_theme.dart
│   └── widgets/                     # Shared UI components
└── features/
    ├── chat/                        # AI chat (requires server)
    │   ├── models/                  # ChatSession, ChatMessage, StreamEvent
    │   ├── providers/               # Split into 9 provider files
    │   ├── screens/                 # ChatHubScreen, ChatScreen, AgentHubScreen
    │   ├── services/                # ChatService, ChatSessionService, etc.
    │   └── widgets/                 # MessageBubble, ChatInput, SessionConfigSheet
    ├── daily/                       # Voice journaling (offline-capable)
    │   ├── journal/                 # Journal CRUD, display
    │   ├── recorder/                # Audio recording & transcription
    │   ├── capture/                 # Photo/handwriting input
    │   └── search/                  # Journal search
    ├── vault/                       # Knowledge browser (requires server)
    ├── brain/                       # Brain module UI (requires server)
    │   ├── models/                  # BrainEntity, BrainSearchResult
    │   ├── providers/               # Search, service, entity providers
    │   ├── screens/                 # BrainScreen, BrainEntityScreen
    │   ├── services/                # BrainService
    │   └── widgets/                 # BrainEntityCard, BrainTagChip
    ├── settings/                    # App settings
    │   ├── screens/
    │   ├── models/                  # TrustLevel
    │   └── widgets/                 # BotConnectorsSection, HooksSection, TrustLevelsSection
    └── onboarding/                  # Setup flow
```

---

## Core Package (Inlined)

The `parachute-app-core` package was inlined into `lib/core/`. All imports use `package:parachute/core/...` paths. There is no separate core package dependency.

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

**Important**: `ref.listen` must be inside `build()`, never in `initState` or callbacks.

### Theme Colors

Use `BrandColors.forest` (NOT `DesignTokens.forestGreen`). Color tokens are in `core/theme/design_tokens.dart`.

### Service Location

Audio processing services have a SINGLE canonical location:
- VAD: `core/services/vad/`
- Audio processing: `core/services/audio_processing/`
- Transcription: `core/services/transcription/`

### ChatSession API

- `ChatSession` has no `module` field — uses `agentPath`, `agentName`, `agentType`
- `ChatSession.title` is `String?` (nullable) — use `displayTitle` for guaranteed non-null
- `StreamEventType` has 14 values including `typedError`, `userQuestion`, `promptMetadata`
- `ChatSource` enum includes `telegram`, `discord` for bot-originated sessions

---

## Running

```bash
# Desktop development
flutter run -d macos

# Server required for Chat/Vault/Brain
cd ../base && parachute server

# Static analysis
flutter analyze

# Integration tests (macOS, one at a time)
flutter test integration_test/chat_test.dart
```

### Sherpa-ONNX Version Pin

**IMPORTANT**: Pin sherpa_onnx to **1.12.20** via `dependency_overrides`. Version 1.12.21+ has ARM SIGSEGV crash.

---

## Gotchas

- `core/` is inlined — do NOT add `parachute_app_core` back as a dependency
- Integration tests share the macOS app process — don't run them in parallel
- First build takes ~90s (pod install + compile), subsequent builds ~15-20s
- `VAULT_PATH` on server defaults to `./sample-vault` — set to `~/Parachute` in prod
- Server runs on port 3333 by default
