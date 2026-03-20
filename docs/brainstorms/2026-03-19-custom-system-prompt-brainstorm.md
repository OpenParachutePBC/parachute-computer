# Custom System Prompt: Replacing the Claude Code Preset

**Status:** Brainstorm
**Priority:** P2
**Issue:** #297
**Date:** 2026-03-19
**Module:** computer

---

## What We're Building

A Parachute-native system prompt that replaces the Claude Code preset for coding sessions. This involves obtaining the current Claude Code preset, auditing what it does, deciding what to keep/drop/modify, and building a dynamic system prompt tailored to Parachute's orchestrator model.

## Why This Approach

### The Problem

Parachute currently uses the Claude Code preset (`claude_code` or equivalent) when configuring SDK sessions. This preset was designed for a human developer sitting at a terminal — it includes instructions for tools like AskUserQuestion and PlanMode, assumes interactive permission flows, and frames the assistant as a CLI tool. Parachute is a different kind of interface: an orchestrator mediating between users (via Flutter app, Telegram, Discord) and the Claude agent.

The mismatch causes:
- **Unwanted behaviors**: The model tries to use AskUserQuestion, enters PlanMode, asks for terminal-style confirmation
- **Wasted context**: Prompt space is spent on instructions for tools and workflows that don't apply
- **Fragile workarounds**: Permission pipe, tool interception callbacks, and system prompt patches to suppress default CLI behavior
- **Missed opportunity**: A custom prompt can encode Parachute-specific patterns (module awareness, trust levels, vault structure) that the generic preset knows nothing about

### What We Want

A system prompt that:
- Retains Claude Code's excellent coding capabilities (file operations, error handling, structured thinking)
- Drops terminal-developer framing (no AskUserQuestion, no PlanMode, no interactive confirmation)
- Adds Parachute context (module system, trust levels, vault structure, user preferences)
- Is dynamic — sections are assembled based on session context (module, trust level, container, user)
- Makes tool suppression at the callback level unnecessary — if the prompt doesn't mention AskUserQuestion, the model rarely tries it

## Key Decisions

1. **Start from the Claude Code preset, not from scratch** — the preset encodes a lot of valuable behavior around coding, error recovery, and tool usage. Audit and adapt rather than reinvent.
2. **Obtain the preset first** — the preset isn't officially published but has been extracted and shared publicly. Pull it down, version it in the repo, and use it as the reference for the audit.
3. **Audit in layers** — categorize every section of the preset as: keep as-is, modify for Parachute, drop entirely.
4. **Dynamic assembly** — the final prompt should be composed from sections based on session context, not a static blob. This is already partially how it works (module prompts, CLAUDE.md injection) but should be more structured.
5. **Phased rollout** — start with suppressing unwanted tools via prompt changes, then progressively replace sections as we validate behavior.

## Audit Framework

When examining the Claude Code preset, categorize each section:

| Category | Meaning | Example |
|----------|---------|---------|
| **Keep** | Valuable behavior that applies to Parachute | File operation best practices, error handling patterns |
| **Modify** | Right concept, wrong framing | Tool usage instructions (keep the tools, change the interaction model) |
| **Drop** | Doesn't apply to Parachute | Terminal-specific instructions, interactive confirmation flows |
| **Add** | Missing from preset, needed for Parachute | Module awareness, trust level behavior, vault conventions |

## Open Questions

- Where is the most current extraction of the Claude Code preset? Need to find and pull it down.
- How much of the model's coding behavior comes from the preset vs. fine-tuning? If it's mostly fine-tuning, the preset changes may have less impact than expected.
- Should the custom prompt be a single file or a directory of composable sections?
- How do we test prompt changes? A/B testing is hard with LLMs — maybe a structured eval set of coding tasks?
- What's the relationship between the system prompt and `--dangerously-skip-permissions`? If we drop permission-related instructions from the prompt AND skip permissions, do we get clean behavior?

## Scope

**In scope:**
- Obtaining and versioning the Claude Code preset
- Audit of every section with keep/modify/drop/add categorization
- Design of the dynamic prompt assembly system
- Initial implementation replacing the preset for DIRECT trust coding sessions

**Out of scope:**
- Non-coding session prompts (daily journal, brain queries)
- Changes to the Claude Code CLI itself
- Fine-tuning or model-level changes

## Relationship to Permission Pipe Cleanup (#295)

This brainstorm is the long-term companion to the permission pipe cleanup (#295). That issue handles the immediate fix (skip permissions, intercept unwanted tools). This one addresses the root cause: the system prompt shouldn't be telling the model to use tools that Parachute doesn't support.

Once the custom prompt is in place:
- `can_use_tool` deny-list becomes a safety net, not the primary mechanism
- Permission pipe complexity is further reduced
- Model behavior is more predictable because the prompt matches the actual capabilities
