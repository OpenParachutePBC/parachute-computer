---
date: 2026-02-22
topic: dev-workflow-tooling-improvements
status: complete
priority: P2
**Issue:** #108
---

# Dev Workflow Tooling Improvements

## What We're Building

Two targeted improvements to the `.claude/` development tooling:

1. **GitHub sync in existing commands** — `/deepen-plan` and `/para-work` now automatically keep GitHub issues in sync with local plan files. No new infrastructure; just a `gh issue edit` call at the right moment in each command.

2. **`/para-audit` command** — A fast health check for development coherence. Checks plan/issue sync, brainstorm lifecycle gaps, module drift, and open issue health. Like `/para-next` but for codebase health rather than finding the next issue to work on.

## Why This Approach

The workflow system is already intelligent and mostly coherent. The problem is a few missing sync steps: when you deepen a plan, the GitHub issue doesn't update; when you start work, you might be working from a stale issue. Similarly, there's no lightweight way to step back and check if things have drifted — documentation, lifecycles, open issues.

The simplest fix: add sync calls to existing commands at the moments they already know the plan path and issue number. And create a single new command that does local checks (no agents, no external research) to give a quick health snapshot.

## Key Decisions

- **Sync on write, not on read** — `/deepen-plan` syncs after writing the enhanced plan; `/para-work` syncs when it resolves the plan at startup. Both moments are when we already have the plan path in hand.
- **No new infrastructure** — Everything is `gh` CLI + file scanning. No database, no registry, no CI required.
- **`/para-audit` is informational, not blocking** — It reports and offers to fix, but never blocks your workflow. Run it when you want to check in.
- **Fast over comprehensive** — `/para-audit` intentionally avoids spawning agents. Speed matters; it should feel instant compared to `/para-review` or `/deepen-plan`.

## Open Questions

- Should `/para-audit` also check `.claude/` tool integrity (e.g., commands referencing agents that don't exist)? Left out for now — orient towards simplicity.
- Should `/para-brainstorm` also sync to GitHub when the brainstorm file is updated mid-session? The command already documents this but it could be made more explicit.
