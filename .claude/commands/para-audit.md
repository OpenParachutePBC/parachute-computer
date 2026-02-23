---
name: para-audit
description: Quick codebase health check — plan/issue sync, lifecycle gaps, module drift, and open issue health
argument-hint: ""
---

# Codebase Health Audit

**Note: The current year is 2026.**

A fast local health check for development coherence. No agents, no external research — just `gh` CLI, grep, and find. Run this periodically to catch drift before it becomes a problem. Similar to `/para-next` (which finds work), this finds what's out of sync.

## Checks

Run all four checks, then produce a single consolidated report.

### 1. Plan/Issue Sync

For each plan in `docs/plans/*.md` that has `issue: NN` in its YAML frontmatter, compare the local file against the GitHub issue body.

```bash
# Find all plans with an issue number
grep -rl "^issue: " docs/plans/ 2>/dev/null
```

For each plan found, extract the issue number and fetch the GitHub issue:

```bash
gh issue view NN --json body,state,title,labels
```

Compare local vs GitHub:
- **In sync** — First 500 chars roughly match (whitespace/frontmatter differences are ok)
- **Out of sync** — Content differs meaningfully → flag with the fix command
- **Issue closed, PR merged** — Expected, mark as DONE (not a problem)
- **Issue not found** — Flag as ORPHANED (issue was deleted or wrong number)

### 2. Brainstorm Lifecycle

```bash
# All brainstorm files
ls docs/brainstorms/*.md 2>/dev/null

# Which ones are missing an issue number
grep -rL "\*\*Issue:\*\* #" docs/brainstorms/ 2>/dev/null
```

For each brainstorm file:
1. **Has `**Issue:** #NN`?** — If not → flag as UNTRACKED (never filed as GitHub issue)
2. **Has a corresponding plan?** — Scan `docs/plans/*.md` for `issue: NN` in frontmatter. If not found → flag as NO PLAN. Note how many days old it is.
3. **GitHub issue still has `brainstorm` label after 7+ days?** — Stale, should have progressed to plan

```bash
# Check GitHub for open brainstorm issues
gh issue list --state open --label brainstorm --json number,title,createdAt --limit 50
```

### 3. Module Drift

```bash
# What modules actually exist
ls computer/modules/
```

Compare against the module list documented in `computer/CLAUDE.md`. Flag any module directory that exists but isn't mentioned.

### 4. Open Issue Health

```bash
# All open plan-stage issues
gh issue list --state open --label plan --json number,title,createdAt,labels --limit 50

# All open P1 issues
gh issue list --state open --label P1 --json number,title,createdAt,labels --limit 20
```

Flag:
- **Plan issues open > 14 days** with no associated PR → stale, needs attention
- **P1 issues open > 7 days** → should be actively in progress
- **Issues with `brainstorm` label > 7 days old** → should have a plan by now

```bash
# Check for PRs referencing each issue (quick heuristic)
gh pr list --state all --json number,title,body --limit 100 | grep "Closes #NN"
```

## Output Format

Produce a concise health report. Use ✅ / ⚠️ / ❌ for quick scanning.

```
# Parachute Health Report — YYYY-MM-DD

## Summary
✅ N checks passed  ⚠️ N warnings  ❌ N critical

---

## Plan/Issue Sync
❌ docs/plans/2026-02-16-feat-mid-stream-messaging-plan.md — OUT OF SYNC with #57
   Fix: gh issue edit 57 --body-file docs/plans/2026-02-16-feat-mid-stream-messaging-plan.md
✅ 8 other plans in sync with GitHub

## Brainstorm Lifecycle
⚠️  docs/brainstorms/2026-02-20-cleanup-context-system-duplication-brainstorm.md
    NO PLAN yet — issue #88, 2 days old
✅ 4 brainstorms have corresponding plans

## Module Drift
⚠️  computer/modules/brain_v2/ exists but not mentioned in computer/CLAUDE.md
✅ brain, chat, daily — documented and present

## Open Issue Health
⚠️  #47 [P1, plan] feat: MCP session context injection — open 6 days, no PR found
✅ No brainstorm issues stale (>7 days)

---

## Actions
1. Sync out-of-sync plans to GitHub (commands above)
2. Consider creating a plan for #88 or closing the brainstorm
3. Document brain_v2 in computer/CLAUDE.md
```

Keep the report tight. If everything is healthy, say so clearly and exit. Don't invent problems.

## After the Report

If there are out-of-sync plans, offer to fix them now:

- **Fix sync issues** — Run the listed `gh issue edit` commands immediately
- **Open GitHub** — `gh issue list --web` to review in browser
- **Done** — Report is informational, act later
