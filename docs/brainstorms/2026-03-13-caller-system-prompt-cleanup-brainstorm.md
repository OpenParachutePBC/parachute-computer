---
date: 2026-03-13
topic: caller-system-prompt-cleanup
status: brainstorm
priority: P1
issue: #236
---

# Caller System Prompt Cleanup

## What We're Building

Remove the Claude Code preset from Daily caller system prompts so callers behave as focused, specialized agents rather than general-purpose coding assistants.

Currently, the Docker entrypoint wraps every caller's system prompt in `preset: "claude_code"`, which prepends the full Claude Code system prompt — file editing conventions, git workflows, Bash tool instructions, PR creation patterns, etc. This is noise for an agent whose job is "read journal entries, write a reflection."

The fix: pass the caller's system prompt as a plain string, matching what `_run_direct()` already does for non-Docker callers.

## Why This Approach

**Direct callers already work this way.** `_run_direct()` in `daily_agent.py` passes `system_prompt` as a plain string to the SDK (line 478) — no preset. Sandboxed callers should match.

We considered four approaches:

1. **Drop the preset entirely** ← chosen
2. Filtered preset (strip irrelevant Claude Code sections) — fragile, maintenance burden
3. Custom "caller" preset — over-engineered for current needs
4. Prompt override layer ("ignore Bash/file tools") — competing instructions are worse than no instructions

The Claude Code CLI's built-in tools (Bash, Read, Write, Edit) will still technically be available, but without the system prompt coaching the agent to use them, callers won't reach for them. The caller's own prompt already guides tool usage explicitly ("use `read_journal`, use `write_output`"). Prompt-based steering is sufficient for now; if callers start using CLI tools inappropriately, we can add an explicit preamble later.

## Key Decisions

- **No Claude Code preset for callers**: Change entrypoint.py to pass system_prompt as a plain string, not `{type: "preset", preset: "claude_code", append: system_prompt}`
- **Match direct execution behavior**: Sandboxed and direct callers should see the same system prompt — no behavioral divergence based on execution mode
- **Start minimal, add later**: Don't add a "caller preamble" or tool restrictions yet. Only add guardrails if callers demonstrate problematic tool usage
- **No changes to caller prompt templates**: The existing system prompts (e.g. daily-reflection) are already well-crafted for this use case

## Open Questions

- **Session resume**: Does removing the preset affect session resumption behavior? The CLI stores the system prompt in transcripts — changing it mid-session might force a fresh start. Need to verify.
- **Future caller types**: Some callers might legitimately need filesystem access (e.g., a caller that reads/writes files in the vault). When that happens, we can add tools selectively rather than re-enabling the full preset.

## Next Steps

→ `/plan #236` for implementation details
