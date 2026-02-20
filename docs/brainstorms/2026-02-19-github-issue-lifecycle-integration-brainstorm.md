# GitHub Issue as Lifecycle Handle

> Make the GitHub issue number the through-line for the entire brainstorm → plan → work lifecycle. All commands accept `#NN`, all files link back, plans post to existing issues instead of creating new ones.

**Date:** 2026-02-19
**Status:** Brainstorm complete, ready for planning
**Modules:** computer, app (`.claude/` commands and skills)
**Priority:** P2
**Issue:** #77

---

## What We're Building

A tighter integration between our `.claude/` commands (`/para-brainstorm`, `/para-plan`, `/para-work`, `/para-next`, `/lfg`) and GitHub Issues, where the issue number is the single handle that threads through the entire feature lifecycle.

Today: brainstorm creates an issue, but the file doesn't know its issue number. Plans create *new* issues instead of posting to existing ones. Commands accept descriptions but not issue numbers. Handoffs say "run /para-plan" without specifying which issue.

After: every command accepts `#NN`. Files have `issue: NN` in frontmatter. Plans are posted as comments on the brainstorm's issue. PRs automatically include `Closes #NN`. The issue is the durable handle, local files are working documents.

## Why This Approach

### One Issue Per Feature (Not Brainstorm + Plan Issues)

The brainstorm issue already exists. Creating a second issue for the plan fragments tracking and forces manual cross-referencing. Instead, the plan enriches the existing issue as a comment — the issue evolves from "brainstorm" to "brainstorm + plan" to "brainstorm + plan + PR" as work progresses.

### Issue Number as the Handle (Not File Paths)

File paths are brittle and local. Issue numbers are stable, shareable, and clickable. When `/para-next` recommends an issue, the handoff is `/para-plan #74` — unambiguous, copy-pasteable, and the command knows exactly where to find context.

### Semi-Automatic Sync (Not Fully Automatic)

No file watchers or hooks that auto-sync changes. Commands prompt when appropriate (e.g., "Plan written. Post to issue #74?"). This keeps things predictable and avoids surprise GitHub API calls.

## Key Decisions

- **One issue per feature:** Brainstorm creates it, plan posts to it as a comment, PR closes it
- **Frontmatter convention:** `issue: 74` (integer, no `#`, no quotes) in both brainstorm and plan files
- **Plans post to existing issues:** `gh issue comment #NN --body-file plan.md` instead of `gh issue create`
- **Label progression:** Issue starts with `brainstorm` label; gets `plan` label added when plan is posted
- **All commands accept `#NN`:** `/para-plan #74`, `/para-work #74`, `/lfg #74`
- **Brainstorm frontmatter:** Add YAML-style `issue:` field, written back after issue creation
- **PR auto-linking:** `/para-work` includes `Closes #NN` in PR body
- **`todos/` stays local:** Review findings don't get linked to GitHub issues
- **No automatic file sync:** Updates to brainstorm/plan files don't auto-push to GitHub; commands offer to update when relevant

## Current State Gaps

| Gap | Impact |
|-----|--------|
| Brainstorm files have no `issue:` field | Can't find which issue a brainstorm belongs to |
| Plan files have `issue:` but format varies (`"#56"`, `68`, `"#48"`) | Fragile parsing |
| `/para-plan` creates new issues instead of commenting | Duplicate tracking |
| Commands don't accept `#NN` as input | Manual context threading |
| `/para-work` doesn't auto-link PRs to issues | Manual `Closes #NN` |
| `/para-next` handoff doesn't specify issue number | Ambiguous next step |
| `/deepen-plan` doesn't preserve issue context | Loses thread during deepening |

## Lifecycle Flow

```
/para-brainstorm "idea"
  → writes docs/brainstorms/2026-02-19-foo-brainstorm.md
  → creates GitHub issue #74 (label: brainstorm)
  → writes issue: 74 back into brainstorm file
  → handoff: "Run /para-plan #74 when ready"

/para-plan #74
  → fetches issue #74 body from GitHub
  → finds local brainstorm file (scan frontmatter for issue: 74)
  → writes docs/plans/2026-02-19-foo-plan.md (with issue: 74)
  → posts plan as comment on issue #74
  → adds "plan" label to issue #74
  → handoff: "Run /para-work #74 when ready"

/para-work #74
  → fetches issue #74, finds linked plan file
  → creates branch, executes plan
  → creates PR with "Closes #74" in body
  → posts PR link as comment on issue #74

/para-next
  → recommends issues by priority tier
  → handoff: "Run /para-plan #74" or "/para-work #74"
    (based on whether issue already has "plan" label)

/lfg #74
  → threads issue number through: plan → deepen → work → review
```

## Commands Affected

| Command | Change |
|---------|--------|
| `/para-brainstorm` | Write `issue: NN` back to brainstorm file after issue creation; handoff uses `#NN` |
| `/para-plan` | Accept `#NN` input; fetch issue context; post plan as comment (not new issue); add `plan` label |
| `/para-work` | Accept `#NN` input; find plan file by frontmatter; auto-include `Closes #NN` in PR |
| `/para-next` | Handoff specifies `#NN`; distinguish plan-ready vs work-ready issues |
| `/lfg` | Accept `#NN`; thread through all sub-commands |
| `/deepen-plan` | No change needed (operates on file, issue context preserved in frontmatter) |
| `/para-review` | No change needed (operates on PRs) |
| `/reproduce-bug` | No change needed (already accepts issue numbers) |
| `/triage` | No change needed (local todo system) |
| brainstorming skill | No change needed (process knowledge, not issue linking) |

## Resolved Questions

- **Brainstorm frontmatter format:** Keep freeform `**Field:** value` style. Add `**Issue:** #NN` as a freeform line (matches existing convention). Parseable with regex, no migration needed.
- **`/para-plan` without a brainstorm issue:** Create a minimal issue with `plan` label (no `brainstorm` label). Not every feature needs a brainstorm phase.
- **Existing plan files:** Leave alone. Enforce `issue: 74` (integer, no `#`, no quotes) in plan YAML frontmatter going forward.

## Next Steps

→ `/para-plan #NN` for implementation details (once this brainstorm is filed as an issue)
