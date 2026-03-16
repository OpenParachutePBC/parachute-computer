---
title: "Recording & Capture UX Redesign"
type: feat
date: 2026-03-15
issue: 268
---

# Recording & Capture UX Redesign

## Overview

Redesign the Daily input bar from a five-button toolbar with a full-panel recording overlay to an iMessage-style text field + mic button with inline recording state. Remove photo and handwriting inputs until they can be done justice as standalone features.

## Problem Statement

The current input bar (`journal_input_bar.dart`, 975 lines) has five equally-weighted action buttons (voice, photo, handwriting, expand, send) but only two are regularly used — voice and typing. The recording overlay (`DailyRecordingOverlay`) replaces the entire input bar with a three-section panel: pulsing red dot header with 24pt timer, 80px/40-bar waveform, and two full-width Discard/Done buttons. This puts the user in "monitoring mode" instead of "speaking mode" and obscures the journal entries behind it.

## Proposed Solution

### New Layout: Normal State

```
[TextField "Capture a thought..."] [🎤] [↗] [⬆]
                                         ^    ^
                                    compose  send (contextual)
```

- **Text field** takes most of the width — always visible, always ready
- **Mic button** sits immediately right of the text field
- **Compose button** (expand to full editor) — kept, moved right of mic
- **Send button** — appears contextually when text is entered (already works this way)
- Photo, handwriting buttons **removed entirely**

### New Layout: Recording State (Inline)

```
[● 0:12 ~~thin waveform~~~~~~~~~~] [⏹]
```

The text field area transforms into a compact recording strip — same height, same footprint:

- **Small recording dot** (forest green, not red) — subtle breathing animation
- **Timer** inline, small (13-14pt), tabular figures
- **Thin waveform** fills remaining space (~24px tall, ~20 bars)
- **Mic button transforms to stop button** — same position, icon changes to square stop icon with gentle breathing glow
- Compose and send buttons **hide** during recording
- **No overlay** — journal entries remain fully visible above
- **No discard button** — tap stop to finish. User can delete the entry after if unwanted (simpler mental model)

### Post-Recording Flow (unchanged)

- Entry appears immediately with "Transcribing..." state
- Raw text fills in when Parakeet finishes (~3-5s)
- Cleaned text replaces raw when Haiku finishes (~5-10s more)
- Subtle haptic on stop

## Acceptance Criteria

- [x] Input bar shows only: text field, mic, compose, send (4 elements, not 7)
- [x] Tapping mic starts recording inline — no overlay, no panel swap
- [x] Recording state shows thin waveform + timer inside the text field area
- [x] Mic button transforms to stop button during recording
- [x] Recording uses forest green accent, not alarming red
- [x] Journal entries remain visible/scrollable during recording
- [x] Stop creates voice entry with existing transcription pipeline (unchanged)
- [x] Minimum 3-second recording check preserved
- [x] Long-press mic still opens recording options sheet
- [x] Photo and handwriting buttons fully removed (not just hidden)
- [x] Dead code for photo/handwriting cleaned up from input bar
- [x] `flutter analyze` passes

## Implementation Steps

### Step 1: Strip photo & handwriting from input bar

**File: `journal_input_bar.dart`**

Remove:
- `onPhotoCaptured` and `onHandwritingCaptured` callback parameters
- `_buildPhotoButton()`, `_buildHandwritingButton()` methods
- `_showPhotoOptions()`, `_captureFromCamera()`, `_selectFromGallery()` methods
- `_openHandwritingCanvas()` method
- Imports: `capture_providers.dart`, `handwriting_screen.dart`
- Photo/handwriting items from the input Row

**File: `journal_screen.dart`**

Remove:
- `onPhotoCaptured` and `onHandwritingCaptured` callback wiring from `JournalInputBar(...)` call
- Keep `_addPhotoEntry` and `_addHandwritingEntry` methods for now (other code paths may reference them)

### Step 2: Reorder input bar layout

Rearrange the input Row from:
```
[voice] [photo] [handwriting] [TextField] [expand] [send]
```
To:
```
[TextField] [mic] [expand] [send]
```

The text field becomes the first (leftmost) element and takes `Expanded`. Mic button moves to the right side, adjacent to the text field. Compose (expand) stays. Send stays contextual.

### Step 3: Build inline recording state

Replace `_buildRecordingMode()` which currently returns `DailyRecordingOverlay(...)` with an inline recording strip built directly in the input bar.

