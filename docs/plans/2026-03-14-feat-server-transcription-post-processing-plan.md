---
title: "Server-Side Transcription & LLM Post-Processing for Daily"
type: feat
date: 2026-03-14
issue: 260
---

# Server-Side Transcription & LLM Post-Processing for Daily

Audio recorded in the app uploads to Parachute Computer, where Parakeet V3 transcribes it and a cleanup Caller polishes the text. Voice notes read like typed entries. The app becomes a recorder + display; the server does the heavy lifting.

**Brainstorm:** `docs/brainstorms/2026-03-14-server-transcription-post-processing-brainstorm.md`

## Overview

Three-phase build on top of existing infrastructure. Phase 1 adds the transcription engine. Phase 2 wires a combined voice-entry endpoint that transcribes in the background. Phase 3 adds a built-in cleanup Caller that auto-runs after transcription, plus a new `update_entry` tool so the Caller can write polished text back to the entry itself (not a Card).

### End-to-End Flow

```
App: record → create local stub (status: "needs_upload")
     → POST /api/daily/entries/voice (audio + metadata)

Server: save audio → create Note (status: "processing")
        → background: transcribe with Parakeet V3
        → update Note.content with raw text (status: "transcribed")
        → auto-trigger cleanup Caller
        → Caller reads entry, cleans up, writes back (status: "complete")

App: poll/sync → entry appears with polished text
```

### Status Flow

```
processing → transcribed → complete
     ↓            ↓
   failed       failed
     ↑            ↑
  (retry)     (retry → processing)
```

Add `"transcribed"` as an intermediate status — transcription done, cleanup pending. This lets the app show raw text immediately while cleanup runs, and gives a clean retry boundary if only the Caller fails.

## Existing Infrastructure (No Changes Needed)

| What | Where | Notes |
|------|-------|-------|
| Asset upload | `POST /api/daily/assets/upload` | Saves to `~/.parachute/daily/assets/{date}/` |
| Entry CRUD | `POST/GET/PATCH/DELETE /api/daily/entries` | Full lifecycle with metadata_json |
| Transcription status validation | `module.py` lines 156–161 | `VALID_TRANSCRIPTION_STATUSES`, transitionguards on PATCH |
| Caller infrastructure | `daily_agent.py`, `scheduler.py` | Discovery, scheduling, sandboxed + direct execution |
| Caller tools | `daily_agent_tools.py` | read_journal, write_output, etc. |
| Bot connector hooks | `telegram.py`, `discord_bot.py`, `matrix_bot.py` | Already look for `self.server.transcribe_audio()` |

## Phase 1: TranscriptionService

New file: `parachute/core/transcription.py`

A singleton service with a backend abstraction. The public interface (`TranscriptionService`) delegates to a backend — `parakeet-mlx` on macOS (Metal GPU acceleration), with `sherpa-onnx` as a future Linux fallback. Inference runs in a ThreadPoolExecutor so it doesn't block the event loop.

### Why parakeet-mlx over sherpa-onnx on macOS

| | parakeet-mlx | sherpa-onnx |
|---|---|---|
| macOS Apple Silicon | **Metal GPU** — fast | CPU only (CoreML is slower) |
| Linux | Not supported | Full support |
| Same model | Parakeet V3 | Parakeet V3 |
| API | `model.transcribe("file.wav")` | ~20 lines of setup |
| Word timestamps | Built-in | No |
| Install | `pip install parakeet-mlx` | `pip install sherpa-onnx` |

macOS is the primary target OS. sherpa-onnx on macOS uses CPU-only ONNX Runtime — the GPU and Neural Engine sit idle. parakeet-mlx uses Apple's MLX framework to run inference on the Metal GPU, which is significantly faster. Same Parakeet V3 model, native hardware acceleration.

### Architecture: Backend abstraction

