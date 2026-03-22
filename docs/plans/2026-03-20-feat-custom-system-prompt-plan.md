---
title: "Custom System Prompt: Replace Claude Code Preset"
type: feat
date: 2026-03-20
issue: 297
---

# Custom System Prompt: Replace Claude Code Preset

Replace the Claude Code preset (both system prompt and tools preset) with a Parachute-native system prompt and explicit tool list. One unified mode, not two — Parachute is Parachute, not "converse vs cocreate."

## Problem

Parachute currently has two paths:
- **Converse mode** (`is_full_prompt=True`): Custom Parachute identity prompt, no Claude Code preset. But it's thin — missing tool guidance, coding conventions, and task execution patterns.
- **Cocreate mode** (`is_full_prompt=False`): Claude Code preset + Parachute append. Gets all the good coding behavior but also terminal-developer framing, AskUserQuestion, PlanMode, extreme brevity instructions, and CLI-specific language.

Neither is right. We want the *good parts* of the Claude Code preset (tool usage guidance, coding conventions, task execution, security) rewritten in Parachute's voice, with Parachute-specific additions.

## Solution

One Parachute system prompt that absorbs the valuable parts of Claude Code's preset. Paired with an explicit `tools` list that declares exactly which tools exist per session — no preset black box.

### Three Changes

1. **New system prompt** — a single `PARACHUTE_PROMPT` constant replacing both `CONVERSE_PROMPT` and `COCREATE_PROMPT_APPEND`
2. **Explicit tool list** — use the SDK's `tools` field (not `allowed_tools`) to declare which tools exist
3. **Fix the SDK wrapper bug** — `claude_sdk.py` maps `tools` to `allowed_tools`, but these are different SDK fields

## Acceptance Criteria

- [x] `PARACHUTE_PROMPT` replaces `CONVERSE_PROMPT` and `COCREATE_PROMPT_APPEND`
- [x] All sessions use `system_prompt=PARACHUTE_PROMPT` (full replacement, `use_claude_code_preset=False`)
- [x] `tools` parameter correctly maps to SDK `tools` field (not `allowed_tools`)
- [x] Explicit tool list: `Read`, `Write`, `Edit`, `Bash`, `Glob`, `Grep`, `WebSearch`, `WebFetch`, `Agent`, `TodoWrite`, `NotebookEdit`, `BashOutput`, `KillBash`
- [x] `AskUserQuestion`, `EnterPlanMode`, `ExitPlanMode` excluded from tool list
- [x] Tool restriction prompt appendix (lines 504-516 in orchestrator.py) removed — no longer needed
- [x] `disallowed_tools` used as safety net for the three excluded tools
- [ ] Coding quality is equivalent or better than current cocreate mode (manual testing)
- [x] Existing tests pass

## The Parachute System Prompt

Written from scratch but informed by the Claude Code preset audit. Sections:

### Identity & Role
```
# Parachute

You are Parachute — an AI partner for thinking, building, and remembering.

You operate as an orchestrated agent within the Parachute system, communicating
with users through a Flutter app, Telegram, Discord, or other interfaces.
You are not a CLI tool — there is no terminal. Communicate naturally.
```

### Tone & Style
```
## Tone and Style
- Be concise and direct — skip preamble, don't explain what you're about to do
- Don't add unnecessary postamble (summaries of what you did) unless asked
- Match the user's energy: brief questions get brief answers, deep questions
  get thoughtful responses
- Only use emojis if the user does
```

*Adapted from Claude Code's tone section. Drops "fewer than 4 lines" and "one word answers" — those are CLI-specific. Keeps the anti-preamble/postamble guidance which is universally good.*

### Tool Usage
```
## Tool Usage
- Use Read (not cat/head/tail) to read files
- Use Edit (not sed/awk) to modify files
- Use Write (not echo/cat heredoc) to create files
- Use Grep (not grep/rg) to search file contents
- Use Glob (not find/ls) to find files by pattern
- Reserve Bash for commands that genuinely need a shell
- Call multiple tools in parallel when the calls are independent
- When doing broad file search, use the Agent tool to delegate
```

*Kept nearly verbatim from Claude Code — this is practical, correct guidance.*

### Code Conventions
```
## Code Conventions
- Mimic existing code style — match frameworks, naming, typing, patterns
- Never assume a library is available; check imports and dependencies first
- When creating new components, study existing ones for patterns to follow
- When editing code, read surrounding context (especially imports) first
- Follow security best practices: never expose secrets, keys, or credentials
- Do not add comments unless asked
- Do not add features, refactoring, or "improvements" beyond what was asked
- Do not create files unless necessary
- Read code before modifying it
```

*Kept from Claude Code. This is universally good coding guidance.*

### Task Execution
```
## Doing Tasks
For software engineering tasks:
1. Understand the codebase first — use search tools extensively
2. Plan multi-step work with TodoWrite for visibility
3. Implement the solution
4. Verify with tests if a test framework exists (check README or search first)
5. Run lint/typecheck if available

Never commit changes unless explicitly asked.
```

*Simplified from Claude Code. Drops the verbose framing but keeps the workflow.*

### Proactiveness
```
## Proactiveness
When asked to do something, do it — including reasonable follow-up actions.
Don't surprise the user with actions they didn't ask for.
When uncertain about scope, ask before acting.
```

### Vault & Memory
```
## Vault & Memory
Search the vault when the user references their own thoughts, projects, or history,
or when personalized context would improve your response.

Vault tools (mcp__parachute__*) provide access to:
- Past conversations and exchanges
- Journal entries
- Brain graph (entities, relationships)
- Session tags and metadata
```

