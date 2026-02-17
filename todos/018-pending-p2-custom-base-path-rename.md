---
status: pending
priority: p2
issue_id: "30"
tags: [code-review, app, naming, tech-debt]
dependencies: []
---

# CustomBasePathNotifier not renamed to match Computer terminology

## Problem Statement

The plan called for renaming `customBasePathProvider` to `customComputerPathProvider` and the `CustomBasePathNotifier` class accordingly. The section header comment was updated but the actual class and provider names were not.

## Findings

- Discovered by: architecture-strategist, pattern-recognition-specialist
- Location: `app/lib/core/providers/app_state_provider.dart:67-95`
- Also: `bare_metal_server_service.dart` has `_customBasePath`/`_standardBasePath` and `bundledBaseVersion` still using "base" naming

## Proposed Solutions

### Option A: Rename to Computer terminology (Recommended)
- `CustomBasePathNotifier` -> `CustomComputerPathNotifier`
- `customBasePathProvider` -> `customComputerPathProvider`
- `bundledBaseVersion` -> `bundledComputerVersion`
- `_customBasePath`/`_standardBasePath` -> `_customComputerPath`/`_standardComputerPath`
- Effort: Small
- Risk: Low -- find/replace with flutter analyze verification
