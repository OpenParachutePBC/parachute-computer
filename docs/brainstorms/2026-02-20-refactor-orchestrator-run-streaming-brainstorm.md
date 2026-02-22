---
title: "Refactor: Extract phases from orchestrator run_streaming()"
date: 2026-02-20
status: brainstorm
priority: P3
tags: [refactor, computer, orchestrator]
---

# Refactor: Extract phases from orchestrator run_streaming()

## What We're Exploring

`orchestrator.py` is 1,809 lines, and its central method `run_streaming()` accounts for roughly 700 of them — handling at least ten distinct concerns in a single contiguous block. The method has grown through legitimate accretion (attachment support, sandbox retry logic, MCP filtering, workspace capability filtering) and is now difficult to navigate, test in isolation, or reason about as a whole. Extracting logical phases into private methods would make the orchestrator maintainable again without touching any externally-observable behavior.

## Context

Reading `run_streaming()` reveals a clear layered structure that the code does not express in its organization:

**Phase 1 — Session setup (~lines 300–500):** Context loading, prompt construction, attachment saving, `UserMessageEvent` emission, interrupt/queue setup, and recovery mode handling.

**Phase 2 — Capability discovery (~lines 511–663):** MCP loading (`load_mcp_servers`, `resolve_mcp_servers`, `validate_and_filter_servers`), skill discovery (`discover_skills`, `generate_runtime_plugin`), plugin discovery (`discover_plugins`, `get_plugin_dirs`), trust level resolution (client param → session stored → workspace default → fallback), and two-stage capability filtering (trust-level filter then workspace `capabilities` allowlist).

**Phase 3a — Sandboxed execution (~lines 759–963):** Only reached when `effective_trust == "untrusted"`. Constructs `AgentSandboxConfig`, chooses persistent vs. ephemeral container, implements a three-tier resume strategy (SDK resume → history injection → fresh start), defines an inner `_process_sandbox_event()` async generator that handles session ID rewriting and early finalization, runs the retry loop, writes a synthetic transcript, and increments the message count. This block is ~200 lines and is effectively a second orchestrator nested inside `run_streaming()`. The mutable `sbx` dict is the tell: shared state between the inner function and the outer loop, signaling that these belong in a class method with instance attributes or a dedicated object.

**Phase 3b — Trusted execution (~lines 973–1200+):** Calls `query_streaming()` and translates raw SDK events (`system/init`, `assistant`, `user`, `result`, `permission_denied`, etc.) into typed SSE events (`InitEvent`, `TextEvent`, `ThinkingEvent`, `ToolUseEvent`, `PermissionRequestEvent`, …). Also handles early session finalization when the first SDK session ID arrives.

**Phase 4 — Finalization (~lines 1200+):** Message count increment, final `DoneEvent` construction, error cleanup.

The sandbox path is the clearest problem. Its inner `_process_sandbox_event()` function closes over `sbx`, `sandbox_sid`, `effective_trust`, `is_new`, `captured_model`, `message`, `agent_type`, `workspace_id`, and `actual_message`. That is nine captured variables — a strong sign that the function belongs as a method on a class (or at minimum a free function receiving those values explicitly).

## Why This Matters

- **Navigation cost.** Finding the trust resolution logic, or the sandbox retry strategy, requires reading past hundreds of lines of unrelated code. Every bug fix or feature addition in this method requires mentally parsing the whole thing.
- **Test surface.** None of the phases can be exercised in isolation today. Unit-testing "what happens when MCP load fails" requires constructing a full orchestrator call. Extracting `_discover_capabilities()` would let tests inject a fixture vault and assert on the returned capability bundle.
- **Sandbox complexity is growing.** The rich sandbox image brainstorm (`2026-02-18`) proposes adding image streaming and output rendering to the sandbox path. Adding more surface area to an already 200-line nested block will make it significantly harder to maintain.
- **Contributor ramp.** A new contributor looking at the sandbox retry logic has to first understand that they are inside `run_streaming()`, inside an `if effective_trust == "untrusted":` block, inside an `if await self._sandbox.is_available():` block, calling an inner function defined mid-loop. Extracting `_run_sandboxed()` makes this a named, findable thing.

