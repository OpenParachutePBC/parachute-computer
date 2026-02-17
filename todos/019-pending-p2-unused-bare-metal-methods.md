---
status: pending
priority: p2
issue_id: "30"
tags: [code-review, app, dead-code, tech-debt]
dependencies: []
---

# Unused methods in BareMetalServerService

## Problem Statement

Several methods in `BareMetalServerService` have zero callers and should be removed as part of the dead code sweep.

## Findings

- Discovered by: code-simplicity-reviewer
- Location: `app/lib/core/services/bare_metal_server_service.dart`
- Unused methods:
  - `getPythonVersion()` (line ~184)
  - `getClaudeVersion()` (line ~544)
  - `getServerVersion()` (line ~476)
  - `openShell()` (line ~807)
  - Interactive `installClaudeCLI()` (line ~781, superseded by `installClaudeCLINonInteractive`)
- Also: `bareMetalServiceInitializedProvider` in `bare_metal_provider.dart` (lines 21-29) has no consumers
- Also: `resetServerUrl()` in `computer_service.dart` (line 71) never called
- Also: `isPythonInstalled()` duplicates `checkPythonCompatibility()`
- Estimated ~100 lines removable

## Proposed Solutions

### Option A: Delete all unused methods (Recommended)
- Remove the 5 uncalled methods from BareMetalServerService
- Remove `bareMetalServiceInitializedProvider`
- Remove `resetServerUrl()` from ComputerService
- Consolidate `isPythonInstalled()` into `checkPythonCompatibility()`
- Effort: Small
- Risk: Low -- zero callers confirmed via grep
