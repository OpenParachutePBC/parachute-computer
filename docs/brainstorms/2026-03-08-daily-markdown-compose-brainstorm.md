# Daily: Full-Screen Markdown Compose

**Date:** 2026-03-08
**Status:** Brainstorm
**Priority:** P1
**Modules:** app, daily
**Issue:** #208

---

## Context

Daily's text input is a bottom bar capped at ~5 lines (120px). For quick capture it's fine, but for longer reflections — the kind of writing that happens during a morning tea session — it's claustrophobic. There's no formatting, no expand affordance, and no draft persistence. If the app resets mid-compose, whatever you were writing is gone.

Meanwhile, entries in the timeline render as plain text — no markdown formatting visible even if the user writes in markdown syntax. The compose and display sides are both under-serving users who want to *write*.

This brainstorm focuses on three connected improvements that form one cohesive pass, all client-side with no backend changes required.

---

## What We're Building

### 1. Full-Screen Markdown Compose

An Obsidian-style full-screen editor that opens when the user wants more space than the quick-capture bar provides. This is **markdown-native** — you see and write the syntax, with lightweight inline rendering (headers get bigger, bold text renders bold, etc.) while keeping the markdown visible and editable.

**Entry point:** The existing input bar stays as the quick-capture surface for one-liners. An expand button (or automatic expansion after a few lines) opens the full-screen compose view.

**The compose screen includes:**
- Large, distraction-free text area filling the screen
- Markdown toolbar at the bottom (above keyboard): bold, italic, heading, list, quote, link
- Title field at the top (optional — can be left blank for untitled entries)
- Save button and discard/back navigation
- Preview toggle (optional, for checking rendered output)

**Inline markdown rendering while typing:**
- `# Heading` renders with larger font weight
- `**bold**` renders bold
- `- list items` render with bullet indicators
- `> quotes` render with left border
- Syntax characters stay visible (like Obsidian, not like Notion)

### 2. Draft Persistence

Whatever is in the compose field — whether the quick-capture bar or the full-screen editor — survives app restarts. The draft is saved to local storage (SharedPreferences or SQLite) on every text change (debounced). When the user returns to Daily, their unsaved draft is restored.

**Behavior:**
- Auto-save draft on text change (debounced ~500ms)
- Restore draft when Daily tab loads or compose screen opens
- Clear draft when the entry is successfully submitted
- Only one active draft at a time (today's compose)
- Draft includes both title and content fields

### 3. Markdown Rendering in Timeline

Entries in the journal timeline render their markdown formatting. Headers, bold, italic, lists, quotes, code blocks, and links all display with proper formatting instead of raw syntax.

**Behavior:**
- All entry types that contain text get markdown rendering (typed entries, voice transcripts if they contain markdown)
- Truncated entries (~6-8 lines instead of current 4) still show formatting in preview
- Tapping an entry to edit opens it in the full-screen markdown editor
- The existing `flutter_markdown` package (already in pubspec) handles rendering

---

## Why This Approach

- **Markdown-native, not rich text** — the user explicitly wants Obsidian-style editing where markdown syntax is visible. This is simpler to implement (no bidirectional rich text ↔ markdown conversion) and matches the vault's markdown-first philosophy.
- **Two-tier compose** — keeping the quick-capture bar for one-liners means we don't slow down fast capture. The full-screen editor is for when you want to settle in and write.
- **Draft persistence is table stakes** — losing mid-compose text is a trust-breaking experience. Local auto-save with debounce is simple and reliable.
- **No backend changes** — all three improvements are client-side Flutter work. Entries are already stored as text; markdown rendering is purely a display concern.
- **flutter_markdown already in pubspec** — rendering infrastructure exists, just needs to be wired into the entry display.

---

## Key Decisions

1. **Obsidian-style inline rendering** — markdown syntax stays visible while typing, with lightweight visual formatting applied. Not a WYSIWYG editor like Notion.
2. **Input bar stays as quick-capture** — the full-screen editor is an expansion, not a replacement. Both entry points create the same type of entry.
3. **One active draft** — no multiple drafts or draft management. Just "your current unsaved text for today."
4. **Tap entry → full-screen editor for editing** — replaces the current inline edit mode. Editing happens in the same compose screen as creation.
5. **Markdown renders everywhere** — timeline entries, expanded view, and (eventually) search results all render markdown.

---

## Open Questions

- **Expand trigger:** Should the full-screen editor open via an explicit expand button, or auto-expand when the text exceeds a certain length (e.g., 3 lines)? An explicit button is simpler and more predictable.
- **Markdown toolbar scope:** Which formatting shortcuts are worth putting in the toolbar for v1? Probably just: bold, italic, heading, bullet list, quote. Link and code can wait.
- **Inline rendering library:** Does an existing Flutter package handle Obsidian-style "live markdown" (syntax visible + rendered), or do we need to build it? `flutter_markdown` renders final output but doesn't do inline editing. May need a custom approach or a package like `markdown_editor_plus`.
- **Voice entry editing:** When you tap a voice transcript to edit, should it open in the full-screen markdown editor too? Probably yes for consistency, but voice entries might feel weird in a markdown context.
- **Entry truncation in timeline:** Currently 4 lines. Moving to 6-8 lines with markdown rendering feels right, but should we just show the full entry if it's under some threshold (say, 15 lines)?
