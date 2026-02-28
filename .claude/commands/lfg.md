---
name: lfg
description: Full autonomous engineering workflow
argument-hint: "[#issue-number or feature description]"
---

Run these in order. Do not do anything else.

**If the argument starts with `#` (e.g., `#77`):**

1. `/plan #NN`
2. `/work #NN`

**If the argument is a description:**

1. `/plan $ARGUMENTS`
2. `/work` (use the plan file just created)

Start with step 1 now. Run `/review` afterward if the change is large or risky.
