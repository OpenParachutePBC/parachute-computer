# Parachute App Migration Status

Tracking the merge of `chat/` and `daily/` into unified `app/`.

## Architecture Goal

```
app/
├── lib/
│   ├── main.dart                    # App entry, nav shell
│   ├── core/                        # Shared infrastructure
│   │   ├── config/                  # App config, constants
│   │   ├── models/                  # Shared data models
│   │   ├── providers/               # Riverpod providers
│   │   ├── services/                # Core services
│   │   ├── theme/                   # Design tokens, themes
│   │   └── widgets/                 # Reusable widgets
│   └── features/
│       ├── daily/                   # Daily journal (offline-first)
│       │   ├── journal/             # Main journal UI
│       │   ├── recorder/            # Voice recording/transcription
│       │   ├── capture/             # Handwriting, photos
│       │   └── reflections/         # AI reflections
│       ├── chat/                    # AI chat (requires server)
│       │   ├── screens/             # Chat hub, chat screen
│       │   ├── models/              # Session, message models
│       │   ├── services/            # Chat service, SSE
│       │   └── widgets/             # Chat input, messages
│       ├── vault/                   # File browser (requires server)
│       ├── settings/                # Unified settings
│       └── onboarding/              # First-run setup
```

## Migration Status

### ✅ COMPLETED

**Core Infrastructure:**
- [x] Unified `FileSystemService` with module support (daily/chat)
- [x] `LoggingService` with file logging and component loggers
- [x] `PerformanceService` for timing measurements
- [x] Theme system (`design_tokens.dart`, `app_theme.dart`)
- [x] App state provider (AppMode: dailyOnly/full)
- [x] Navigation shell (Daily center, Chat/Vault conditional)
- [x] Error boundary widget

**Daily Features (64 files):**
- [x] Journal - models, providers, screens, services, widgets
- [x] Recorder - transcription, VAD, audio services, Omi BLE
- [x] Capture - handwriting, photo capture
- [x] Reflections - AI morning reflections
- [x] Search - simple text search (within Daily)

**Settings:**
- [x] Unified settings screen
- [x] Server URL configuration
- [x] Daily storage location
- [x] Chat storage location (when server enabled)

**Chat & Vault Placeholders:**
- [x] Chat hub screen (placeholder with server status)
- [x] Vault browser screen (placeholder with folder cards)

**Stubbed Services:**
- [x] Voice input service (stub)
- [x] Streaming voice service (stub)
- [x] Embedding provider (stub)
- [x] Vision provider (stub)

### 🚧 IN PROGRESS

**Chat Features (models copied, core integration done):**
- [x] Models copied (chat_session, chat_message, etc.)
- [x] Services copied and fixed (ChatService, LocalSessionReader, etc.)
- [x] Providers integrated (chatSessionsProvider, currentSessionIdProvider)
- [x] Chat hub shows sessions from server
- [x] Backend health service for connection status
- [x] Session list with navigation to chat screen
- [ ] Full chat screen streaming/messages
- [ ] Voice input for chat

### ❌ NOT STARTED

**Full Chat Implementation:**
- [ ] SSE streaming integration
- [ ] Stream message events
- [ ] Tool result rendering
- [ ] Session persistence

**Vault Browser:**
- [ ] File tree view
- [ ] File preview
- [ ] Search across vault

**Onboarding:**
- [ ] First-run flow
- [ ] Folder picker
- [ ] Permissions
- [ ] Optional server setup

## Current Build Status

- ✅ macOS debug builds
- ✅ Android debug builds and installs
- ⏸️ iOS (not tested yet)

## App Features by Mode

### Daily Only Mode (no server)
- Journal entries (voice, text, photo, handwriting)
- Local transcription (Parakeet/Sherpa-ONNX)
- Search within Daily
- Settings

### Full Mode (server configured)
- All Daily features
- **Chat tab** - AI conversations via Base server
- **Vault tab** - Browse ~/Parachute files
- Server management

## Key Files

- `lib/main.dart` - App entry, navigation shell
- `lib/core/providers/app_state_provider.dart` - Server URL, app mode
- `lib/core/services/file_system_service.dart` - Unified file paths
- `lib/features/daily/home/screens/home_screen.dart` - Daily entry point
- `lib/features/chat/screens/chat_hub_screen.dart` - Chat entry point
- `lib/features/vault/screens/vault_browser_screen.dart` - Vault entry point
- `lib/features/settings/screens/settings_screen.dart` - Settings
