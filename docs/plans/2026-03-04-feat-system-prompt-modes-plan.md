---
title: System Prompt Modes — converse + cocreate
type: feat
date: 2026-03-04
issue: 193
---

# System Prompt Modes — converse + cocreate

Replace the one-size-fits-all Claude Code preset with two explicit session modes: **converse** (thinking partner, no coding preset, Parachute identity) and **cocreate** (agentic, full tooling, Cowork-flavored). Default switches from always-on Claude Code preset to `converse`.

## Acceptance Criteria

- [ ] `mode` field accepted on `ChatRequest` (`"converse"` | `"cocreate"`, default `"converse"`)
- [ ] `mode` persisted on `Session` / `SessionCreate` and stored in `Parachute_Session` graph node
- [ ] `mode` returned in session API responses and `ChatSession` Flutter model
- [ ] `converse` mode uses a new Parachute identity prompt with `use_claude_code_preset=False` — no coding scaffolding
- [ ] `cocreate` mode uses Claude Code preset + updated Parachute append content (current behavior, improved framing)
- [ ] `prompt_source` in `PromptMetadataEvent` reflects the mode: `"converse"` or `"claude_code_preset"`
- [ ] Flutter app sends `mode` in chat request; reads it back from session
- [ ] `/prompt/preview` endpoint respects `mode` param

## Context

**Pattern to follow**: `mode` mirrors `trust_level` in every layer — same shape in models, graph schema, orchestrator, and Flutter. Wherever `trust_level` is wired, `mode` goes next to it.

**Key files:**
- `computer/parachute/models/requests.py` — `ChatRequest`
- `computer/parachute/models/session.py` — `Session`, `SessionCreate`, `SessionUpdate`
- `computer/parachute/db/graph_sessions.py` — schema + CRUD
- `computer/parachute/core/orchestrator.py` — `DEFAULT_VAULT_PROMPT`, `run_streaming()`, `_build_system_prompt()`
- `computer/parachute/api/prompts.py` — preview endpoint
- `app/lib/features/chat/models/chat_session.dart` — `ChatSession`
- `app/lib/features/chat/providers/chat_message_providers.dart` — `streamChat()` call

## Implementation

### 1. Two prompt constants in `orchestrator.py`

Replace `DEFAULT_VAULT_PROMPT` with two constants:

**`CONVERSE_PROMPT`** — full replacement prompt, no preset:
```
# Parachute

You are Parachute, [user]'s thinking partner and memory extension.

## Your Role
Help [user] think clearly, explore ideas, remember context, and make connections.
This is a collaborative thinking relationship — not a task queue.

## How to Engage
- Think alongside, not just for — ask questions that help develop their thinking
- Be direct: skip flattery, no filler phrases, respond to what's actually being asked
- Make connections between what you know about their projects, interests, and past thinking
- One question at a time — pick the best one, not all of them

## Vault Context
Search the vault when [user] asks about their own thoughts, projects, or history,
or when personalized context would improve your response.

### Vault Tools (mcp__parachute__*)
- **mcp__parachute__search_sessions** — search past conversations
- **mcp__parachute__list_recent_sessions** — recent chat sessions
- **mcp__parachute__get_session** — read a specific conversation
- **mcp__parachute__search_journals** — search Daily voice journal entries
- **mcp__parachute__list_recent_journals** — recent journal dates
- **mcp__parachute__get_journal** — read a specific day's journal

### Web Tools
- **WebSearch** — current information, news, research
- **WebFetch** — read a specific URL

## Handling Attachments
- **Images**: Use the Read tool to view and describe them — don't just acknowledge
- **PDFs / text files**: Read and engage with the content directly

## Skills
Skills in `.skills/` extend your capabilities for specific tasks.
When a task seems to call for one, invoke it with the Skill tool.
```

**`COCREATE_PROMPT_APPEND`** — appended to Claude Code preset (replaces current `DEFAULT_VAULT_PROMPT` append content):
```
## Parachute Context

You are running as Parachute in cocreate mode — an agentic partner for building,
writing, coding, and creating. The project's CLAUDE.md or AGENTS.md defines
conventions and orientation for this specific context.

## Vault Tools Available (mcp__parachute__*)
The same vault tools from converse mode are available for personal context:
search_sessions, search_journals, get_journal, list_recent_sessions, etc.

## Skills
Skills in `.skills/` extend your capabilities. Check for relevant skills
before starting unfamiliar task types.

## Working Style
- For multi-step tasks, use TodoWrite to track progress visibly
- Clarify ambiguous requests before executing — simple-sounding tasks are often
  underspecified; asking once upfront prevents wasted effort
- Loop in the user at natural checkpoints, especially before irreversible actions
```

### 2. Python backend changes

