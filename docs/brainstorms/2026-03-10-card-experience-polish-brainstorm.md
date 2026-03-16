# Card Experience Polish

**Status:** Brainstorm
**Priority:** P1
**Labels:** daily, app
**Issue:** #220

---

## What We're Building

Make Cards the hero of the Parachute Daily experience. Cards are the agent-generated outputs that appear on each day's journal page — daily reflections, weekly reviews, prompts, summaries. The data model and backend are solid (deterministic IDs, status tracking, agent attribution). The UI needs to make Cards feel like *the thing you open Daily to see*, not an afterthought below your journal entries.

## Why This Matters

Cards are what differentiate Parachute Daily from any other journaling app. Without Cards, Daily is just another note-taking tool. With great Cards, it's an active thinking partner that greets you with something worth reading every morning. This is the feature that sells subscriptions and creates the habit loop: open app, see your Card, journal in response, repeat.

For the New Venture Challenge pitch, Cards are the demo moment — showing a personalized, AI-generated reflection that responds to someone's actual journal entries is immediately compelling.

## Current State

**What exists in Flutter:**
- `AgentCard` model with `cardId`, `agentName`, `displayName`, `content` (markdown), `status`, `generatedAt`, `date`
- `JournalAgentOutputsSection` renders Cards below journal entries
- `AgentRunningCard` shows status badge (running/done/failed)
- `AgentTriggerCard` provides a button to trigger agent runs
- Cards display as expandable markdown sections

**What's missing:**
- Cards are visually subordinate to journal entries — positioned below, styled as secondary
- No visual hierarchy between different Card types
- No interaction beyond expand/collapse
- No loading/streaming state that feels alive
- No empty state that invites you to set up Callers
- Cards don't feel like a "morning greeting" — they feel like log output

## Key Decisions

**Cards at the top of the day view, not the bottom.**
When you open a day in Daily, Cards should be the first thing you see — above your journal entries. They're the AI's contribution to your day. Journal entries are your contribution. The natural reading order is: see what your agents prepared, then add your own thoughts.

**Visual distinction by Card type/Caller.**
Different Callers produce different kinds of Cards. A daily reflection should feel different from a content digest or a weekly review. This could be as simple as icon + color accent per Caller, or as rich as different Card layouts. Start simple — icon and subtle color, consistent with the Caller's identity.

**Status states that feel alive.**
When a Card is running, it shouldn't just show a spinner and "Running..." — it should feel like something is actively being prepared for you. A subtle shimmer or pulse, maybe a "Your reflection is being written..." message. When it completes, a gentle transition to the content. Failed states should be clear but not alarming — "Couldn't generate today's reflection. Tap to retry."

**Empty state that drives setup.**
If no Callers are enabled, the Card area should invite the user to explore available Callers — not just be blank. "Set up your first daily agent" with a link to the Caller management screen. This is the onboarding funnel for the feature.

**Markdown rendering quality.**
Cards are markdown. The rendering needs to be polished — good typography, proper heading hierarchy, code blocks if relevant, maybe even light interactivity (checkboxes in weekly reviews?). This is where the user spends their attention.

## What Changes

**Flutter (`app/`):**
- `journal_screen.dart`: Move Card section above entries, redesign layout hierarchy
- `JournalAgentOutputsSection`: Redesign as primary content area, not secondary
- `AgentRunningCard`: Rich status states (shimmer, contextual messages, retry on failure)
- New: Card visual theming (icon + color per Caller type)
- New: Empty state widget for when no Callers are enabled
- Markdown renderer: Audit and polish rendering quality for Card content

**No backend changes needed** — the Card API and data model are already solid.

## Open Questions

- Should Cards be dismissible/archivable per day? (e.g., "I've read this, minimize it") Probably yes for daily use, but not MVP.
- Should tapping a Card expand it full-screen or is inline expansion enough? Start inline, see if content length demands full-screen.
- Do we want Card-to-journal interaction? (e.g., a "Respond" button on a reflection Card that opens a new journal entry) Compelling but not MVP.
- Should Cards animate in when they complete while you're looking at the day? Yes — this is the "alive" feeling.
