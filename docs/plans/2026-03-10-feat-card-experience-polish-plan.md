---
title: "Card Experience Polish"
type: feat
date: 2026-03-10
issue: 220
---

# Card Experience Polish

Make Cards the hero of the Parachute Daily experience. Cards are agent-generated outputs (reflections, digests, reviews) that greet the user each morning. The backend is solid — deterministic IDs, status tracking, graph storage, API endpoints all work. The UI treats Cards as an afterthought: bare spinner for running state, no failed state handling, no empty state, and no visual identity per Caller.

**Flutter-only. No backend changes. No new dependencies.**

## Problem Statement

Cards are what differentiate Parachute Daily from every other journaling app. Without Cards, Daily is just another note-taking tool. With great Cards, it's an active thinking partner that greets you each morning. For the NVC pitch, Cards are the demo moment.

Current gaps:
- **Running state is bare** — `_AgentRunningCard` shows a `CircularProgressIndicator` + "Running..." text. No shimmer, no per-agent icon, no contextual message.
- **Failed state is invisible** — `JournalAgentOutputsSection` only branches on `card.isRunning`; failed cards fall through to `AgentOutputHeader` and render as expandable markdown with empty content. No retry affordance.
- **Agent theming is duplicated** — `_getAgentIconAndColor` exists identically in `agent_output_header.dart` and `agent_trigger_card.dart`, hardcoded for only 2 agents.
- **No empty state** — when no cards exist, the section doesn't render at all. No invitation to set up Callers.
- **Done cards lack polish** — no shadow, hardcoded spacing/radii, no auto-expand for single cards, no content preview when collapsed.

## Implementation Phases

### Phase 1: Shared Agent Theming (Foundation)

Extract the duplicated `_getAgentIconAndColor` into a shared utility. Add `runningMessage` for contextual loading text.

**Create** `app/lib/features/daily/journal/utils/agent_theme.dart`:

```dart
class AgentTheme {
  final IconData icon;
  final Color color;
  final String runningMessage;

  static AgentTheme forAgent(String agentName) {
    // reflection → wb_twilight + forest + "Your reflection is being written..."
    // content-scout → lightbulb_outline + turquoise + "Scouting content..."
    // default → smart_toy_outlined + driftwood + "Working on something..."
  }
}
```

**Modify** `agent_output_header.dart` — remove private `_getAgentIconAndColor`, use `AgentTheme.forAgent()`.
**Modify** `agent_trigger_card.dart` — same cleanup.

### Phase 2: Rich Running State with Shimmer

Replace the bare spinner with a shimmer card using per-agent theming.

**Modify** `journal_agent_outputs_section.dart` — promote `_AgentRunningCard` to `StatefulWidget` with `SingleTickerProviderStateMixin`:

- `AnimationController` with `duration: Motion.breathing` (4s), repeating
- Subtle `LinearGradient` sweep across card background using agent's accent color
- Agent icon (from `AgentTheme`) with gentle pulse opacity
- Contextual message from `AgentTheme.runningMessage` instead of "Running..."
- Border radius `Radii.lg` (16) to match done cards
- Dark mode: shimmer from `nightSurfaceElevated` through `color.withValues(alpha: 0.08)`

No shimmer package — built with Flutter's `AnimationController` + gradient.

### Phase 3: Failed State with Retry

Add a distinct `_AgentFailedCard` widget with tap-to-retry.

**Modify** `journal_agent_outputs_section.dart`:

- Convert `JournalAgentOutputsSection` from `StatelessWidget` to `ConsumerWidget` (needs `ref` for retry)
- Add branch: `if (card.isFailed) return _AgentFailedCard(...)`
- `_AgentFailedCard` design:
  - Agent icon with subtle warning overlay
  - "Couldn't generate today's [displayName]"
  - "Tap to try again" subtitle
  - Entire card tappable → `dailyApiServiceProvider.triggerAgentRun()` + refresh
  - Border: agent color at low alpha (gentle, not alarming red)

### Phase 4: Empty State for Callers

When viewing today and no cards exist, invite the user to set up Callers.

**Create** `app/lib/features/daily/journal/widgets/cards_empty_state.dart`:

- Compact card (sits above journal entries, not full-page)
- Icon: `Icons.auto_awesome` in `BrandColors.forest`
- Title: "Your daily agents"
- Body: "Set up a Caller to get personalized reflections each day."
- CTA: `TextButton` "Explore Callers" → navigate to Settings
- Same margin/padding/radius as other cards
- Dashed border to distinguish from "real" cards

**Modify** `journal_content_view.dart`:

```dart
if (hasAgentOutputs)
  SliverToBoxAdapter(child: JournalAgentOutputsSection(cards: agentCards)),
else if (isToday)
  SliverToBoxAdapter(child: CardsEmptyState()),
```

Past days show nothing (correct — can't retroactively generate).

### Phase 5: Done Card Polish

**Modify** `agent_output_header.dart`:

1. **Auto-expand single card** — when only one done card, default expanded. Add `initiallyExpanded` param, set from `JournalAgentOutputsSection`.
2. **Content preview when collapsed** — first ~60 chars of content (markdown stripped) as subtitle.
3. **Subtle shadow** — `Elevation.cardShadow` in light mode.
4. **Design tokens** — replace hardcoded values with `Radii.lg`, `Spacing.lg`/`Spacing.sm`, `Motion.gentle`.
5. **Use `AgentTheme`** instead of private method.

## Files Changed

| File | Action |
|------|--------|
| `app/lib/features/daily/journal/utils/agent_theme.dart` | **Create** — shared agent theming |
| `app/lib/features/daily/journal/widgets/journal_agent_outputs_section.dart` | **Modify** — shimmer running, failed state, ConsumerWidget |
| `app/lib/features/daily/journal/widgets/agent_output_header.dart` | **Modify** — AgentTheme, auto-expand, shadow, tokens |
| `app/lib/features/daily/journal/widgets/cards_empty_state.dart` | **Create** — empty state for today |
| `app/lib/features/daily/journal/widgets/journal_content_view.dart` | **Modify** — show empty state when today + no cards |
| `app/lib/features/daily/journal/widgets/agent_trigger_card.dart` | **Modify** — use AgentTheme (minor) |

## Acceptance Criteria

- [ ] Running cards show per-agent icon, accent color, contextual message, and shimmer animation (light + dark)
- [ ] Failed cards show distinct error state with "Couldn't generate" message and tap-to-retry
- [ ] Empty state appears on today's view when no cards exist, links to Caller settings
- [ ] Agent theming consolidated in single `AgentTheme` utility used by all card widgets
- [ ] Done cards auto-expand when only one exists, show content preview when collapsed
- [ ] Design tokens used consistently — no hardcoded spacing/radii/motion values
- [ ] Dark mode correct for all card states
- [ ] No new dependencies in pubspec.yaml