```python
class TranscriptionBackend(Protocol):
    """Interface for transcription backends."""
    async def initialize(self) -> None: ...
    async def transcribe(self, audio_path: Path) -> str: ...
    async def transcribe_bytes(self, audio_bytes: bytes) -> str: ...

class TranscriptionService:
    """Server-side speech-to-text. Delegates to platform-specific backend."""

    def __init__(self, backend: TranscriptionBackend):
        self._backend = backend

    @classmethod
    def from_config(cls, settings) -> "TranscriptionService | None":
        """Auto-detect platform and select best available backend."""
        backend = _detect_backend(settings)
        if backend is None:
            return None
        return cls(backend)

    async def initialize(self):
        await self._backend.initialize()

    async def transcribe(self, audio_path: Path) -> str:
        return await self._backend.transcribe(audio_path)

    async def transcribe_bytes(self, audio_bytes: bytes) -> str:
        return await self._backend.transcribe_bytes(audio_bytes)


def _detect_backend(settings) -> TranscriptionBackend | None:
    """Select backend: parakeet-mlx on macOS, sherpa-onnx on Linux (future)."""
    if sys.platform == "darwin":
        try:
            from parachute.core.transcription_mlx import ParakeetMLXBackend
            return ParakeetMLXBackend()
        except ImportError:
            logger.warning("parakeet-mlx not installed, transcription unavailable")
            return None
    else:
        # Future: sherpa-onnx backend for Linux
        logger.info("Transcription: no backend available for this platform")
        return None
```

### parakeet-mlx backend

New file: `parachute/core/transcription_mlx.py`

```python
class ParakeetMLXBackend:
    """Parakeet V3 on Apple MLX — Metal GPU acceleration."""

    MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v3"

    def __init__(self):
        self._model = None
        self._executor = ThreadPoolExecutor(max_workers=2)

    async def initialize(self):
        loop = asyncio.get_running_loop()
        self._model = await loop.run_in_executor(
            self._executor, self._load_model
        )

    def _load_model(self):
        from parakeet_mlx import from_pretrained
        return from_pretrained(self.MODEL_ID)

    async def transcribe(self, audio_path: Path) -> str:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            self._executor, self._transcribe_sync, audio_path
        )

    async def transcribe_bytes(self, audio_bytes: bytes) -> str:
        # Write to temp file — parakeet-mlx needs a file path
        # (uses FFmpeg internally for format handling)
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            self._executor, self._transcribe_bytes_sync, audio_bytes
        )

    def _transcribe_sync(self, audio_path: Path) -> str:
        result = self._model.transcribe(str(audio_path))
        return result.text

    def _transcribe_bytes_sync(self, audio_bytes: bytes) -> str:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
            tmp.write(audio_bytes)
            tmp.flush()
            result = self._model.transcribe(tmp.name)
            return result.text
```

### Key technical decisions

- **Primary backend:** `parakeet-mlx` on macOS — Metal GPU acceleration, bfloat16 by default
- **Model:** `mlx-community/parakeet-tdt-0.6b-v3` (auto-downloaded from HuggingFace on first use, cached locally)
- **One-pass:** Full audio processed in single pass. For very long recordings (>10 min), parakeet-mlx supports chunking with overlap: `model.transcribe(path, chunk_duration=120, overlap_duration=15)`
- **Timestamps:** parakeet-mlx returns word-level timestamps for free — useful for future features (highlights, navigation)
- **Future Linux:** Add `transcription_onnx.py` with `SherpaOnnxBackend` implementing the same `TranscriptionBackend` protocol. The service auto-detects platform
- **FFmpeg:** parakeet-mlx requires FFmpeg for audio format handling. Already common on dev machines; add to install.sh check

### Model management

parakeet-mlx auto-downloads from HuggingFace Hub on first `from_pretrained()` call. Model is cached in the standard HuggingFace cache (`~/.cache/huggingface/`). No manual download step needed — this is a significant UX improvement over sherpa-onnx's manual tar.bz2 download.

Optional config override for custom model path:

```yaml
# ~/.parachute/config.yaml
transcription:
  enabled: true
  # model_id: mlx-community/parakeet-tdt-0.6b-v3  # default, override if needed
```

### Server startup integration

In `server.py` lifespan, after BrainDB and before scheduler:

```python
# Initialize transcription service (optional — skip if backend not available)
from parachute.core.transcription import TranscriptionService
ts = TranscriptionService.from_config(settings)
if ts:
    await ts.initialize()
    get_registry().publish("TranscriptionService", ts)
    logger.info("Transcription service initialized")
else:
    logger.info("Transcription service: no backend available, skipping")
```

### Bot connector integration

Wire `transcribe_audio` on the server reference object (in `server.py` where `SimpleNamespace` is built for bots). This satisfies the existing `getattr(self.server, "transcribe_audio", None)` pattern in all three connectors.

```python
async def transcribe_audio(audio_data) -> str:
    ts = get_registry().get("TranscriptionService")
    if not ts:
        raise RuntimeError("Transcription service not available")
    if isinstance(audio_data, (bytes, bytearray)):
        return await ts.transcribe_bytes(audio_data)
    return await ts.transcribe(Path(audio_data))

server_ref.transcribe_audio = transcribe_audio
```

