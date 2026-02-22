---
title: "Fix: Prompt metadata UI overstates visibility into system prompt"
date: 2026-02-20
status: brainstorm
priority: P3
tags: [fix, app, computer, transparency, ux]
---

# Fix: Prompt metadata UI overstates visibility into system prompt

## What We're Exploring

The Session Info sheet presents itself as a window into "what context is being provided to the AI," but two pieces of that UI make claims it can't actually back up. The "Base Prompt" token counter always shows 0 — not because the base prompt has no tokens, but because Parachute can't see inside the Claude Code SDK preset. The "View Full Prompt" button displays only the content Parachute appended, not the full prompt Claude actually receives. Both are honest engineering limitations; neither is labeled as such.

## Context

**Symptom 1 — "Base: 0" token count**

In `computer/parachute/core/orchestrator.py` at line 1379, `base_prompt_tokens` is hardcoded to `0` with the comment `# SDK handles base prompt`. This value flows through `computer/parachute/api/prompts.py` (the `GET /api/prompt/preview` endpoint, field `basePromptTokens`) and is displayed in the three-column token breakdown in `app/lib/features/chat/widgets/session_info_sheet.dart` (`_buildTokenRow`, line 605–625) under the label "Base Prompt". Claude Code's built-in system preset is likely 5–10k+ tokens, so showing 0 here is actively misleading.

**Symptom 2 — "View Full Prompt" shows partial content**

The "View Full Prompt" button (line 356 in `session_info_sheet.dart`) calls `GET /api/prompt/preview`, which runs `orchestrator._build_system_prompt()` — this returns only what Parachute itself appended to the SDK preset (context files, agent instructions, module instructions). It does NOT include:
- The Claude Code base system prompt preset (SDK-internal, not accessible)
- CLAUDE.md files the SDK loads natively via `setting_sources=["project"]`
- Tool definitions injected by the SDK

The footer at line 402 says: "This information shows what context is being provided to the AI in your conversations." That framing implies completeness that doesn't exist.

## Why This Matters

Parachute's value proposition includes transparency — users should be able to see what's going into their AI sessions. Showing a "Base Prompt: 0" and labeling a partial view "Full Prompt" actively undermines that trust. A user who investigates their token usage will see numbers that don't add up. A user who reads the "full" prompt and compares it to Claude's actual behavior will find instructions they can't account for. Fixing the labels is the minimum honest thing to do.

## Proposed Approach

This is a copy and label change — no new API or data pipeline needed.

**Token row (`_buildTokenRow` in `session_info_sheet.dart`):**
- Option A: Hide the "Base Prompt" column entirely, since it's always 0 and unexplainable. Show only "Context" and "Total".
- Option B: Rename the column to "SDK Preset" with value shown as "?" or "~7k" with a tooltip explaining it's estimated and not accessible.
- Preferred: Option A (simpler, less likely to mislead with a guess).

**Button label:**
- Rename "View Full Prompt" to "View Added Context" or "View Parachute Instructions".

**Footer note:**
- Replace current text with something like: "Shows the context Parachute adds to your conversations. The Claude Code SDK also injects its own base instructions and project CLAUDE.md files, which are not shown here."

**Header when viewing prompt:**
- The sheet title currently changes from "Session Info" to "System Prompt" when the button is pressed (line 134). Rename to "Added Context" or "Parachute Instructions" to match the button rename.

## What We're NOT Doing

Not attempting to expose the Claude Code SDK's internal system prompt — that content is managed by the SDK and not accessible to Parachute at runtime. Not adding any new endpoints, token-counting logic, or API changes. Not adding an estimate for SDK token usage (guessing 7k would be another form of inaccuracy). The goal is honesty about the boundary, not working around it.

## Open Questions

- Should the "Base Prompt" column be hidden (Option A) or relabeled with an explicit unknown marker (Option B)? Hidden is cleaner; relabeled is more informative for curious users.
- Should the footer note link to documentation explaining the SDK architecture, or keep it self-contained?
- Does renaming the button to "View Added Context" make it less discoverable for users looking to understand their prompt setup?

**Issue:** #81
