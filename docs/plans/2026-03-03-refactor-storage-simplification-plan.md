---
title: "Storage Simplification — Remove Vault Path, Absolute Audio Paths, Flexible Importer"
type: refactor
date: 2026-03-03
issue: 172
labels: [plan, daily, app, computer]
---

# Storage Simplification

Remove the vault path concept from the Flutter app, move audio assets into `~/.parachute/daily/assets/`, store audio paths as absolute values in the graph, and build a flexible journal importer that accepts any directory and splitting strategy.

## Problem Statement

The "vault path" was invented when Parachute wrote and read markdown journals as its primary storage. Now that Kuzu is the primary store and markdown is import-only, the vault path has no ongoing purpose — it's only needed as the root to resolve relative audio paths. This creates unnecessary user-facing complexity (settings screen, macOS security bookmarks, SharedPreferences keys) and a subtle bug surface where audio breaks if the vault path setting drifts.

Concrete issues today:
- Audio stored as relative paths (`assets/2026-02-25/foo.wav`) that require a root to resolve
- Vault path is a user-configurable setting with 8+ SharedPreferences keys, macOS security bookmark ceremony, and its own settings section — all for a concept that shouldn't exist
- Journal importer is Parachute-format-only; users with Obsidian or Logseq vaults can't use it
- `~/.parachute/sessions/` is a vestigial copy of JSONL files (source of truth is `~/.claude/projects/`, controlled by the Claude Code CLI — we can't relocate it)

## Target Architecture

```
~/.parachute/
  graph/parachute.kz     ← all metadata + content (Kuzu)
  daily/assets/          ← audio files, absolute paths in graph
  config/                ← server.yaml and other config
  logs/                  ← server logs

~/.claude/projects/      ← JSONL transcripts (Claude Code CLI, read-only for us)

~/Parachute/Daily/       ← user's existing markdown + legacy audio (untouched, importable on request)
```

Flutter app:
- No vault path setting
- After recording, **uploads** the audio file to the server (`POST /api/daily/assets/upload`)
- Server saves the file to `~/.parachute/daily/assets/{date}/` and returns the server-side absolute path
- Creates entry via API with that server path — audio lives on the server, not the client device
- Import journals: user picks source directory + format, fires `POST /api/daily/import` once

## Acceptance Criteria

- [x] New audio recordings are uploaded to the server and saved to `~/.parachute/daily/assets/{date}/filename.wav`
- [x] Audio paths in the graph are absolute server paths (e.g., `/Users/parachute/.parachute/daily/assets/...`)
- [x] Server exposes `POST /api/daily/assets/upload` (multipart) to receive and store audio files
- [x] Server exposes `GET /api/daily/assets/{path}` for streaming audio back to any client
- [x] Existing relative paths in graph are migrated to absolute on first server boot
- [x] Flutter app no longer has vault path SharedPreferences keys (`parachute_daily_vault_path`, `parachute_daily_secure_bookmark`, `parachute_daily_module_folder`, `parachute_vault_path`, etc.)
- [x] Journal importer accepts: source directory + format (Parachute / Obsidian / Logseq / Plain)
- [x] Import preview: dry-run returns entry count and sample entries before committing
- [x] Flutter settings import section has directory picker, format selector, preview, and confirm

> **Status as of 2026-03-04:** All phases complete — #172 done.

## Implementation Phases

---

### ~~Phase 1 — Server: Absolute Audio Paths + Asset Serving~~ ✅ Done (PR #171)

**Goal:** Server knows where audio lives; paths in graph are self-contained.

#### 1a. Asset directory constant

In `computer/modules/daily/module.py`:
```python
# ~/.parachute/daily/assets/ — fixed, not configurable
ASSETS_DIR = Path.home() / ".parachute" / "daily" / "assets"
```

Remove `entries_dir` (vestigial). Update `__init__` to just store `parachute_dir` passed from `module_loader`.

#### 1b. Migrate existing relative paths → absolute

On `on_load()`, after schema setup, run a one-time migration:
```python
async def _migrate_audio_paths_to_absolute(self, graph) -> None:
    """One-time: convert relative audio_path values to absolute."""
    rows = await graph.execute_cypher(
        "MATCH (e:Journal_Entry) WHERE e.audio_path IS NOT NULL AND e.audio_path <> '' "
        "AND NOT e.audio_path STARTS WITH '/' RETURN e.entry_id, e.audio_path"
    )
    for row in rows:
        # Try known legacy roots in order
        for legacy_root in [
            Path.home() / "Parachute" / "Daily",
            Path.home() / "Daily",
            ASSETS_DIR.parent,  # ~/.parachute/daily
        ]:
            candidate = legacy_root / row["audio_path"]
            if candidate.exists():
                await graph.execute_cypher(
                    "MATCH (e:Journal_Entry {entry_id: $id}) SET e.audio_path = $path",
                    {"id": row["entry_id"], "path": str(candidate)},
                )
                break
```

This runs idempotently — already-absolute paths are skipped by the `NOT STARTS WITH '/'` filter.

#### 1c. Audio upload endpoint

New route in `get_router()`:
```python
@router.post("/assets/upload", status_code=201)
async def upload_asset(file: UploadFile, date: str | None = None):
    """
    Receive an audio/image file from a client and save it to
    ~/.parachute/daily/assets/{date}/{filename}.

    Returns the absolute server path so the client can store it in the entry.
    """
    from fastapi import UploadFile
    import shutil, uuid

    date_str = date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    dest_dir = ASSETS_DIR / date_str
    dest_dir.mkdir(parents=True, exist_ok=True)

    # Preserve original filename; add UUID prefix to avoid collisions
    safe_name = f"{uuid.uuid4().hex[:8]}_{file.filename}"
    dest_path = dest_dir / safe_name

    with open(dest_path, "wb") as out:
        shutil.copyfileobj(file.file, out)

    return {"path": str(dest_path), "filename": safe_name}
```

#### 1d. Audio file serving endpoint

```python
@router.get("/assets/{path:path}")
async def serve_asset(path: str):
    """Stream an audio/image file. Path is relative to ASSETS_DIR."""
    assets_root = ASSETS_DIR
    full_path = (assets_root / path).resolve()
    if not str(full_path).startswith(str(assets_root.resolve())):
        return JSONResponse(status_code=403, content={"error": "forbidden"})
    if not full_path.exists():
        return JSONResponse(status_code=404, content={"error": "not found"})
    return FileResponse(full_path)
```

#### 1e. `create_entry` writes absolute paths

When the Flutter app sends `audio_path` after uploading, store the absolute server path as-is.

**Files:** `computer/modules/daily/module.py`

---

### ~~Phase 2 — Flutter: Upload Audio to Server~~ ✅ Done (PR #171 + PR #191)

**Goal:** Audio lives on the server. Flutter uploads the file immediately after recording, then creates the entry with the server-returned path. No vault path needed.

#### 2a. New `DailyApiService.uploadAudio()` method

```dart
// Returns the absolute server path to store in the entry
Future<String?> uploadAudio(File audioFile, {String? date}) async {
  final uri = Uri.parse('$baseUrl/api/daily/assets/upload');
  final request = http.MultipartRequest('POST', uri)
    ..files.add(await http.MultipartFile.fromPath('file', audioFile.path))
    ..fields['date'] = date ?? _todayStr();
  if (apiKey != null) request.headers['X-API-Key'] = apiKey!;
  final response = await request.send();
  if (response.statusCode == 201) {
    final body = json.decode(await response.stream.bytesToString());
    return body['path'] as String?;
  }
  return null; // upload failed — caller decides how to handle
}
```

#### 2b. Update recording flow

After recording stops and transcription completes, in `journal_screen.dart._addVoiceEntry()`:

```dart
Future<void> _addVoiceEntry(String transcript, String localAudioPath, int duration) async {
  final api = ref.read(dailyApiServiceProvider);

  // Upload audio to server first
  final serverPath = await api.uploadAudio(File(localAudioPath));

  // Create entry with server path (or fall back to local if upload failed)
  await api.createEntry(
    content: transcript,
    metadata: {
      'type': 'voice',
      'audio_path': serverPath ?? localAudioPath,
      'duration_seconds': duration,
    },
  );
  // ...
}
```

#### 2c. Audio playback via server URL

`JournalHelpers.getAudioUrl()` — replaces `getFullAudioPath()`:
```dart
static String getAudioUrl(String audioPath, String serverBaseUrl) {
  if (audioPath.startsWith('/')) {
    // Absolute server path → derive relative segment for HTTP endpoint
    final assetsMarker = '/daily/assets/';
    final idx = audioPath.indexOf(assetsMarker);
    if (idx != -1) {
      final rel = audioPath.substring(idx + assetsMarker.length);
      return '$serverBaseUrl/api/daily/assets/$rel';
    }
  }
  // Legacy relative path — serve directly via server
  return '$serverBaseUrl/api/daily/assets/$audioPath';
}
```

On macOS desktop (local server), this becomes `http://localhost:3333/api/daily/assets/...`.
On mobile/web (remote server), same URL works over the network.

#### 2d. Temp file cleanup

After successful upload, delete the local temp recording file:
```dart
if (serverPath != null) {
  await File(localAudioPath).delete();
}
```

**Files:** `daily_api_service.dart` (new `uploadAudio()`), `journal_screen.dart` (`_addVoiceEntry`), `journal_helpers.dart` (new `getAudioUrl()`), `omi_capture_service.dart` (same upload pattern), playback call sites

---

### ~~Phase 3 — Flutter: Remove Vault Path Settings~~ ✅ Done

**Goal:** Vault path concept is gone from the UI and SharedPreferences.

#### 3a. Remove SharedPreferences keys

Delete or deprecate:
- `parachute_daily_vault_path`
- `parachute_daily_module_folder`
- `parachute_daily_user_configured`
- `parachute_daily_secure_bookmark`
- `parachute_chat_vault_path` / `_module_folder` / `_user_configured` / `_secure_bookmark`
- Subfolder keys: `parachute_daily_journals_folder`, `parachute_daily_assets_folder`, etc.

Write a one-time migration that clears these keys on first launch after the update.

#### 3b. Simplify or remove `FileSystemService`

`FileSystemService` was primarily a vault-path resolver. After this refactor:
- Audio path: use `ParachutePaths` constants
- Markdown import: replaced by flexible importer (Phase 4)
- Chat logs: no longer written by app

The service can be significantly trimmed or removed. Keep only:
- `getRecordingTempPath()` — for in-flight recordings
- Any remaining non-vault I/O

#### 3c. Remove `VaultSettingsSection` vault UI

Keep the settings section but strip it to just the import controls (moved to Phase 4 UI). Remove:
- Vault root display
- Module folder name display
- "Open in Finder" vault button
- macOS security bookmark flow

The section gets renamed `JournalImportSection` and only shows the import UI.

**Files:** `file_system_service.dart`, `vault_settings_section.dart`, `settings_screen.dart`, various providers that read vault path

---

### ~~Phase 4 — Flexible Journal Importer~~ ✅ Done (PR #171)

**Goal:** Any Obsidian/Logseq/plain/Parachute vault can be imported in one step from Settings.

#### 4a. Server: format-aware importer endpoint

Extend `POST /api/daily/import` with a request body:

```python
class ImportRequest(BaseModel):
    source_dir: str           # absolute path the user selected
    format: str               # "parachute" | "obsidian" | "logseq" | "plain"
    dry_run: bool = False     # if True, parse but don't write
    date_from: str | None = None  # optional YYYY-MM-DD filter
    date_to: str | None = None
```

**Format parsers:**

| Format | Split strategy | Entry ID |
|--------|---------------|---------|
| `parachute` | `# para:id HH:MM` headers | para_id |
| `obsidian` | `---` HR or `## ` H2 headings | `{stem}-{i}` |
| `logseq` | Top-level `- ` bullet points | `{stem}-{i}` |
| `plain` | Whole file = one entry | file stem |

Response includes:
```json
{
  "files_found": 230,
  "entries_parsed": 526,
  "already_imported": 520,
  "to_import": 6,
  "sample": [...],   // first 3 parsed entries for preview
  "imported": 6      // only present when dry_run=false
}
```

#### 4b. Server: update `_parse_md_file` to accept format

Refactor the existing parser into a dispatch function:
```python
def _parse_file(self, md_file: Path, fmt: str) -> list[dict]:
    if fmt == "parachute":
        return self._parse_parachute(md_file)
    elif fmt == "obsidian":
        return self._parse_obsidian(md_file)
    elif fmt == "logseq":
        return self._parse_logseq(md_file)
    else:  # plain
        return self._parse_plain(md_file)
```

**Obsidian parser:** split on `\n---\n` or `\n## `. Use frontmatter `date:` or filename for date. Content is the section text.

**Logseq parser:** read file, split on top-level `^- ` bullets (not indented). Each bullet = one entry. Date from filename (`YYYY-MM-DD.md`).

**Plain parser:** whole file = one entry. Date from filename. No splitting.

#### 4c. Flutter: import settings UI

Replace the current import section in `VaultSettingsSection`:

```
┌─ Import Journals ────────────────────────────────────────┐
│                                                          │
│  Source folder:  /Users/you/Obsidian/Daily  [Browse]    │
│                                                          │
│  Format:  ● Obsidian (HR / H2 headings)                 │
│           ○ Logseq (top-level bullets)                  │
│           ○ Parachute (# para: headers)                 │
│           ○ Plain (whole file per entry)                 │
│                                                          │
│  [Preview]                                               │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │ Found 230 files · 526 entries · 6 not yet in DB │   │
│  │ Sample: "Good morning. I just met with..." (Feb) │   │
│  └──────────────────────────────────────────────────┘   │
│                                                          │
│  [Import 6 entries]                                      │
└──────────────────────────────────────────────────────────┘
```

Components:
- `file_picker` (already in pubspec? if not, add) for folder selection
- `DropdownButton` or `SegmentedButton` for format
- "Preview" button → `POST /api/daily/import` with `dry_run: true`
- "Import" button → same endpoint with `dry_run: false`

**Files:** `vault_settings_section.dart` (renamed to `import_settings_section.dart`), `daily_api_service.dart` (new `importJournals()` method)

---

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| Audio upload fails while server is offline | Store entry with local path as fallback; retry upload on reconnect (future: pending queue) |
| Relative audio paths in graph not found during migration | Try multiple legacy roots in order; log misses; don't fail boot |
| Large audio files slow the upload + create cycle | Upload is async; show entry immediately with pending audio indicator, update when upload completes |
| FileSystemService used in more places than expected | Grep all usages before removing; deprecate before deleting |
| `file_picker` package not in pubspec | Check `app/pubspec.yaml`; add if missing |
| Logseq parser edge cases (indented bullets, page links) | Ship basic top-level-only parser; improve iteratively |
| Import of files already partially imported creates duplicates | MERGE semantics already in `_write_to_graph`; idempotent by entry_id |

## Alternative Approaches Considered

**A. Keep audio on client filesystem, just store absolute path**
Simpler short-term but breaks for any non-macOS client (mobile, web, remote access). Rejected — audio on the server is the right long-term home.

**B. Keep relative paths, just hardcode the root**
Cheaper short-term but perpetuates the ambiguity. Absolute paths are unambiguous and self-documenting.

**C. Store audio in app's documents directory (macOS sandbox)**
Platform-specific and harder to access from server. `~/.parachute/daily/assets/` is accessible from both Flutter and server process.

## Implementation Order

1. **Phase 1** (server only, self-contained) — can ship without Flutter changes
2. **Phase 2** (Flutter audio path) — depends on Phase 1 server endpoint being live
3. **Phase 4 server** (flexible importer parser) — independent, can parallel with Phase 2
4. **Phase 3** (remove vault path from Flutter) — after Phase 2 is confirmed working
5. **Phase 4 Flutter** (import UI) — after Phase 4 server and Phase 3

## References

- Storage restructure PR: #170
- Post-restructure fixes: #171
- Daily module: `computer/modules/daily/module.py`
- FileSystemService: `app/lib/core/services/file_system_service.dart`
- Vault settings UI: `app/lib/features/settings/widgets/vault_settings_section.dart`
- JournalHelpers: `app/lib/features/daily/journal/utils/journal_helpers.dart`
- Recording services: `app/lib/features/daily/recorder/services/`