### Dependencies

Add to `pyproject.toml`:
```toml
"parakeet-mlx>=0.3.0; sys_platform == 'darwin'",
```

No `sherpa-onnx` dependency yet — add when Linux backend is implemented.

Ensure FFmpeg is available (for parakeet-mlx audio loading). Add check to `install.sh`.

### Files changed

| File | Action |
|------|--------|
| `parachute/core/transcription.py` | **New** — TranscriptionService + backend protocol |
| `parachute/core/transcription_mlx.py` | **New** — ParakeetMLXBackend |
| `parachute/server.py` | Modify — initialize TranscriptionService at startup, wire `transcribe_audio` |
| `parachute/config.py` | Modify — add transcription config fields |
| `pyproject.toml` | Modify — add parakeet-mlx dep (macOS-conditional) |
| `install.sh` | Modify — check FFmpeg availability |

### Acceptance criteria

- [ ] `TranscriptionService` auto-detects macOS and uses `ParakeetMLXBackend`
- [ ] `transcribe(audio_path)` returns text for a WAV file
- [ ] `transcribe_bytes(data)` returns text for raw audio bytes
- [ ] Inference runs in ThreadPoolExecutor, doesn't block event loop
- [ ] Model auto-downloads from HuggingFace on first use
- [ ] Bot connectors can use `transcribe_audio` for voice messages
- [ ] Graceful skip if parakeet-mlx not installed (server still starts)
- [ ] Service published to registry as `"TranscriptionService"`
- [ ] Backend protocol allows future sherpa-onnx Linux backend without changing callers

---

## Phase 2: Voice Entry Endpoint

New combined endpoint in the Daily module: upload audio + create entry + transcribe in background. One request from the app kicks off the full pipeline.

### Endpoint: `POST /api/daily/entries/voice`

```
POST /api/daily/entries/voice
Content-Type: multipart/form-data

Fields:
  file: audio file (WAV, any sample rate)
  date: YYYY-MM-DD (optional, defaults to today)
  duration_seconds: float (optional, for UI display)

Response (201):
  {
    "entry_id": "2026-03-14-10-30-45-123456",
    "status": "processing",
    "audio_path": "/Users/x/.parachute/daily/assets/2026-03-14/abc123_recording.wav"
  }
```

### Implementation in `module.py`

```python
@router.post("/entries/voice", status_code=201)
async def create_voice_entry(
    file: UploadFile,
    date: str | None = Form(None),
    duration_seconds: float | None = Form(None),
):
    # 1. Save audio (reuse asset upload logic)
    audio_path = await _save_audio(file, date_str)

    # 2. Create entry with status "processing"
    entry = await _create_entry(
        graph, date_str,
        content="",
        metadata={
            "entry_type": "audio",
            "audio_path": str(audio_path),
            "duration_seconds": duration_seconds,
            "transcription_status": "processing",
        },
    )

    # 3.Kick off background transcription
    asyncio.create_task(
        _transcribe_and_cleanup(graph, entry["entry_id"], audio_path)
    )

    return entry
```

### Background task: `_transcribe_and_cleanup()`

```python
async def _transcribe_and_cleanup(graph, entry_id: str, audio_path: Path):
    """Background: transcribe audio → update entry → trigger cleanup Caller."""
    ts = get_registry().get("TranscriptionService")
    if not ts:
        await _update_entry_status(graph, entry_id, "failed",
                                    error="Transcription service unavailable")
        return

    try:
        # Transcribe
        raw_text = await ts.transcribe(audio_path)
        if not raw_text.strip():
            await _update_entry_status(graph, entry_id, "failed",
                                        error="No speech detected")
            return

        # Update entry with raw transcription
        await _update_entry_content(
            graph, entry_id, raw_text,
            metadata={"transcription_status": "transcribed",
                      "transcription_raw": raw_text}
        )

        # Auto-trigger cleanup Caller
        await _trigger_cleanup_caller(entry_id, graph)

    except Exception as e:
        logger.error(f"Transcription failed for {entry_id}: {e}")
        await _update_entry_status(graph, entry_id, "failed",
                                    error=str(e))
```

### Status transition update

Extend `VALID_TRANSCRIPTION_STATUSES` and `VALID_TRANSCRIPTION_TRANSITIONS`:

