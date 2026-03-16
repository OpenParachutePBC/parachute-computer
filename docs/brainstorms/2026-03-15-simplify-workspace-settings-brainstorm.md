# Simplify Workspace Settings UI

**Status:** Brainstorm
**Priority:** P2
**Labels:** app, chat
**Issue:** #275

---

## What We're Building

Strip the workspace/session settings UI down to what users actually need, and make those actions discoverable.

### The Problem

There are currently **two separate settings sheets** that overlap and confuse:

1. **ContainerSettingsSheet** (gear icon in workspace context bar) — workspace name, core memory, delete
2. **SessionConfigSheet** (long-press on a chat — undiscoverable) — trust level, workspace picker, response mode, sandbox promotion banner

The result: a user trying to name their workspace can't find the feature. The long-press is invisible, and the gear icon only appears when a workspace is already selected. The two sheets show 10+ controls when 3 are actually needed.

### What Users Actually Need

Most users just need workspace management:

1. **Name a workspace** (promote a sandbox) — the primary action
2. **Rename a workspace** — occasional
3. **Delete a workspace** — rare, destructive

### What's Legacy/Unused

- **Trust level selector** — sandboxed is the default going forward. Direct trust is a power-user/developer setting, not something in a general settings sheet. Users don't change trust level mid-chat.
- **Workspace picker / move chat** — not functional. Chat workspace is set at creation time and can't be reassigned.
- **Core memory** — uncertain whether this is in the current product thinking.
- **Response mode / mention pattern** — bot-specific, only relevant for Telegram/Discord connector sessions.

## Why This Approach

The current UI accumulated features from different eras of thinking. Rather than consolidating two complex sheets, we should delete what's not needed and make the remaining actions obvious.

### Design Direction

- **One settings surface, not two** — replace both sheets with a single, focused workspace sheet
- **Gear icon stays** in the workspace context bar, but opens the simplified sheet
- **Kill long-press as the only path** to settings — it's undiscoverable
- **Sandbox promotion should be prominent** — this is the main action users need. When a chat is in an unnamed sandbox, there should be a clear visual nudge (not buried in a settings sheet behind a long-press)

## Key Decisions

- **Trust level** moves out of the main settings UI. Could become a developer-only option in a future "advanced" section, or just stay as an API-level concern.
- **Core memory** — keep in the data model but remove from the UI for now. Can be re-added if the concept proves useful.
- **Bot session config** (response mode, mention pattern) — needs a separate home. These are activation/onboarding concerns, not ongoing settings. Keep them in the activation flow for pending bot sessions only.
- **Session config sheet** — largely deprecated. The activation flow for bot sessions is the only part that still matters.

## Open Questions

- Where should the "name this workspace" nudge live? Inline banner in the chat? In the workspace context bar itself? Toast/snackbar after first message in a sandbox?
- Should there be a way to access settings from within a chat session (e.g., a header action), or only from the session list?
- What happens to the long-press gesture — remove it entirely, or repurpose it for something else (archive, delete chat)?

## Scope

**In scope:**
- Simplify ContainerSettingsSheet to name/rename + delete
- Remove or relocate trust level, workspace picker, core memory from the main UI
- Make workspace naming discoverable without long-press
- Keep bot session activation flow functional (it's the only part of SessionConfigSheet that's needed)

**Out of scope:**
- Moving chats between workspaces (not currently possible)
- Redesigning the workspace creation flow
- Advanced/developer settings surface
