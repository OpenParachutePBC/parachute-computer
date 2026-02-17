---
name: para-next
description: Recommend the next issue to work on based on priority, type, and current context
argument-hint: "[module filter: chat, daily, brain, computer, app]"
---

# Recommend Next Work

Fetch open GitHub issues and recommend what to work on next.

## Step 1: Fetch Issues

Run this command to get all open issues with metadata:

```bash
gh issue list --state open --json number,title,labels,body,createdAt,assignees --limit 50
```

## Step 2: Categorize

Sort issues into tiers:

**Tier 1 — Ready to build (brainstorm + P1)**
Issues with `brainstorm` label AND `P1`. These have been thought through and are high priority.

**Tier 2 — Ready to build (brainstorm + P2)**
Issues with `brainstorm` label AND `P2`. Thought through, moderate priority.

**Tier 3 — Bugs**
Issues with `bug` label. Fix what's broken.

**Tier 4 — Enhancements without brainstorm**
Issues with `enhancement` but no `brainstorm`. May need `/para-brainstorm` first.

**Tier 5 — Needs thinking**
Issues with `needs-thinking`. Not ready to build yet.

**Tier 6 — Everything else (P3, brainstorm-only, etc.)**

## Step 3: Filter (Optional)

If the user provided a module argument (`$ARGUMENTS`), filter to issues that have that module label (e.g., `chat`, `daily`, `brain`, `computer`, `app`). Show the filtered view but mention how many total issues exist.

## Step 4: Present Recommendation

Display a concise summary table of the top issues (max 10), grouped by tier:

```
## Recommended Next

| # | Title | Priority | Module | Type |
|---|-------|----------|--------|------|
```

Then recommend the single best issue to pick up, with a brief rationale (1-2 sentences).

## Step 5: Offer Next Steps

Use **AskUserQuestion tool** to ask:

**Question:** "Which issue would you like to pick up?"

**Options:**
1. **#[recommended]** - Start with the recommended issue
2. **Pick a different one** - Specify an issue number
3. **Just browsing** - No action needed

If the user picks an issue, ask whether they want to:
1. **Plan it** — Run `/para-plan` with the issue context
2. **Brainstorm first** — Run `/para-brainstorm` to explore further
3. **Just read it** — Show the full issue body