```python
VALID_TRANSCRIPTION_STATUSES = {"processing", "transcribed", "complete", "failed"}
VALID_TRANSCRIPTION_TRANSITIONS = {
    "processing": {"transcribed", "complete", "failed"},
    "transcribed": {"complete", "failed"},
    "failed": {"processing"},       # retry
    "complete": set(),              # terminal
}
```

The `"transcribed"` status means raw Parakeet output is in the entry, cleanup is pending. App can show this text immediately — it's readable, just not polished.

### Files changed

| File | Action |
|------|--------|
| `modules/daily/module.py` | Modify — new endpoint, background task, status transitions |

### Acceptance criteria

- [ ] `POST /api/daily/entries/voice` accepts audio + metadata, returns entry ID
- [ ] Audio saved to assets directory
- [ ] Entry created in graph with `transcription_status: "processing"`
- [ ] Background task transcribes and updates entry content + status to `"transcribed"`
- [ ] On transcription failure, entry marked `"failed"` with error in metadata
- [ ] Empty transcription (no speech) handled gracefully
- [ ] `"transcribed"` added as valid status with correct transitions

---

## Phase 3: Cleanup Caller

A built-in Caller that reads raw transcription from an entry and writes back polished text. Uses the Caller infrastructure (direct execution for v1) with a new `update_entry` tool.

### New tool: `update_entry`

Added to `daily_agent_tools.py`. Allows a Caller to modify an existing Note's content — different from `write_output` which creates Cards.

```python
@tool(
    "update_entry",
    "Update a journal entry's content. Use for cleaning up or rewriting an entry.",
    {"entry_id": str, "content": str}
)
async def update_entry(args: dict[str, Any]) -> dict[str, Any]:
    entry_id = args.get("entry_id", "").strip()
    content = args.get("content", "").strip()
    # Validate, then update Note.content in graph
    await graph.execute_cypher(
        "MATCH (e:Note {entry_id: $entry_id}) "
        "SET e.content = $content",
        {"entry_id": entry_id, "content": content},
    )
    return {"content": [{"type": "text", "text": f"Updated entry {entry_id}"}]}
```

### Built-in Caller definition

Seeded in the graph during `_ensure_new_columns()` if it doesn't exist:

```python
{
    "name": "transcription-cleanup",
    "display_name": "Transcription Cleanup",
    "description": "Cleans up voice transcriptions: removes filler words, fixes grammar, adds punctuation and paragraph breaks. Preserves the speaker's voice.",
    "system_prompt": CLEANUP_SYSTEM_PROMPT,  # see below
    "tools": ["read_journal", "update_entry"],
    "schedule_enabled": False,  # not scheduled — triggered by transcription pipeline
    "enabled": True,
    "trust_level": "direct",  # runs in-process, no Docker needed
}
```

### System prompt

```markdown
You are a transcription cleanup assistant. You receive raw speech-to-text output
and produce clean, readable text.

## Rules

- Remove filler words: "um", "uh", "like", "you know", "I mean", "so", "right"
- Fix grammar and sentence structure
- Add proper punctuation (periods, commas, question marks)
- Create paragraph breaks at natural topic transitions
- Very light restructuring for readability — combine fragments, smooth transitions
- Preserve the speaker's voice, tone, and meaning exactly
- Do NOT summarize, add commentary, or change the substance
- Do NOT add headers, bullet points, or other structural formatting unless
  the speaker clearly intended a list
- Output ONLY the cleaned text — no preamble, no explanation

## Process

1. Read the journal entry for the given date using read_journal
2. Clean up the text following the rules above
3. Write the cleaned text back using update_entry with the entry_id provided
```

### Auto-trigger mechanism

In `_transcribe_and_cleanup()` (Phase 2), after transcription completes:

```python
async def _trigger_cleanup_caller(entry_id: str, graph):
    """Trigger the cleanup Caller on a specific entry."""
    from parachute.core.daily_agent import run_daily_agent

    # Extract date from entry_id (format: YYYY-MM-DD-HH-MM-SS-ffffff)
    date = entry_id[:10]

    try:
        result = await run_daily_agent(
            vault_path=_vault_path,
            agent_name="transcription-cleanup",
            date=date,
            force=True,  # always run, even if this date was processed before
            # Custom prompt that includes the entry_id
            build_prompt_fn=lambda config, d, od: (
                f"Clean up the voice transcription for entry {entry_id} "
                f"from {d}. Read the journal, then use update_entry to write "
                f"the cleaned version back. The entry_id is: {entry_id}"
            ),
        )

        if result.get("status") == "completed":
            # Update status to complete
            await graph.execute_cypher(
                "MATCH (e:Note {entry_id: $eid}) SET e.metadata_json = $meta",
                # ... merge metadata with transcription_status: "complete"
            )
        else:
            logger.warning(f"Cleanup Caller returned: {result}")
            # Entry stays at "transcribed" — raw text is still readable
    except Exception as e:
        logger.error(f"Cleanup Caller failed for {entry_id}: {e}")
        # Don't mark as failed — raw transcription is fine
```

