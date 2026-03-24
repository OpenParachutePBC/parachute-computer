---
title: "Persistent cards with read/unread state and card types"
type: brainstorm
date: 2026-03-24
issue: 322
---

# Persistent Cards with Read/Unread State

Cards should drift forward until you've seen them. Unread cards are buoyant — they float to today's surface. Once read, they settle back to their home date.

## Design Principles

- **Daily is forward-looking** — you live in today, cards come to you
- **Unforced interaction** — no dismiss buttons, no swipe-to-clear
- **Deterministic over random** — idempotent IDs, no duplicate cards on re-runs
- **Start simple, type matters later** — card_type is a plain string now, will drive rendering in the future

## Card Types

Add `card_type` to the Card schema. A plain string, agent-defined, no registry.

Card type is **structural** — it's part of the card's identity, baked into the ID, describes what the agent produced. It is NOT a tag. Tags (if/when #321 lands) are organizational, user-applied, many-to-many. A reflection card might be tagged `#gratitude`, but its type is always `reflection`.

`card_type` defaults to `"default"` for backward compatibility — existing agents that don't specify a type still work.

## Card ID Format

Change from `{agent_name}:{date}` to `{agent_name}:{card_type}:{date}`.

Deterministic, not UUID. This preserves the idempotent MERGE pattern — re-running an agent updates the existing card instead of creating duplicates. The constraint of "one card per agent per type per day" is correct, not limiting. If an agent needs to say two different things, those are two different card types.

Examples:
- `process-day:reflection:2026-03-24`
- `process-day:weekly-review:2026-03-24`
- `daily-summary:default:2026-03-24`

## Read/Unread State

Add `read_at` timestamp to Card schema. `null` = unread.

**Auto-read mechanic**: Card is marked read when expanded and then collapsed. Fire the `read_at` write on collapse, not on expand (handles accidental taps). No explicit dismiss button needed.

**Max float age**: 7 days. Cards older than 7 days that are still unread just live on their home date quietly. Prevents ancient cards from piling up.

## Updated Card Schema

```
Card node:
  card_id:       "{agent_name}:{card_type}:{date}"   # PK, deterministic
  agent_name:    "process-day"
  card_type:     "reflection"                         # NEW
  display_name:  "Evening Reflection"
  content:       "..." (markdown)
  status:        "running" | "done" | "failed"
  date:          "2026-03-24"
  generated_at:  ISO timestamp
  read_at:       ISO timestamp | null                 # NEW — null = unread
```

## API Changes

```
# New endpoints
GET  /api/daily/cards/unread          → all unread cards (within 7-day window)
POST /api/daily/cards/{card_id}/read  → set read_at timestamp

# Modified endpoints
GET  /api/daily/cards?date=...        → unchanged, but response includes read_at and card_type
```

`write_card` tool gets optional `card_type` param (defaults to `"default"`).

## Flutter UI

Today's journal page layout:

```
┌─────────────────────────────┐
│ ★ Unread from past days     │  ← section only shows if count > 0
│   📄 Mar 22 — Reflection    │    grouped by date, most recent first
│   📄 Mar 21 — Weekly Review │
├─────────────────────────────┤
│ Today's Cards               │
│   📄 Daily Summary (unread) │  ← unread styling (dot, highlight)
│   📄 Reflection (read)      │  ← muted styling
├─────────────────────────────┤
│ Journal entries...           │
└─────────────────────────────┘
```

**Unread badge on Daily nav**: Same pattern as chat unread badges. Shows count of unread cards (within 7-day window) on the Daily icon in bottom nav.

**Card expand/collapse**: On collapse of an unread card, fire `POST /cards/{card_id}/read`. Optimistically update local state (mark read immediately in UI, don't wait for server).

## Migration

Existing cards have no `card_type` or `read_at`. Migration:
- Add `card_type` column with default `"default"`
- Add `read_at` column, nullable
- Existing cards get `card_type = "default"` and `read_at = null`
- Card ID migration: existing `{agent_name}:{date}` cards keep their IDs (read by old API still works). New cards use the triple format. API handles both formats.

## Relationship to Other Issues

- **#321 (Tags as graph primitive)**: Card types are NOT tags. Types are structural identity; tags are organizational metadata. Cards could be tagged once #321 lands — they're complementary.
- **#220 (Card experience polish)**: This builds on that work. Persistent cards make the polish work more impactful since cards are now the hero of the experience.

## Open Questions

- Should the unread badge count include today's unread cards, or only past-day cards that floated forward? (Leaning: include all unread.)
- When an agent re-runs and overwrites a card the user already read, does `read_at` reset to null? (Leaning: yes — new content deserves a fresh read.)