## Proposed Approach

Extract four private methods, leaving `run_streaming()` as a thin coordinator:

**`_save_attachments(attachments, vault_path, session_id) -> tuple[str, list[str]]`**
Takes the raw attachment list, saves files to `Chat/assets/YYYY-MM-DD/`, returns the markdown block to append to the message and a list of failure descriptions. Currently ~60 lines inline. Fully synchronous (the `base64.b64decode` and `file_path.write_bytes` calls are blocking I/O — a separate cleanup opportunity noted in todo #046).

**`_discover_capabilities(agent, session, trust_level, workspace_config) -> CapabilityBundle`**
Returns a dataclass or typed dict containing `resolved_mcps`, `plugin_dirs`, `skill_names`, `agents_dict`, `effective_trust`, and any `WarningEvent` instances to emit. Encapsulates MCP loading, skill/plugin discovery, legacy plugin MCP merging, trust resolution, trust-level filtering, and workspace capability filtering. Currently ~150 lines inline.

**`_run_sandboxed(session, sandbox_config, sandbox_sid, actual_message, is_new, ...) -> AsyncGenerator`**
Contains everything inside the `if await self._sandbox.is_available():` block: container selection, resume strategy, the retry loop, the event processor (currently `_process_sandbox_event()`), transcript writing, and message count increment. The inner `_process_sandbox_event()` becomes a named method `_process_sandbox_event(self, event, sbx, sandbox_sid, effective_trust, ...)` rather than a closure, eliminating the `sbx` dict pattern.

**`_run_trusted(session, query_args, ...) -> AsyncGenerator`**
Contains the `async for event in query_streaming(...)` loop and all the SDK event translation logic. This is the larger of the two execution paths and its event-type dispatch table (system/init, assistant, user, result, permission_denied) is easier to read as a standalone method.

`run_streaming()` then becomes: setup → `_save_attachments` → `_discover_capabilities` → yield metadata events → `_run_sandboxed` or `_run_trusted` → finalize.

No signature changes to `run_streaming()` itself. No changes to the SSE event format or the session lifecycle.

## What We're NOT Doing

- No behavior changes. This is a pure refactor — same logic, different organization.
- No changes to the public API (`run_streaming`, `stop_stream`, `inject_message`, `grant_permission`, etc.).
- No changes to the SSE event format or the session lifecycle.
- No changes to the sandbox execution model or the trust level semantics.
- Not introducing new abstractions beyond the extracted methods (no Strategy pattern, no pipeline object — just private methods on `Orchestrator`).
- Not addressing the blocking I/O issues in attachment saving or plugin installation (separate todos).
- Not splitting `orchestrator.py` into multiple files yet — that is a larger structural change that can follow once the phases are cleanly named.

## Open Questions

- **`CapabilityBundle` shape.** Should `_discover_capabilities()` return a dataclass, a `TypedDict`, or individual return values? A dataclass (`@dataclass`) is explicit and avoids positional confusion. `TypedDict` avoids a new class for a one-caller function. Either works; the dataclass is preferable if we anticipate adding fields.
- **Error handling boundary.** `_discover_capabilities()` currently has a try/except that catches MCP load failures and converts them to a `WarningEvent` to emit later. Should the method return the warning as part of the bundle, or should it yield events directly? Returning the warning as data (rather than yielding) keeps the method pure and makes it easier to test.
- **`_process_sandbox_event` as inner vs. method.** The current inner function closes over many variables. Making it a proper method on `Orchestrator` is cleaner but requires threading those values as parameters or storing them as instance state during a call. A small `_SandboxCallContext` dataclass (not stored on `self`) could carry the per-call state without polluting instance attributes.
- **Order of operations for the agentic consolidation refactor.** The agentic ecosystem consolidation plan (`2026-02-19`) also proposes simplifying the orchestrator's discovery flow. These two refactors could conflict if they touch the same lines. Sequencing matters: this structural extraction should probably happen first, then the discovery simplification can target the now-isolated `_discover_capabilities()` method.

**Issue:** #82
