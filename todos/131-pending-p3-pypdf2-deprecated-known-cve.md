---
status: pending
priority: p3
issue_id: 96
tags: [code-review, security, docker, dependencies]
dependencies: []
---

# PyPDF2 Is Deprecated with Known CVE — Migrate to `pypdf`

## Problem Statement

The Dockerfile pins `PyPDF2==3.0.1`, which is the final release of a deprecated, unmaintained library. CVE-2023-36464 affects all PyPDF2 versions from 2.2.0 through 3.0.1 (the complete 3.x line). The vulnerability is an infinite loop triggered by a malformed PDF comment, causing 100% CPU utilization. No further patches will be issued — the project has been officially superseded by `pypdf`. The existing `timeout_seconds=300` and `--cpus 1.0` limits reduce the practical impact (container times out after 5 minutes rather than running indefinitely), but the vulnerability remains unpatched within its window.

## Findings

- **Sources**: security-sentinel (confidence 82)
- **Location**: `computer/parachute/docker/Dockerfile.sandbox`, line 40
- **Evidence**:
  ```dockerfile
  PyPDF2==3.0.1 \  # CVE-2023-36464 affects all PyPDF2 versions up to and including 3.0.1
  ```
- **CVE**: CVE-2023-36464 — Infinite loop in `__parse_content_stream` on malformed PDF
- **Mitigating factors**: Container CPU limit (1.0 core) + timeout (300s) bound the DoS window

## Proposed Solutions

### Solution A: Replace with `pypdf` (Recommended)
```dockerfile
pypdf==4.3.1 \   # or latest stable; drop-in replacement for most PyPDF2 usage
```
The `pypdf` package is the maintained successor. The API is largely compatible with PyPDF2 for basic operations (read/write pages, extract text). A migration guide is available from the pypdf maintainers.
- **Pros**: Actively maintained, CVE-free for current release, same functionality
- **Cons**: Minor API differences for advanced usage; requires testing
- **Effort**: Small
- **Risk**: Low

### Solution B: Remove PyPDF2 entirely until needed
If no sandbox agent code currently relies on PDF parsing, remove it from the image.
- **Pros**: Eliminates the vulnerability; smaller image
- **Cons**: Re-add when needed
- **Effort**: Small
- **Risk**: Low

## Recommended Action
<!-- Filled during triage -->

## Technical Details

- **Affected files**: `computer/parachute/docker/Dockerfile.sandbox`
- **CVE-2023-36464**: https://github.com/advisories/GHSA-4vvm-4w3v-6mr8
- **pypdf migration guide**: https://pypdf.readthedocs.io/en/stable/migration-1-to-2.html

## Acceptance Criteria

- [ ] `PyPDF2` removed from `Dockerfile.sandbox`
- [ ] Replaced with `pypdf` or removed if unused
- [ ] No remaining references to `PyPDF2` in requirements or Dockerfiles

## Work Log

| Date | Action | Learnings |
|------|--------|-----------|
| 2026-02-22 | Created from PR #96 code review | PyPDF2 is deprecated; prefer pypdf for all new code |

## Resources

- PR #96: https://github.com/OpenParachutePBC/parachute-computer/pull/96
- CVE-2023-36464: https://github.com/advisories/GHSA-4vvm-4w3v-6mr8
