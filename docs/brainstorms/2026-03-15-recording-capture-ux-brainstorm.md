# Recording & Capture UX Redesign

**Status:** Brainstorm
**Priority:** P1
**Labels:** daily, app
**Issue:** #268

---

## What We're Building

A redesigned input experience for Daily that treats **voice and typing as the two primary modes**, with an iMessage-style input bar (text field + mic button). The recording state becomes subtle and inline rather than an overlay control panel. Photo and handwriting inputs are removed until they can be done justice.

## Why This Matters

The current recording overlay feels overwhelming — a three-section panel with pulsing red dot, large waveform (80px, 40 bars), and two full-width buttons. It puts the user in "monitoring mode" instead of "speaking mode." For a journaling app where the goal is to externalize thought freely, the interface should feel like a sanctuary, not a dashboard.

The input bar currently shows five equally-weighted buttons (voice, photo, handwriting, text, send) but only two are regularly used — voice and typing. Photo and handwriting are undercooked and may be broken. The visual noise dilutes focus.

## The Design Direction

### Input Bar: iMessage-Style

- **Text field** takes most of the width — always visible, always ready
- **Mic button** sits to the right of the text field (prominent but not competing)
- Tap mic to record, tap text field to type
- Photo, handwriting, linked entry buttons are **removed for now** — they come back individually when each is ready
- Send button appears contextually (when text is entered)

### Recording State: Subtle Inline

When recording starts:
- The text field transforms into a **compact recording strip** — same footprint
- A **subtle waveform** replaces the text field area (thin, not 80px tall)
- **Timer** appears inline (small, not 24pt red)
- The **mic button becomes a stop button** with a gentle breathing animation
- Color accent signals "recording" without alarming red
- Journal entries remain visible above — no overlay blocks the view

When recording stops:
- Input bar returns to normal immediately
- Entry appears at bottom of journal list with calm "Transcribing..." indicator
- Raw text fills in when Parakeet finishes (~3-5s)
- Cleaned text replaces raw text when Haiku finishes (~5-10s more)
- Subtle haptic on stop and on transcription complete

### What Gets Removed

- **Photo button** — not in regular use, remove until camera/photo flow is polished
- **Handwriting button** — needs its own deeper design work (separate brainstorm)
- **Recording overlay** — the overlay panel that replaces the input bar is gone; recording is inline
- **Pulsing red dot header** — replaced by breathing animation on the button itself
- **Large waveform** — replaced by thin inline waveform within the input bar footprint
- **Discard/Done buttons** — replaced by a single stop button (mic → stop transform)

## Key Decisions

1. **Voice + typing only for now** — photo and handwriting are removed, not hidden. They return as individual features when ready.
2. **Inline recording, no overlay** — the input bar IS the recording UI. Same footprint, transformed state.
3. **Waveform stays but shrinks** — it provides emotional reassurance ("it's listening") but doesn't need to dominate.
4. **iMessage as the interaction model** — text field + mic is a universally understood pattern.

## Design Inspiration

- **AudioPen** — "Hit record and talk. No script needed." Recording screen is nearly empty. The transformation from raw audio to clean text is the magic moment.
- **iMessage** — text field + mic button. Universal, zero learning curve.
- **WhatsApp/Telegram voice messages** — hold-to-record, swipe-to-cancel. The waveform is animated but not accurate — it's a "system is listening" signal.
- **Reflect** — audio memos are first-class objects that appear inline, not in a separate section.
- **Brain Dump** — VAD-based auto-stop removes "when do I press stop?" anxiety.

## Open Questions

- Should we support hold-to-record as an alternative to tap-to-record/tap-to-stop? (Could be a future enhancement)
- Should recording auto-stop on extended silence (VAD)?
- Do we want a "discard" gesture (swipe to cancel like WhatsApp) or is stop + delete sufficient?
- Exact waveform style: thin bar stack vs. breathing ring vs. single amplitude line

## Related Threads

Two related ideas surfaced during this brainstorm that deserve their own exploration:

### Note Organization via Tags + Graph (#269)
Daily is currently date-first (flat chronological). Users want topical organization (recipes, projects, etc.). Rather than folders/notebooks, the approach would be: **tags as the primitive, graph structure as the organizer, containers as the boundary-maker**. Emergent structure from simple primitives — similar to Tana's supertags but built on our graph DB. Containers could scope to tagged notes, creating "effective containment."

### Handwriting Experience (#270)
The handwriting input mode exists but hasn't been refined. With devices like Daylight computers making handwriting a primary input, there's opportunity to make this a first-class experience. Needs its own deep brainstorm on canvas UX, OCR quality, and how handwritten notes integrate with the journal.
