---
title: "feat: GitHub Issue as lifecycle handle"
type: feat
date: 2026-02-19
issue: 77
modules: [computer, app]
---

# feat: GitHub Issue as Lifecycle Handle

## Overview

Thread the GitHub issue number through the entire `/para-brainstorm` → `/para-plan` → `/para-work` lifecycle. The issue number becomes the handle that all commands accept, all files reference, and all handoffs use. Plans post to existing issues as comments instead of creating new issues.

**Brainstorm:** #77

## Problem Statement

Today the workflow has gaps:

- `/para-brainstorm` creates an issue but never writes the number back to the file
- `/para-plan` creates a *new* issue instead of enriching the brainstorm's issue
- Commands accept descriptions but not `#NN` — handoffs are ambiguous
- `/para-next` says "run /para-plan" without specifying which issue
- No standard frontmatter convention links files back to their issue

## Proposed Solution

Edit the 5 command markdown files (`.claude/commands/`) to:

1. Accept `#NN` as argument and resolve it via `gh issue view`
2. Write `issue:` into file frontmatter after issue creation
3. Find local files by scanning frontmatter for matching issue numbers
4. Post plans as comments on existing issues (not new issues)
5. Include `Closes #NN` in PR bodies automatically
6. Use issue labels (`plan`) to indicate lifecycle stage

## Files to Modify

| File | Changes |
|------|---------|
| `.claude/commands/para-brainstorm.md` | Write issue number back to brainstorm file; update handoff |
| `.claude/commands/para-plan.md` | Accept `#NN`; resolve issue; find brainstorm; post plan as comment; add label |
| `.claude/commands/para-work.md` | Accept `#NN`; find plan file; auto-link PR |
| `.claude/commands/para-next.md` | Use `#NN` in handoffs; check `plan` label for routing |
| `.claude/commands/lfg.md` | Accept `#NN`; thread through sub-commands |

No other files need changes. `/deepen-plan`, `/para-review`, `/reproduce-bug`, `/triage`, and the brainstorming skill stay as-is.

## Implementation Details

### 1. `/para-brainstorm` — Write Issue Back + Updated Handoff

**Phase 4 (File as GitHub Issue):** After `gh issue create`, capture the issue URL/number and write it back into the brainstorm file.

Replace current Phase 4:

```markdown
### Phase 4: File as GitHub Issue

After capturing the brainstorm, create a GitHub issue. Brainstorm issues are the durable tracking artifact.

**Determine labels:**
- Always add `brainstorm`
- Add module label(s): `daily`, `chat`, `brain`, `computer`, `app`
- Add priority if clear: `P1`, `P2`, `P3`

**Create the issue:**

\`\`\`bash
gh issue create \
  --title "[Brainstorm] <Topic Title>" \
  --body-file docs/brainstorms/YYYY-MM-DD-<topic>-brainstorm.md \
  --label brainstorm,<module-label>
\`\`\`

**After creation:**
1. Capture the issue number from the `gh issue create` output URL
2. Add `**Issue:** #NN` to the brainstorm file's metadata block (after Status/Priority lines)
3. Update the issue body on GitHub to include the issue reference:
   \`\`\`bash
   gh issue edit NN --body-file docs/brainstorms/YYYY-MM-DD-<topic>-brainstorm.md
   \`\`\`
```

**Phase 5 (Handoff):** Update options to use issue number.

Replace:

```markdown
1. **Proceed to planning** - Run `/para-plan` to create an implementation plan from this brainstorm
```

With:

```markdown
1. **Proceed to planning** - Run `/para-plan #NN` to create an implementation plan from this brainstorm
```

And update the Output Summary template:

```markdown
Next: Run `/para-plan #NN` when ready to implement.
```

### 2. `/para-plan` — Accept `#NN`, Post to Existing Issue

This is the biggest change. The command needs a new Phase 0 that resolves an issue number, and the Issue Creation section needs to become "Post to Issue" instead.