New `_buildRecordingMode()` returns a `Row` with the same outer Container as the normal input mode:

```dart
Row(
  children: [
    // Recording strip (replaces text field)
    Expanded(
      child: Container(
        height: 48,  // same as text field
        decoration: /* same rounded container as text field */,
        child: Row(
          children: [
            SizedBox(width: 12),
            _BreathingDot(),           // small green dot
            SizedBox(width: 8),
            Text(timer),               // "0:12" in 13pt
            SizedBox(width: 12),
            Expanded(
              child: RecordingWaveform(  // reuse existing widget
                amplitudeStream: ...,
                height: 24,             // thin, not 80
                barCount: 20,           // fewer bars
                color: BrandColors.forest,
              ),
            ),
            SizedBox(width: 12),
          ],
        ),
),
    ),
    SizedBox(width: 8),
    // Stop button (same position as mic button)
    _buildStopButton(isDark),
  ],
)
```

### Step 4: Mic → Stop button transform

Modify `_buildVoiceButton()` to handle both states, or split into `_buildMicButton()` / `_buildStopButton()`:

- **Normal**: Forest-green-tinted circle with mic icon
- **Recording**: Forest-green filled circle with stop (square) icon + subtle breathing animation via `AnimationController` pulsing the container's opacity or scale between 0.95-1.05

The breathing animation replaces the `_PulsingDot` from the overlay — the whole button gently breathes to signal "recording active."

### Step 5: Create `_BreathingDot` widget

Small (8px) forest-green dot with opacity animation (0.4 → 1.0, 1s cycle, easeInOut). Reuses the same animation pattern as the old `_PulsingDot` but:
- Uses `BrandColors.forest` instead of `BrandColors.error`
- 8px instead of 12px
- Lives inside the recording strip, not a separate header

### Step 6: Clean up dead code

- Delete `DailyRecordingOverlay` from `daily_recording_overlay.dart` (or mark deprecated if referenced elsewhere)
- Check for any other references to the overlay widget
- Remove the overlay import from `journal_input_bar.dart`
- Consider whether `_PulsingDot` in the overlay file is used anywhere else
- Verify `RecordingWaveform` still works at smaller dimensions (it should — it's parameterized)

## Technical Considerations

### RecordingWaveform reuse

`RecordingWaveform` is already parameterized with `height` and `barCount`. Using `height: 24, barCount: 20` should work without any changes to the widget itself. The `_WaveformPainter` calculates bar width from available space and bar count dynamically.

### State management

The `_isRecording` / `_isProcessing` state flags in `_JournalInputBarState` already control the mode switch. The refactor only changes what `_buildRecordingMode()` returns — the state machine stays the same.

### No discard button

The current overlay has a Discard button that calls `_discardRecording()`. By removing it, the user's only action during recording is Stop. If a recording is unwanted, they delete the entry after. This simplifies the recording UX significantly — one button, one action.

The `_discardRecording()` method can stay in the codebase (called if recording < 3 seconds, which auto-discards), but there's no UI affordance for manual discard.

### Callback cleanup

Removing `onPhotoCaptured` and `onHandwritingCaptured` from the widget's constructor is a breaking API change for `JournalInputBar`. The only consumer is `journal_screen.dart`, so this is safe. The `onComposeSubmitted` callback stays.

### Compose button

The expand/compose button stays — it's the "long-form typing" affordance. When the user wants to write a longer entry with a title, they tap expand. This is aligned with "voice + typing as the two primary modes."

## Dependencies & Risks

- **Low risk**: All changes are UI-only within the Daily feature. No server changes.
- **No new dependencies**: Reuses existing `RecordingWaveform` widget.
- **Regression risk**: Recording flow must still work end-to-end (start → stop → entry created → transcription). The state machine is unchanged, only the visual presentation changes.
- **Android model download**: The `_startRecording()` model download check is untouched.

## Files Changed

| File | Change |
|------|--------|
| `app/lib/features/daily/journal/widgets/journal_input_bar.dart` | Major refactor — strip photo/handwriting, reorder layout, inline recording |
| `app/lib/features/daily/journal/screens/journal_screen.dart` | Remove photo/handwriting callback wiring |
| `app/lib/features/daily/recorder/widgets/daily_recording_overlay.dart` | Delete (no longer used) |
| `app/lib/features/daily/recorder/widgets/recording_waveform.dart` | No changes (already parameterized) |