**`computer/parachute/models/requests.py`** — add to `ChatRequest`:
```python
mode: Optional[str] = Field(
    default=None,
    description="Session mode: 'converse' or 'cocreate'. Persisted on session creation.",
)
```

**`computer/parachute/models/session.py`** — add `mode: Optional[str] = None` to `Session`, `SessionCreate`, `SessionUpdate`.

**`computer/parachute/db/graph_sessions.py`**:
- Add `"mode": "STRING"` to `Parachute_Session` schema dict
- Add `"mode": session.mode` to `create_session()` INSERT params and Cypher
- Add `mode` to `update_session()` (alongside `trust_level` handling)
- Read `mode` back in `_row_to_session()`

**`computer/parachute/core/orchestrator.py`**:
- Replace `DEFAULT_VAULT_PROMPT` with `CONVERSE_PROMPT` and `COCREATE_PROMPT_APPEND`
- Add `mode: Optional[str] = None` to `run_streaming()` signature
- Resolve effective mode: `mode or session.mode or "converse"` (request > session > default)
- Pass mode to `_build_system_prompt()`
- In `_build_system_prompt()`: add `mode: str = "converse"` param
  - If `mode == "converse"`: return `CONVERSE_PROMPT` with `prompt_source="converse"`
  - If `mode == "cocreate"`: use existing append path with `COCREATE_PROMPT_APPEND` instead of `DEFAULT_VAULT_PROMPT`, `prompt_source="claude_code_preset"`
- Persist mode on session at creation: pass through `SessionCreate`
- Update `is_full_prompt` logic: converse mode is always `is_full_prompt=True`

**`computer/parachute/api/prompts.py`** — add `mode: str = Query("converse")` param to `/prompt/preview`, pass to `_build_system_prompt()`.

### 3. Flutter app changes

**`app/lib/features/chat/models/chat_session.dart`**:
```dart
final String? mode;
// in constructor, fromJson, toJson, copyWith — same pattern as trustLevel
```

**`app/lib/features/chat/providers/chat_message_providers.dart`**:
- Add `mode` to `ChatMessagesState` and `sendMessage()` signature
- Pass `mode` in `_service.streamChat()` call alongside `trustLevel`
- Read `mode` back from session-created events (same as `trustLevel` event handling)

**`app/lib/features/chat/services/chat_service.dart`** (or equivalent HTTP service):
- Add `mode` to the request body map: `if (mode != null) 'mode': mode`

### 4. Prompt source in transparency event

Update `PromptMetadataEvent` `prompt_source` values:
- Converse mode → `"converse"`
- Cocreate mode → `"claude_code_preset"` (existing value, unchanged)
- Custom prompt override → `"custom"` (unchanged)

This makes `/prompt/preview` and the app's prompt transparency UI correctly reflect which mode is active.

### 5. Remove vault-level skills pipeline (cleanup)

The vault-level skills system pre-dates `setting_sources=["project"]` and is now over-engineering. Skills per project live in `.claude/skills/` and the SDK discovers them natively.

**Delete or gut `computer/parachute/core/skills.py`**: remove `generate_runtime_plugin`, `discover_skills`, `get_skills_for_system_prompt`, `SkillInfo`, related helpers. File can be removed entirely.

**Remove from `_discover_capabilities()` in `orchestrator.py`**:
- `discover_skills(Path.home())` call
- `generate_runtime_plugin(...)` call
- `skill_names` from `CapabilityBundle`

**Remove legacy plugin system** — `computer/parachute/core/plugins.py`: `discover_plugins` and `get_plugin_dirs` are labeled legacy, nothing actively uses them. Remove calls from `_discover_capabilities()` and delete the plugin discovery block.

**Remove from `CapabilityBundle`**: `skill_names` field.

Note: `plugin_dirs` parameter itself stays — it's the SDK mechanism we use. We just stop generating runtime plugin dirs from the vault. If `plugin_dirs` ends up empty every call, we can remove it later.

## What's Not In This Plan

- Graph-native instruction nodes (`Parachute_Instruction` table) — future iteration
- Project-scoped instructions on `ContainerEnv` — future iteration
- App UI for toggling mode (button/toggle in chat toolbar) — separate issue
- `converse` mode tool restrictions at the SDK level (no bash, no file writes) — the prompt boundary is sufficient for v1; hard enforcement comes later
- AGENTS.md support alongside CLAUDE.md
- Mid-stream injection improvements — works but awkward; separate future work

## References

- Brainstorm: `docs/brainstorms/2026-03-04-system-prompt-modes-project-memory-brainstorm.md`
- Claude Desktop published prompt: https://platform.claude.com/docs/en/release-notes/system-prompts
- Claude Cowork leaked prompt: https://github.com/EliFuzz/awesome-system-prompts/blob/main/leaks/anthropic/2026-01-16_prompt_cowork.md
- Claude Code prompts (community-extracted): https://github.com/Piebald-AI/claude-code-system-prompts
