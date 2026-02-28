---
name: para-review
description: Code review — lightweight by default, full suite when needed
argument-hint: "[PR number, branch, or 'full' for comprehensive review]"
---

# Review Command

Review the current branch or a specific PR.

## Setup

```bash
# Determine what to review
# If argument is a PR number: gh pr checkout NN
# If argument is a branch name: git checkout <branch>
# Otherwise: review current branch
```

Fetch PR metadata if reviewing a PR:
```bash
gh pr view --json title,body,files,number
```

## Default Review (most PRs)

Run these two agents in parallel:

1. **Task code-simplicity-reviewer** — unnecessary complexity, over-engineering
2. **Task python-reviewer** (if `computer/` touched) OR **Task flutter-reviewer** (if `app/` touched)

That's it for small-to-medium PRs. Synthesize findings, present a clean summary.

## Full Review (`/review full`)

Only for large PRs (many files), risky changes (auth, data, payments), or when explicitly requested.

Run in parallel:
1. Task security-sentinel
2. Task performance-oracle
3. Task architecture-strategist
4. Task code-simplicity-reviewer
5. Task python-reviewer (if computer/ touched)
6. Task flutter-reviewer (if app/ touched)
7. Task parachute-conventions-reviewer (if crossing module boundaries or touching MCP/trust)

## Protected Artifacts

Never flag for deletion: `docs/plans/*.md`, `docs/solutions/*.md` — these are pipeline artifacts.

## Output

Present findings grouped by severity. Be direct about signal vs noise — if a finding is theoretical or stylistic, say so. Focus on things that could actually break or harm the system.

**P1 (blocks merge):** security vulnerabilities, data corruption, broken imports, missing deps
**P2 (should fix):** real architectural issues, performance problems
**P3 (optional):** style, minor cleanup — list briefly, don't belabor

After presenting: suggest running tests to verify nothing is broken.
```bash
cd computer && .venv/bin/python -m pytest tests/unit/ -x -q
```
