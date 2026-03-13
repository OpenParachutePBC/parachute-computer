---
title: "fix: Caller system prompt cleanup — drop Claude Code preset"
type: fix
date: 2026-03-13
issue: 236
---

# Caller System Prompt Cleanup

Remove the Claude Code preset from Daily caller system prompts so callers behave as focused, specialized agents rather than general-purpose coding assistants.

## Problem

The Docker entrypoint (`entrypoint.py`) unconditionally wraps every system prompt in `preset: "claude_code"`. This adds the full Claude Code system prompt — file editing conventions, git workflows, Bash instructions — to callers whose job is "read journal, write reflection." Direct callers (`_run_direct()`) already pass the system prompt as a plain string with no preset.

## Proposed Solution

Add a `use_preset` flag so callers can opt out of the Claude Code preset while sandboxed chat sessions keep it.

### Changes

**1. `computer/parachute/core/sandbox.py` — AgentSandboxConfig**

Add field:
```python
use_preset: bool = True  # Whether to wrap system_prompt in claude_code preset
```

Pass through to container stdin JSON (persistent mode, line ~835):
```python
if config.system_prompt:
    stdin_payload["system_prompt"] = config.system_prompt
    stdin_payload["use_preset"] = config.use_preset
```

Pass through as env var (ephemeral mode, line ~412):
```python
if not config.use_preset:
    args.extend(["-e", "PARACHUTE_NO_PRESET=1"])
```

**2. `computer/parachute/docker/entrypoint.py` — Respect the flag**

Replace lines 260-266:
```python
if system_prompt:
    use_preset = request.get("use_preset", True)
    if not use_preset or os.environ.get("PARACHUTE_NO_PRESET"):
        options_kwargs["system_prompt"] = system_prompt
    else:
        options_kwargs["system_prompt"] = {
            "type": "preset",
            "preset": "claude_code",
            "append": system_prompt,
        }
```

**3. `computer/parachute/core/daily_agent.py` — Callers opt out**

In `_run_sandboxed()`, when building `AgentSandboxConfig` (line ~342):
```python
sandbox_config = AgentSandboxConfig(
    ...
    system_prompt=system_prompt,
    use_preset=False,  # Callers don't need Claude Code preset
    ...
)
```

## Acceptance Criteria

- [x] Sandboxed callers receive only their personality prompt as system prompt (no Claude Code preset)
- [x] Sandboxed chat sessions continue to use the Claude Code preset (backward compatible)
- [x] Direct callers are unchanged (already pass plain string)
- [ ] Session resume still works for callers (test by running a caller twice)

## Context

- **Entrypoint is shared infrastructure**: Both callers and chat sandbox sessions go through `entrypoint.py`. Chat sessions benefit from the Claude Code preset (users may ask to write code). Callers don't.
- **Direct callers already work this way**: `_run_direct()` passes `system_prompt` as a plain string (line 478). This change makes sandboxed callers match.
- **CLI tools remain available**: The Claude Code CLI still registers Bash, Read, Write, Edit tools. Without the preset coaching the agent to use them, callers won't reach for them. If they do, a "caller preamble" can be added later.
- **Session resume**: Changing the system prompt format invalidates existing sessions. Callers already handle resume failures gracefully (lines 398-405) — stale sessions are cleared and the agent starts fresh.
