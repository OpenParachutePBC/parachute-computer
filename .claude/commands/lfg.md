---
name: lfg
description: Full autonomous engineering workflow
argument-hint: "[feature description]"
---

Run these slash commands in order. Prefer agent team mode in each step when the scope warrants it (cross-module work, 3+ parallel tracks, large PRs). Do not do anything else.

1. `/para-plan $ARGUMENTS`
2. `/deepen-plan` — will use team mode by default for multi-section plans
3. `/para-work` — offer team mode if plan has independent workstreams across modules
4. `/para-review` — will use team mode for large PRs (15+ files or cross-module)

Start with step 1 now.
