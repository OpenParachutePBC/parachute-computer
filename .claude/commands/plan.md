---
name: para-plan
description: Transform feature descriptions into well-structured project plans
argument-hint: "[#issue-number or feature description]"
---

# Create a plan

**Note: The current year is 2026.**

## Input

<feature_description> #$ARGUMENTS </feature_description>

If empty, ask: "What would you like to plan?"

### 0. Resolve Issue Context

**If argument starts with `#` (e.g., `#77`):**
1. `gh issue view NN --json title,body,labels,state`
2. Search `docs/brainstorms/*.md` for files containing `**Issue:** #NN` — use as context if found
3. Store issue number for later

**If argument is a description:** proceed to idea refinement.

### 0b. Idea Refinement (if no issue/brainstorm)

Use AskUserQuestion to understand: purpose, constraints, success criteria. Ask one question at a time. Stop when clear or user says "proceed."

## Main Tasks

### 1. Local Research (always runs)

Read the relevant code and CLAUDE.md files for the affected area. Use Glob/Grep to find existing patterns related to the feature. Focus on: file structure, naming conventions, similar implementations, CLAUDE.md guidance for the component.

### 1.5. External Research (only when needed)

Skip external research unless the feature involves: security, payments, external APIs, unfamiliar technology, or the user asks for it.

If needed, run in parallel:
- Task best-practices-researcher(feature_description)
- Task framework-docs-researcher(feature_description)

Announce the decision briefly before proceeding.

### 2. Write the Plan

**Title & file:** `docs/plans/YYYY-MM-DD-<type>-<descriptive-name>-plan.md`

**Choose detail level based on complexity:**

**MINIMAL** (simple bugs, small features):
```markdown
---
title: [Title]
type: [feat|fix|refactor]
date: YYYY-MM-DD
issue: NN
---

# [Title]

[Brief description]

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Context
[Critical info, file paths, patterns to follow]
```

**STANDARD** (most features):
Add: Overview, Problem Statement, Proposed Solution, Technical Considerations, Dependencies & Risks, References

**COMPREHENSIVE** (major features, architectural changes):
Add: Implementation Phases, Alternative Approaches, Risk Analysis, Success Metrics

Default to MINIMAL or STANDARD. Use COMPREHENSIVE only when the complexity genuinely warrants it.

### 3. Post to GitHub

**If issue number known:**
```bash
gh issue edit NN --title "<type>: <title>"
gh issue edit NN --body-file <plan-path>
gh issue edit NN --remove-label brainstorm --add-label plan
```

**If no issue exists:**
```bash
gh issue create --title "<type>: <title>" --body-file <plan-path> --label plan
```

Add `issue: NN` to the plan file's YAML frontmatter.

### 4. Ask What's Next

"Plan ready at `<path>` and posted to issue #NN. What next?"

Options:
1. Start `/work #NN`
2. Open plan in editor
3. Simplify / revise

NEVER CODE. Just research and write the plan.
