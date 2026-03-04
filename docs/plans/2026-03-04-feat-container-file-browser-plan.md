---
title: Container file browser — full end-to-end
type: feat
date: 2026-03-04
issue: 185
---

# feat(app): Container file browser — full end-to-end

Wire the server-side container file API (PR #184) to a Flutter UI. Users can browse,
upload, download, create directories, and delete files in their chat container environments.

## Acceptance Criteria

- [x] File/directory listing with breadcrumb navigation and pull-to-refresh
- [x] Upload files from device via `file_picker` (photo picker for images; general picker for other files) with progress indicator
- [x] Download/save files from container to device; share sheet on mobile
- [x] Create new directories with a name dialog
- [x] Delete files and directories with confirmation dialog
- [x] Text/code file preview (reuse `RemoteTextViewerScreen` pattern)
- [x] Markdown preview (reuse `RemoteMarkdownViewerScreen` pattern)
- [x] Image preview (`Image.memory` from downloaded bytes)
- [x] "Files" entry point in the chat screen toolbar, visible only when the active session has a `containerEnvId`
- [x] Empty state, loading state, and error states
- [x] Sort by name with folders first (match vault browser behavior)
- [x] `flutter analyze` passes with no new errors

## Context

**API** (live from PR #184, `computer/parachute/api/container_files.py`):

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/containers/{slug}/files?path=&includeHidden=` | List directory |
| `GET` | `/api/containers/{slug}/files/download?path=` | Download file (returns binary) |
| `POST` | `/api/containers/{slug}/files/upload?path=` | Upload files (multipart, 50 MB/file) |
| `POST` | `/api/containers/{slug}/files/mkdir?path=` | Create directory |
| `DELETE` | `/api/containers/{slug}/files?path=` | Delete file or directory |

Response shape for listing: `{ slug, path, entries: [{ name, path, type, size, lastModified, isDirectory, isFile }] }`

**Existing reusables:**
- `FileItem` / `FileItemType` — `app/lib/features/vault/models/file_item.dart`
- `RemoteFilesScreen` — vault file browser; same `ListView` + breadcrumb + context-menu pattern
- `ContainerEnvService` — auth header pattern to clone for `ContainerFilesService`
- `containerEnvServiceProvider` — Riverpod provider pattern to clone
- `file_picker: ^8.0.0+1` — already in pubspec
- `ChatSession.containerEnvId` — nullable, present when session uses a sandbox

**Dependencies to add:**
- `share_plus` — for mobile download / share sheet (not yet in pubspec.yaml)

---

## Implementation

### 1. `ContainerFilesService`
**New file:** `app/lib/features/chat/services/container_files_service.dart`

Mirror `ContainerEnvService` structure (same auth headers). Methods:

```dart
Future<List<FileItem>> listFiles(String slug, {String path = '', bool includeHidden = false})
Future<Uint8List> downloadFile(String slug, String path)   // returns raw bytes
Future<List<ContainerFileOpResult>> uploadFiles(String slug, List<PlatformFile> files, {String uploadPath = ''})
Future<ContainerFileOpResult> mkdir(String slug, String path)
Future<ContainerFileOpResult> delete(String slug, String path)
```

`ContainerFileOpResult` is a simple class with `success`, `path`, `message`.

For `listFiles`, parse the `entries` list into `FileItem` objects. Extend `FileItemType` to include `image` (png, jpg, gif, svg, webp, bmp), re-sort: folders first, then alphabetically.

### 2. Providers
**New file:** `app/lib/features/chat/providers/container_files_providers.dart`

```dart
// Singleton service — mirrors containerEnvServiceProvider
final containerFilesServiceProvider = Provider<ContainerFilesService>(...)

// Per-slug path state. autoDispose so it resets on nav pop.
final containerFilesPathProvider = StateProvider.autoDispose.family<String, String>(
  (ref, slug) => '',
)

// Per-slug directory listing
final containerFilesListProvider = FutureProvider.autoDispose.family<List<FileItem>, String>(
  (ref, slug) async {
    final service = ref.watch(containerFilesServiceProvider);
    final path = ref.watch(containerFilesPathProvider(slug));
    return service.listFiles(slug, path: path);
  },
)
```

### 3. `ContainerFileBrowserScreen`
**New file:** `app/lib/features/chat/screens/container_file_browser_screen.dart`

`ConsumerStatefulWidget`. Takes `slug` and `displayName` as constructor args.

**Layout:** Standard `Scaffold` with `AppBar` (back button, breadcrumb title, refresh + toggle-hidden icons) and `ListView.builder` body.

**Actions available from appbar / FAB:**
- Upload — triggers `FilePicker.platform.pickMultipleFiles()`, passes to service, refreshes
- New folder — shows `AlertDialog` with a `TextField`, calls `mkdir`, refreshes

**File item tap behavior:**
- Directory → push new path via `containerFilesPathProvider(slug).notifier`
- Markdown → `Navigator.push(RemoteMarkdownViewerScreen)` (needs bytes-based variant or download to temp)
- Text/code → `Navigator.push(RemoteTextViewerScreen)` (same)
- Image → show full-screen `Image.memory` dialog
- Other → show context menu (download/share, delete)

**Long-press context menu (bottom sheet) for all non-folder items:**
- Download / Share — download bytes, write to temp file, `SharePlus.shareXFiles([...])`
- Delete — confirm dialog → `service.delete(slug, path)` → refresh

**Long-press on directory:**
- Delete — confirm dialog (recursive delete warning) → `service.delete` → refresh

**Upload progress:** Show a `LinearProgressIndicator` in the app bar area while upload is in flight; use `setState` with a local `_uploading` bool.

**Empty state, loading, error:** Follow `RemoteFilesScreen` pattern exactly.

### 4. Entry point in `ChatScreen`
**Modified file:** `app/lib/features/chat/screens/chat_screen.dart`

In the embedded toolbar (or `AppBar.actions`) — when `session.containerEnvId != null`, show a `folders` icon button that navigates to `ContainerFileBrowserScreen(slug: session.containerEnvId!, displayName: ...)`.

Locate the `// container env slug` section where `activeContainerEnvProvider` is already read; add the icon button in the same area as existing toolbar actions.

### 5. `pubspec.yaml`
**Modified:** Add `share_plus: ^10.0.0` under `dependencies`.

---

## File Map

| Action | File |
|--------|------|
| Create | `app/lib/features/chat/services/container_files_service.dart` |
| Create | `app/lib/features/chat/providers/container_files_providers.dart` |
| Create | `app/lib/features/chat/screens/container_file_browser_screen.dart` |
| Modify | `app/lib/features/chat/screens/chat_screen.dart` |
| Modify | `app/pubspec.yaml` |

---

## Risks

- **Upload multipart encoding**: Flutter's `http` package needs `MultipartRequest` for file uploads. Use `http.MultipartRequest` with `fromBytes` — test with large files near the 50 MB limit.
- **Download on desktop**: `share_plus` `shareXFiles` works on macOS but opens the system share sheet; for desktop we may prefer a save-file dialog. Phase 1: use share sheet everywhere; defer save dialog to follow-up.
- **`FileItem` image type**: `FileItem`/`FileItemType` are shared with vault. Either extend in-place (add `image` case) or duplicate the model into `chat/models/`. Prefer extending vault's shared model — it's a purely additive change.
- **Symlinks in container home**: The server's `iterdir()` follows symlinks. Client just renders them as files/dirs — no special handling needed.
