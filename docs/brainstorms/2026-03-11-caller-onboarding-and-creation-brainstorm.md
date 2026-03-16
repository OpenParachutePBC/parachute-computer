---
title: Caller Onboarding & Creation UX
status: brainstorm
priority: P1
modules: daily, app, computer
**Issue:** #231
---

# Caller Onboarding & Creation UX

## What We're Building

A first-run experience for the Daily module that gives users something to interact with immediately, plus a UI flow for creating and editing callers from the app.

Right now, the Caller Management screen shows "No agents configured" with no way to create one — a dead end. We need to close this loop.

### Three pieces:

1. **Seed caller template** — The server holds a "Daily Reflection" definition (name, default prompt, default tools, schedule). It's not auto-inserted into the graph. Instead, the empty state in the app offers a clear "Create your first caller" action that provisions it from this template. The user explicitly opts in.

2. **Caller editing** — Once a caller exists, the user can edit it from the management UI: name, description, schedule, system prompt (markdown text field), and context/tool configuration.

3. **Caller creation** — Users can create additional callers beyond the starter. Same form as editing, but starting blank (or from another template in the future).

## Why This Approach

- **User agency over silent automation** — Seeding a caller invisibly feels wrong. The user should choose to activate it, even if it's one tap. This also means they see the management screen working from the start.
- **Server-side templates, client-side creation** — The server defines what a good starter caller looks like. The app just calls the create endpoint. This keeps the Flutter side thin and means templates can evolve server-side without app updates.
- **Direct prompt editing first** — The "take your prompt to a personal AI for refinement" idea is appealing but adds complexity. V1: you edit the markdown directly. The refinement flow can layer on later.

## Key Decisions

1. **Seed caller is "Daily Reflection"** — reads today's journal + recent journals, offers a reflective card. Sensible default that demonstrates the system without being opinionated about the user's workflow.

2. **Template lives server-side** — An API endpoint (e.g., `GET /api/daily/callers/templates`) returns available templates. The app calls `POST /api/daily/callers` with the template data to create it. This keeps the door open for community-shared templates later.

3. **Context/tools as friendly toggles with depth** — Not raw tool arrays, not flat checkboxes. Each context source is a toggle that can be tapped into for configuration:
   - **Today's journal** (on/off)
   - **Recent journals** (on/off, configurable lookback: 7/14/30 days)
   - **Chat logs** (on/off)
   - **Web access** (on/off, with explanation of what it enables)
   - This maps to the underlying tools array but presents it in human terms.

4. **System prompt is editable markdown** — Full text field in the app. Power users write their own. Future: a guided flow or AI-assisted prompt builder.

5. **Schedule is opt-in at creation** — Caller is created enabled but unscheduled. User explicitly sets a time to activate the schedule. This avoids surprise automation.

## Open Questions

- **Template endpoint design** — Should templates be a separate endpoint, or should the server just expose a `/callers/defaults` that returns pre-filled caller objects? Simpler might be better.
- **Prompt editing UX on mobile** — Editing a full markdown prompt on a phone is awkward. Is a simple text area enough for v1, or do we need a more structured prompt builder?
- **Tool access gradient** — The toggle list above covers the basics, but the broader vision includes MCP access (Suno, etc.). How does that surface? Probably not in v1, but worth noting the extensibility path.
- **Multiple templates** — V1 ships with Daily Reflection. When do we add Weekly Review, Morning Prompt, etc.? Can punt but the template endpoint should support a list.