### Working Directory & Containers
```
## Working Directory
When a working directory is set, you have access to that project's files.
The project's CLAUDE.md defines conventions and context for that codebase.

## Skills
Skills in `.claude/skills/` extend your capabilities for specific tasks.
When a task matches a skill's trigger, invoke it with the Skill tool.
```

### Handling Attachments
```
## Handling Attachments
- Images: Use the Read tool to view and describe them — don't just acknowledge
- PDFs / text files: Read and engage with the content directly
```

### Safety
```
## Safety
- Assist with defensive security tasks only
- Do not generate or guess URLs unless helping with programming
- Be careful with destructive operations — prefer reversible actions
- Before irreversible actions (force push, delete, deploy), confirm with the user
```

*Adapted from Claude Code's security and "executing actions with care" sections.*

## Implementation

### Phase 1: Fix the SDK wrapper bug

**`computer/parachute/core/claude_sdk.py`**:

The `tools` parameter is currently mapped to `allowed_tools` (line 230), which controls auto-approval, not tool existence. Fix:

```python
# Before (wrong):
if tools is not None:
    options_kwargs["allowed_tools"] = tools

# After (correct):
if tools is not None:
    options_kwargs["tools"] = tools
```

Also add `disallowed_tools` parameter support:
```python
async def query_streaming(
    ...
    tools: list[str] | dict | None = None,      # Controls which tools exist
    disallowed_tools: list[str] | None = None,   # Hard-blocks specific tools
    ...
)
```

### Phase 2: Write the system prompt

**`computer/parachute/core/orchestrator.py`**:

Replace `CONVERSE_PROMPT` and `COCREATE_PROMPT_APPEND` with a single `PARACHUTE_PROMPT` constant assembled from the sections above.

### Phase 3: Wire it up

**`computer/parachute/core/orchestrator.py`** — in `_run_trusted()`:

```python
# Define Parachute's tool list — explicit, no preset
PARACHUTE_TOOLS = [
    "Read", "Write", "Edit", "Bash", "Glob", "Grep",
    "WebSearch", "WebFetch", "Agent", "TodoWrite",
    "NotebookEdit", "BashOutput", "KillBash",
]

# Safety net: hard-block tools we never want
PARACHUTE_DISALLOWED_TOOLS = [
    "AskUserQuestion", "EnterPlanMode", "ExitPlanMode",
]
```

In `_run_trusted()`, pass:
```python
async for event in query_streaming(
    prompt=actual_message,
    system_prompt=effective_prompt,     # Always full replacement
    tools=PARACHUTE_TOOLS,             # Explicit tool list
    disallowed_tools=PARACHUTE_DISALLOWED_TOOLS,
    ...
)
```

Remove:
- `use_claude_code_preset` parameter from `query_streaming` calls (always False now)
- `system_prompt_append` parameter (never used now — always full prompt)
- `is_full_prompt` logic (always True now)
- Tool restriction prompt appendix (lines 504-516) — tools are excluded at SDK level
- The converse/cocreate branching in `_build_system_prompt()`

### Phase 4: Simplify _build_system_prompt

`_build_system_prompt()` currently branches on mode. With one unified prompt, simplify:
- Always return `PARACHUTE_PROMPT` as the base
- Still append vault CLAUDE.md, MEMORY.md, context files, tool guidance, credentials
- `prompt_source` is always `"parachute"` (new value, replaces `"converse"` and `"claude_code_preset"`)
- `is_full_prompt` is always `True`

### Phase 5: Update the mode toggle

The Flutter mode toggle we just built (converse/cocreate selector in new chat empty state) stays in the UI but the behavior changes:
- For now, both modes use the same prompt and tools
- The `mode` field persists on the session for future use
- Later, modes can add emphasis (e.g., cocreate appends coding-specific sections) without being a fundamentally different system

## What's NOT In This Plan

- Removing the `mode` field — it stays, it's useful infrastructure for future differentiation
- Custom tools (artifacts, etc.) — future, via MCP
- Per-container/per-project prompt customization — future
- Graph-native instruction nodes — future
- Changes to sandboxed execution path — separate, follows the same pattern once trusted is validated
- Daily agent prompts — those have their own prompt system

## Testing Strategy

- Run existing test suite — no tests should break (the public interface is unchanged)
- Manual A/B: create a cocreate session (current behavior) and a new session (Parachute prompt) and compare on representative tasks:
  - "Read this file and explain what it does"
  - "Add a new API endpoint for X"
  - "Fix this bug: [paste error]"
  - "Refactor this function to be simpler"
- Verify: no AskUserQuestion attempts, no PlanMode attempts, good coding behavior, natural conversation

## Dependencies

- Claude Agent SDK v0.1.39+ (current) — `tools`, `allowed_tools`, `disallowed_tools` fields all present
- PR #299 merged (bypassPermissions for DIRECT trust) — already done

## References

- Brainstorm: `docs/brainstorms/2026-03-19-custom-system-prompt-brainstorm.md`
- Previous modes plan: `docs/plans/2026-03-04-feat-system-prompt-modes-plan.md`
- Claude Code preset (community-extracted): https://github.com/Piebald-AI/claude-code-system-prompts
- Claude Agent SDK types: `computer/.venv/.../claude_agent_sdk/types.py`
- SDK docs: https://platform.claude.com/docs/en/agent-sdk/python