The key design decision: **if the Caller fails, the entry stays at "transcribed" with raw text visible**. The raw Parakeet output is perfectly readable — it just has filler words and missing punctuation. The user isn't blocked.

### Entry versioning

Raw transcription is preserved in `metadata_json.transcription_raw` (set in Phase 2 when transcription completes). This enables a future "show original" toggle in the app.

### Files changed

| File | Action |
|------|--------|
| `parachute/core/daily_agent_tools.py` | Modify — add `update_entry` tool |
| `modules/daily/module.py` | Modify — seed cleanup Caller, wire auto-trigger |

### Acceptance criteria

- [ ] `update_entry` tool updates Note.content in graph
- [ ] `transcription-cleanup` Caller seeded on first startup
- [ ] Caller reads raw transcription, writes back polished text
- [ ] Auto-triggered after transcription completes
- [ ] Entry statustransitions: `"transcribed"` → `"complete"` on success
- [ ] Raw transcription preserved in `metadata_json.transcription_raw`
- [ ] Caller failure doesn't block the user — entry stays at `"transcribed"` with raw text

---

## Technical Considerations

**Memory budget:** parakeet-mlx uses Apple's unified memory architecture. The 0.6B parameter model in bfloat16 requires ~2 GB unified memory. On a Mac Mini with 16 GB, this is comfortable alongside the rest of the server. On 8 GB machines it's tight but workable — the model loads once and stays resident.

**Concurrency:** Two concurrent transcriptions max (`max_workers=2`). If a third request arrives while two are processing, it queues in the executor. This is fine for single-user Parachute Computer.

**Audio format:** parakeet-mlx uses FFmpeg internally, so it accepts any audio format (WAV, Opus, M4A, etc.). The app records at 16 kHz mono WAV by default. No format restrictions needed on the endpoint — FFmpeg handles conversion.

**Model auto-download:** parakeet-mlx downloads from HuggingFace Hub on first `from_pretrained()`. The model is ~1.2 GB (bfloat16). This happens once; subsequent loads use the cache at `~/.cache/huggingface/`. First startup will be slow — log clearly that model is downloading.

**Backend not available:** If parakeet-mlx isn't installed or the platform isn't macOS, `TranscriptionService.from_config()` returns None. The voice entry endpoint returns 503 ("Transcription not available"). Bot connectors get the existing "voice messages not supported" fallback. Server starts fine.

**Cleanup Caller runs direct (not sandboxed):** The built-in cleanup Caller has `trust_level: "direct"` — it runs in-process, no Docker needed. It only reads journal entries and updates entry content. No filesystem access, no untrusted code. Sandboxing is overhead without benefit here.

**Orphaned entries:** Entries stuck in `"processing"` for >1 hour should be marked `"failed"`. Add a lightweight check in the scheduler or server startup.

## Dependencies & Risks

- **parakeet-mlx:** macOS-only (Apple MLX framework). Conditional dependency in pyproject.toml: `"parakeet-mlx>=0.3.0; sys_platform == 'darwin'"`. Not available on Linux — future work adds a sherpa-onnx backend.
- **FFmpeg:** Required by parakeet-mlx for audio loading. Common on dev machines (Homebrew: `brew install ffmpeg`). Add check to `install.sh`.
- **HuggingFace Hub:** Model auto-downloads on first use (~1.2 GB). Requires internet on first startup. Subsequent startups use cached model.
- **Parakeet V3 quality:** Proven in the Flutter app. No punctuation/capitalization in V3 output — the LLM cleanup step handles this. (V2 has native punctuation but is English-only.)
- **Linux support:** Deferred. When needed, add `transcription_onnx.py` with `SherpaOnnxBackend` using `sherpa-onnx` pip package. The backend protocol makes this a clean addition.

## Out of Scope

- sherpa-onnx Linux backend (future — add when Linux deployment is active)
- App-side changes (Flutter upload flow, processing states, UI) — separate issue
- Hosted/paid tier with API-based transcription
- Heavy LLM transformations (summarization, task extraction) — future Callers
- Custom cleanup Caller configuration UI
