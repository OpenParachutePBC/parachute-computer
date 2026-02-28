# Bridge Behavior + System Prompt Visibility

**Status:** Brainstorm
**Priority:** P1
**Date:** 2026-02-27
**Supersedes:** #112 (Rearchitect vault agent system prompt)
**Issue:** #139

---

## What We're Building

A simpler, more intentional model for what the bridge does and how prompting works across
the system — main chat and bridge both.

The core insight from our conversation: **ambient capture is the wrong default.** The bridge
was trying to do too much (observe, judge, write to graph automatically) without the personal
context needed to make quality decisions. The result was noise — dev architecture details
ending up in a personal knowledge graph.

The fix is to simplify the bridge's role and make prompting visible and editable.

---

## What We're NOT Building (Right Now)

- Staging markdown scratchpad
- Automatic promotion pipelines
- Ambient knowledge capture
- Onboarding flows for personal context

These might make sense later, but are premature until the simpler model proves useful.

---

## The Simplified Model

### Bridge: Do Less, Do It Well

**Post-turn observe** — keep it, but scope it tightly:
- Session metadata only: title, summary, activity log
- No brain graph writes from the observer
- The bridge is reliable infrastructure, not an ambient AI

**Pre-turn enrich** — keep the architecture, make the default conservative:
- Haiku judgment still fires, but default prompt says "pass through unless
  something explicitly personal is referenced"
- Reading from brain is low-risk; only worth doing when there's a clear signal
- As personal context builds in brain, enrichment gets more useful naturally

### Brain Writes: Intentional Only

Brain graph writes happen one way: the user explicitly asks through chat.
- "Remember that Kevin is co-lead on LVB"
- "Add to brain: Woven Web is addressing foundation classification"
- The main chat agent calls `brain_upsert_entity` when asked

The main chat agent already has brain MCP tools available — it just needs prompting
to know when and how to use them. This is a prompting problem, not an infrastructure problem.

Eventually, the bridge or a lightweight "memory agent" could handle explicit memory
requests on behalf of the main chat — keeping the main agent focused on conversation
while delegating the "remember this" action. But the MCP tools are already there; this
is mostly a prompting question.

### System Prompt Visibility

Both the main chat and bridge have invisible prompting right now. That's a real gap —
if prompting is the primary lever for shaping behavior, it should be inspectable and
editable from the app.

A "prompting" or "instructions" view in the app where you can see and edit:
- Main chat system prompt / instructions
- Bridge observe prompt
- Bridge enrich prompt

This is also the natural place to add personal context — rather than a fancy onboarding
flow, you just edit an "About me" field that feeds into the bridge's judgment anchor.
Default is empty (bridge does nothing special). You add context when you want it.

---

## Key Decisions

- **Bridge observe**: session metadata only, no graph writes
- **Bridge enrich**: conservative default (mostly pass-through), reads brain when useful
- **Brain writes**: intentional via chat, not ambient
- **Personal context**: editable instructions field, not a separate setup flow
- **Prompting visibility**: inspect + edit from the app, both agents

---

## Phases

### Phase 1 — Simplify bridge behavior
- Remove automatic brain graph writes from bridge observer
- Tighten enrich prompt to be conservative by default
- Update bridge observe prompt to focus on session metadata quality

### Phase 2 — System prompt visibility
- "Instructions" or "prompting" view in app
- See and edit main chat prompt, bridge observe prompt, bridge enrich prompt
- "About me" / personal context field that feeds into bridge judgment

### Phase 3 — Intentional memory UX
- Make "remember this" feel natural in chat
- Main chat agent knows to call brain tools when asked
- Possibly delegate to bridge or lightweight memory agent so main chat stays focused

### Phase 4 — Ambient enrichment (future)
- Once personal context is established via intentional writes, enrichment gets useful
- Revisit ambient capture if intentional model proves insufficient