**Argument hint:** Change from `"[feature description, bug report, or improvement idea]"` to `"[#issue-number or feature description]"`.

**New Phase 0 — Resolve Issue Context:** Insert before current Step 0 (Idea Refinement):

```markdown
### Phase 0: Resolve Issue Context

**If the argument starts with `#` (e.g., `#77`):**

1. Fetch the issue:
   \`\`\`bash
   gh issue view NN --json title,body,labels,state
   \`\`\`
2. If the issue doesn't exist, tell the user and stop.
3. Search for a local brainstorm file that references this issue:
   - Scan `docs/brainstorms/*.md` for files containing `**Issue:** #NN`
   - If found, read the brainstorm file — use it as context and **skip Idea Refinement**
   - If not found, use the GitHub issue body as context and **skip Idea Refinement**
4. Note whether the issue already has a `plan` label (if so, warn: "This issue already has a plan. Creating a new plan will add another comment to the issue.")
5. Proceed to Local Research (Step 1)

**If the argument is a description (no `#` prefix):**

Proceed with existing behavior (Idea Refinement → brainstorm discovery → etc.)
```

**Idea Refinement update:** The existing brainstorm discovery logic (`ls -la docs/brainstorms/*.md`) stays as fallback for when no `#NN` is provided.

**Issue Creation section:** Replace the entire "Issue Creation" section at the bottom with:

```markdown
## Post Plan to Issue

After writing the plan file, post it to the GitHub issue.

**If an issue number is known** (from `#NN` argument or brainstorm's `**Issue:** #NN`):

1. Post the plan as a comment on the existing issue:
   \`\`\`bash
   gh issue comment NN --body-file docs/plans/YYYY-MM-DD-<type>-<name>-plan.md
   \`\`\`
2. Add the `plan` label:
   \`\`\`bash
   gh issue edit NN --add-label plan
   \`\`\`

**If no issue exists** (user provided a description, no brainstorm):

1. Create a new issue:
   \`\`\`bash
   gh issue create --title "<type>: <title>" --body "Planning in progress. See plan comment below." --label plan
   \`\`\`
2. Capture the issue number
3. Post the plan as a comment on the new issue
4. Write `issue: NN` into the plan file's YAML frontmatter

**Always:** Ensure the plan file's YAML frontmatter includes `issue: NN`.
```

**Post-Generation Options:** Replace "Create Issue" option with "Post to issue #NN" (which runs automatically). Remove the standalone "Create Issue" option since it's now part of the standard flow. Update handoff to say `/para-work #NN`.

**Plan YAML frontmatter:** Ensure all templates include `issue: NN` (integer, no `#`):

```yaml
---
title: [Issue Title]
type: [feat|fix|refactor]
date: YYYY-MM-DD
issue: NN
---
```

### 3. `/para-work` — Accept `#NN`, Auto-link PR

**Argument hint:** Change from `"[plan file, specification, or todo file path]"` to `"[#issue-number, plan file, specification, or todo file path]"`.

**Phase 1 (Quick Start) — Read Plan and Clarify:** Add issue resolution before reading the plan:

```markdown
1. **Resolve Input**

   **If the argument starts with `#` (e.g., `#77`):**
   1. Fetch the issue: `gh issue view NN --json title,body,labels`
   2. Search for a local plan file:
      - Scan `docs/plans/*.md` YAML frontmatter for `issue: NN`
      - If found, use that as the work document
      - If not found, check the issue comments for a plan (the most recent long comment)
        and tell the user: "No local plan file found for #NN. The plan was posted as a
        comment on the issue. Would you like me to save it locally first?"
   3. Proceed with reading the plan

   **If the argument is a file path:**
   Proceed with existing behavior (read the file directly).
```

**Phase 4 (Ship It) — Create Pull Request:** Update the PR body template to include `Closes #NN`:

```markdown
3. **Create Pull Request**

   **Determine the issue number** from the plan file's YAML frontmatter (`issue: NN`).

   \`\`\`bash
   gh pr create --title "<type>: [Description]" --body "$(cat <<'EOF'
   ## Summary
   - What was built
   - Why it was needed
   - Key decisions made

   Closes #NN

   ## Testing
   - Tests added/modified
   - Manual testing performed

   ---

   Generated with [Claude Code](https://claude.com/claude-code)
   EOF
   )"
   \`\`\`
```

### 4. `/para-next` — Route with `#NN`

**Step 5 (Offer Next Steps):** Update the handoff to use issue numbers and check for `plan` label:

Replace current Step 5 with:

```markdown
## Step 5: Offer Next Steps

Use **AskUserQuestion tool** to ask:

**Question:** "Which issue would you like to pick up?"

**Options:**
1. **#[recommended]** - Start with the recommended issue
2. **Pick a different one** - Specify an issue number
3. **Just browsing** - No action needed

If the user picks an issue, check its labels to determine the right next step:

- **Has `plan` label** → "This issue has a plan. Run `/para-work #NN` to start implementing."
- **Has `brainstorm` label but no `plan`** → "This issue has a brainstorm but no plan yet. Run `/para-plan #NN` to create one."
- **Has neither** → Ask: "This issue hasn't been brainstormed yet. Would you like to `/para-brainstorm` first, or jump to `/para-plan #NN`?"
```

### 5. `/lfg` — Thread `#NN`

Replace the entire file:

```markdown
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
```

## Edge Cases & Handling

| Edge Case | Handling |
|-----------|----------|
| `gh issue view` fails (not found) | Tell user: "Issue #NN not found on GitHub. Check the number and try again." |
| `gh issue view` fails (auth/network) | Tell user: "Couldn't reach GitHub. Check your auth (`gh auth status`) and network." |
| No local brainstorm file for `#NN` | Use GitHub issue body as context (it contains the brainstorm content) |
| No local plan file for `#NN` | Check issue comments for plan; offer to save locally |
| Multiple files match `issue: NN` | Use the most recent file (by date in filename); warn user about duplicates |
| `/para-plan #NN` called twice | Creates new plan file + posts new comment. Warn if `plan` label already exists. |
| Existing brainstorms without `**Issue:**` | Leave as-is. Only new brainstorms get the field. |
| `/para-plan` with description (no `#`) | Falls back to current behavior: discover brainstorm → create issue → post plan |

## Acceptance Criteria

- [x] `/para-brainstorm` writes `**Issue:** #NN` back to brainstorm file after issue creation
- [x] `/para-brainstorm` handoff says `/para-plan #NN` with actual issue number
- [x] `/para-plan #77` fetches the issue and finds the local brainstorm
- [x] `/para-plan` with a description (no `#`) still works (backward compatible)
- [x] `/para-plan` posts plan as comment on existing issue (not new issue)
- [x] `/para-plan` adds `plan` label to issue
- [x] Plan YAML frontmatter includes `issue: NN` (integer)
- [x] `/para-work #77` finds the plan file by frontmatter
- [x] `/para-work` PR body includes `Closes #NN`
- [x] `/para-next` handoff uses `#NN` and routes based on `plan` label
- [x] `/lfg #77` threads issue number through all sub-commands
- [x] All commands degrade gracefully when GitHub is unreachable
- [x] Existing brainstorm/plan files without `issue:` field are not broken

## Implementation Order

1. **`/para-brainstorm`** — Smallest change, establishes the write-back convention
2. **`/para-plan`** — Biggest change, core of the feature
3. **`/para-work`** — Depends on plan frontmatter convention from step 2
4. **`/para-next`** — Simple routing change
5. **`/lfg`** — Simple threading, depends on plan + work accepting `#NN`

## References

- Brainstorm: [#77](https://github.com/OpenParachutePBC/parachute-computer/issues/77)
- Current commands: `.claude/commands/para-{brainstorm,plan,work,next}.md`, `.claude/commands/lfg.md`
- Brainstorming skill: `.claude/skills/brainstorming/SKILL.md` (no changes needed)
