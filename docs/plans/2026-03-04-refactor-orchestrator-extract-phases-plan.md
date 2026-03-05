---
title: "Refactor: Extract phases from orchestrator run_streaming()"
type: refactor
date: 2026-03-04
issue: 82
priority: P2
labels: [computer]
---

# Orchestrator Phase Extraction

`run_streaming()` in `core/orchestrator.py` is 1,068 lines (lines 248–1316 of a 1,906-line file). It handles session setup, capability discovery, sandboxed execution, trusted execution, and finalization in a single contiguous block — with no named methods for any phase. Extract four private methods, leaving `run_streaming()` as a thin coordinator. No behavior changes.

> Priority bumped from P3 → P2: the method has grown 50% since the brainstorm was filed (estimated ~700 lines → actual 1,068) and is the primary landing zone for new orchestrator features.

## Acceptance Criteria

- [ ] `run_streaming()` body is ≤ 200 lines; each phase is a named private method call
- [ ] `_save_attachments()` exists as a class method and is tested in isolation
- [ ] `_discover_capabilities()` exists, returns a `CapabilityBundle` dataclass, and is tested in isolation
- [ ] `_run_sandboxed()` exists as an async generator class method; `_process_sandbox_event()` is no longer a closure
- [ ] `_run_trusted()` exists as an async generator class method
- [ ] No changes to `run_streaming()`'s public signature
- [ ] No changes to the SSE event format or session lifecycle
- [ ] All existing unit tests pass; new unit tests cover each extracted method

## Proposed Structure

After this refactor, `run_streaming()` reads as:

```python
async def run_streaming(self, ...) -> AsyncGenerator[dict, None]:
    # Phase 1: Setup
    session, actual_message, recovery_mode = await self._setup_session(...)
    attachment_block, attachment_failures = await self._save_attachments(attachments, ...)
    yield UserMessageEvent(...)

    # Phase 2: Capability discovery
    caps = await self._discover_capabilities(agent, session, trust_level, workspace_config)
    for warning in caps.warnings:
        yield warning

    # Phase 3: Execute
    if caps.effective_trust == "untrusted":
        async for event in self._run_sandboxed(session, caps, actual_message, ...):
            yield event
    else:
        async for event in self._run_trusted(session, caps, actual_message, ...):
            yield event

    # Phase 4: Finalize
    yield DoneEvent(...)
```

## Extractions

### `_save_attachments(attachments, vault_path, session_id) -> tuple[str, list[str]]`

- Currently ~60 lines inline in run_streaming
- Saves base64 attachments to `Chat/assets/YYYY-MM-DD/`
- Returns `(markdown_block, failure_descriptions)`
- Synchronous (blocking I/O — separate cleanup issue)
- Easy to unit-test in isolation with a temp dir

### `_discover_capabilities(agent, session, trust_level, workspace_config) -> CapabilityBundle`

Currently ~150 lines covering:
- MCP loading (`load_mcp_servers`, `resolve_mcp_servers`, `validate_and_filter_servers`)
- Skill/plugin discovery (`discover_skills`, `generate_runtime_plugin`, `discover_plugins`, `get_plugin_dirs`)
- Trust level resolution (client param → session stored → workspace default → fallback)
- Two-stage capability filtering (trust-level filter → workspace `capabilities` allowlist)
- Warning collection for MCP load failures

Returns a dataclass:

```python
@dataclass
class CapabilityBundle:
    resolved_mcps: list[...]
    plugin_dirs: list[Path]
    skill_names: list[str]
    agents_dict: dict[str, str]
    effective_trust: str
    warnings: list[dict]          # WarningEvents to yield before execution
```

Keeping warnings as returned data (rather than yielding inside) keeps the method pure and testable.

### `_run_sandboxed(session, caps, actual_message, ...) -> AsyncGenerator[dict, None]`

Currently the `if await self._sandbox.is_available():` block (~200 lines), including:
- Container selection (persistent vs. ephemeral)
- Three-tier resume strategy (SDK resume → history injection → fresh start)
- Retry loop
- Event processing (currently a closure `_process_sandbox_event`)
- Synthetic transcript writing
- Message count increment

**Key change:** `_process_sandbox_event()` becomes a proper class method `_process_sandbox_event(self, event, ctx: _SandboxCallContext)` rather than a closure over 9 variables. A small `_SandboxCallContext` dataclass carries the per-call state:

```python
@dataclass
class _SandboxCallContext:
    sbx: dict
    sandbox_sid: str | None
    effective_trust: str
    is_new: bool
    captured_model: str | None
    message: str
    agent_type: str
    session_id: str
    effective_working_dir: str | None
```

This dataclass is not stored on `self` — it's instantiated per `_run_sandboxed` call and passed through.

### `_run_trusted(session, caps, actual_message, ...) -> AsyncGenerator[dict, None]`

The `async for event in query_streaming(...)` loop and all SDK event translation (~200+ lines):
- `system/init` → `InitEvent`
- `assistant` → `TextEvent` / `ThinkingEvent` / `ToolUseEvent`
- `user` (tool results) → forwarded
- `result` → session finalization + `DoneEvent` prep
- `permission_denied` → `PermissionRequestEvent`

## Sequencing

Do phases in order — each is independently mergeable:

1. `_save_attachments` — standalone, no cross-dependencies
2. `_discover_capabilities` + `CapabilityBundle` — no async complexity
3. `_run_trusted` — large but self-contained async block
4. `_run_sandboxed` + `_SandboxCallContext` — most complex, saves the closure elimination for last

## What We're Not Doing

- No behavior changes; no API changes; no SSE format changes
- Not splitting `orchestrator.py` into multiple files (follow-on)
- Not fixing blocking I/O in `_save_attachments` (separate issue)
- No new design patterns (no Strategy, no pipeline) — just private methods

## Files Touched

- `computer/parachute/core/orchestrator.py` — primary changes
- `computer/tests/unit/test_orchestrator.py` — new unit tests for each extracted method

## References

- Brainstorm: `docs/brainstorms/` (filed 2026-02-20)
- Orchestrator: `computer/parachute/core/orchestrator.py` lines 248–1316
