---
name: lfg
description: Full autonomous engineering workflow
argument-hint: "[#issue-number or feature description]"
---

Run these slash commands in order. Each command uses parallel subagents for research and review. Do not do anything else.

**If the argument starts with `#` (e.g., `#77`):**

1. `/para-plan #NN`
2. `/deepen-plan` — parallel research agents enhance each section
3. `/para-work #NN` — execute the plan efficiently
4. `/para-review` — parallel review agents check all quality dimensions

**If the argument is a description:**

1. `/para-plan $ARGUMENTS`
2. `/deepen-plan` — parallel research agents enhance each section
3. `/para-work` — execute the plan efficiently (use the plan file just created)
4. `/para-review` — parallel review agents check all quality dimensions

Start with step 1 now.
