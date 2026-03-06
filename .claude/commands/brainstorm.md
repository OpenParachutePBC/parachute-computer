---
name: para-brainstorm
description: Explore requirements and approaches through collaborative dialogue before planning implementation
argument-hint: "[feature idea or problem to explore]"
---

# Brainstorm a Feature or Improvement

**Note: The current year is 2026.** Use this when dating brainstorm documents.

Brainstorming helps answer **WHAT** to build through collaborative dialogue. It precedes `/plan`, which answers **HOW** to build it.

**Process knowledge:** Load the `brainstorming` skill for detailed question techniques, approach exploration patterns, and YAGNI principles.

## Feature Description

<feature_description> #$ARGUMENTS </feature_description>

**If the feature description above is empty, ask the user:** "What would you like to explore? Please describe the feature, problem, or improvement you're thinking about."

Do not proceed until you have a feature description from the user.

## Execution Flow

### Phase 0: Assess Requirements Clarity

Evaluate whether brainstorming is needed based on the feature description.

**Clear requirements indicators:**
- Specific acceptance criteria provided
- Referenced existing patterns to follow
- Described exact expected behavior
- Constrained, well-defined scope

**If requirements are already clear:**
Tell the user their requirements seem detailed enough to skip brainstorming, and suggest running `/plan` instead — but invite them to keep exploring if they want to think it through first.

### Phase 1: Understand the Idea

#### 1.1 Repository Research (Lightweight)

Run a quick repo scan to understand existing patterns:

- Task repo-research-analyst("Understand existing patterns related to: <feature_description>")

Focus on: similar features, established patterns, CLAUDE.md guidance.

#### 1.2 Collaborative Dialogue

Ask questions **one at a time** in natural prose.

**Guidelines (see `brainstorming` skill for detailed techniques):**
- Share your perspective or assumption first, then ask if it's right
- Start broad (purpose, users) then narrow (constraints, edge cases)
- Validate assumptions explicitly
- Ask about success criteria

**Exit condition:** Continue until the idea is clear OR user says "proceed"

### Phase 2: Explore Approaches

Propose **2-3 concrete approaches** based on research and conversation.

For each approach, provide:
- Brief description (2-3 sentences)
- Pros and cons
- When it's best suited

Lead with your recommendation and explain why. Apply YAGNI—prefer simpler solutions.

Share which approach you'd recommend and why, then invite the user to share their thinking or any adjustments.

### Phase 3: Capture the Design

Write a brainstorm document to `docs/brainstorms/YYYY-MM-DD-<topic>-brainstorm.md`.

**Document structure:** See the `brainstorming` skill for the template format. Key sections: What We're Building, Why This Approach, Key Decisions, Open Questions.

Ensure `docs/brainstorms/` directory exists before writing.

### Phase 4: File as GitHub Issue

After capturing the brainstorm, create a GitHub issue. Brainstorm issues are the durable tracking artifact.

**Determine labels:**
- Always add `brainstorm`
- Add module label(s): `daily`, `chat`, `brain`, `computer`, `app` (based on what the brainstorm touches)
- Add priority if clear: `P1`, `P2`, `P3`

**Create the issue:**

```bash
gh issue create \
  --title "[Brainstorm] <Topic Title>" \
  --body-file docs/brainstorms/YYYY-MM-DD-<topic>-brainstorm.md \
  --label brainstorm,<module-label>
```

**After creation:**
1. Capture the issue number from the `gh issue create` output URL
2. Add `**Issue:** #NN` to the brainstorm file's metadata block (after the Status/Priority lines)
3. Update the issue body on GitHub to include the issue reference:
   ```bash
   gh issue edit NN --body-file docs/brainstorms/YYYY-MM-DD-<topic>-brainstorm.md
   ```

### Phase 5: Handoff

Tell the user the brainstorm is filed as GitHub issue #NN. Suggest the natural next step — running `/plan #NN` — and let them know the issue is tracked if they'd rather return to it later. Keep it conversational; they'll say what they want to do.

## Output Summary

When complete, display:

```
Brainstorm complete!

Document: docs/brainstorms/YYYY-MM-DD-<topic>-brainstorm.md
Issue: <GitHub issue URL> (#NN)

Key decisions:
- [Decision 1]
- [Decision 2]

Next: Run `/plan #NN` when ready to implement.
```

## Important Guidelines

- **Stay focused on WHAT, not HOW** - Implementation details belong in the plan
- **Ask one question at a time** - Don't overwhelm
- **Apply YAGNI** - Prefer simpler approaches
- **Keep outputs concise** - 200-300 words per section max
- **Brainstorm file and issue body must stay in sync** - The GitHub issue body IS the brainstorm content. Whenever the brainstorm file is updated (during this session or later), sync it to the issue: `gh issue edit NN --body-file docs/brainstorms/YYYY-MM-DD-<topic>-brainstorm.md`. Update the issue title too if the topic changed. This applies to pivots, refinements, or any substantive change to the brainstorm.

NEVER CODE! Just explore and document decisions.
