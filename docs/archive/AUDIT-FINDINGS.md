# Documentation Audit Findings — February 9, 2026

## Summary

Full audit of `openparachute.io/docs/` against the current app and computer codebases. All 14 documentation pages were reviewed and updated.

---

## Changes Made

### Terminology: "Base" → "Computer"
The server was renamed from "Base" to "Computer" / "Parachute Computer" across the codebase, but docs still said "Base" everywhere. Fixed across all pages (~50 occurrences).

### Curator System Fully Removed
The server-side curator system was completely removed but heavily documented across 8+ pages. All references updated:

- **Replaced** "Curator Pipeline" diagrams with "Background Processing" (activity hooks + daily agents)
- **Replaced** curator task queue references with activity hook system
- **Replaced** "Daily Curator" with generic daily agent system (APScheduler + `Daily/.agents/*.md`)
- **Removed** curator files from file manifest (curator_service.py, curator_mcp_server.py, curator_mcp_tools.py, curator_tools.py, daily_curator.py, daily_curator_tools.py, api/curator.py, import_curator.py)
- **Removed** "Curator Task Queue Unbounded" from issues page

### File Manifest Updated
- Flutter: 190 → 247 files, 73,015 → 78,240 lines
- Python: 66 → 81 files, 19,871 → 23,273 lines
- Total: 256 → 328 files, 92,886 → 101,513 lines
- Added new sections for module system and bot connectors
- Removed all dead curator file entries

### Issues Page Updated
- Removed stale curator issue
- Fixed all file paths from `base/` to `computer/`
- Updated stats in technical debt summary
- Replaced stale "add curator queue limits" recommendation

### Navigation Sidebar
All pages updated with consistent sidebar including new Bot Connectors page.

### New Pages Added (prior session)
- `computer-connectors.html` — Bot Connectors documentation

---

## Findings: Issues & Improvement Ideas

### 1. Dead Curator Code in App (High Priority)

**17 files** in the Flutter app still reference "curator" despite the server-side curator system being fully removed. Key dead code:

**Fully dead files (can be deleted):**
- `app/lib/features/chat/models/curator_session.dart` (361 lines)
- `app/lib/features/chat/widgets/curator_session_viewer_sheet.dart` (1,042 lines)
- `app/lib/features/chat/providers/chat_curator_providers.dart`
- `app/lib/features/chat/services/chat_curator_service.dart`

**Files with stale curator references (need cleanup):**
- `chat_screen.dart` — imports CuratorSession
- `chat_service.dart` — curator-related methods
- `chat_providers.dart` — curator provider references
- `chat_server_import_service.dart` — curator import logic
- `curator_log_screen.dart` — Daily feature; shows agent outputs but named "curator"
- `agent_output_header.dart` — references curator terminology
- Various Daily models (`agent_output.dart`, `reflection.dart`, etc.) use "curator" strings

**Recommendation:** Remove the 4 dead files (~1,700 lines) and rename remaining references from "curator" to "agent" or "activity hook" as appropriate. The curator_log_screen could become `agent_log_screen.dart`.

### 2. Naming Inconsistency: base_server_service.dart

The app still has `base_server_service.dart` and `BaseServerService` class, plus `base_server_provider.dart`. These should eventually be renamed to match the "Computer" terminology. Low priority since it's internal naming, but creates confusion for new contributors.

### 3. File Manifest Accuracy

The file manifest is a manual listing that will drift out of date quickly. Consider:
- Generating it automatically from the codebase
- Or adding a CI check that compares manifest to actual files
- Or removing it entirely and relying on GitHub's own file browser

### 4. Issues Page Maintenance

The issues page lists specific file paths and line numbers that change constantly. Some entries may already be fixed. Consider:
- Linking to GitHub Issues instead of maintaining a static HTML page
- Or adding a "last verified" date to each issue card
- Or using a script to verify that referenced files/lines still exist

### 5. Stale Ancillary Pages

Two pages outside the main docs directory have outdated content:
- `roadmap-v1.html` — still references "base server" terminology
- `prd-modular-architecture.html` — references "Python base server"

These appear to be historical documents. Consider archiving or adding a "superseded" banner.

### 6. ChatService Size (Still True)

`chat_service.dart` at 2,059 lines is still the largest single file. The issues page already flags this, but it's worth noting it hasn't been addressed and is growing. It now handles bot session management on top of the original scope.

### 7. Test Coverage Still Minimal

The app has 247 source files but still only ~13 test files, mostly disposal/widget tests. No integration tests, no service unit tests. As the codebase grows (now 78K+ lines), this becomes riskier.

### 8. Vision Service Stubs Still Present

The vision/OCR service files flagged in the original issues page are still stub implementations. Either implement or remove to reduce confusion.

### 9. Doc Page Filenames

The server documentation pages are still named `base-*.html` (e.g., `computer-overview.html`, `computer-api.html`). For consistency with the "Computer" rename, these could be renamed to `computer-*.html`. This would require updating all cross-links across all pages. Low priority but would complete the terminology migration.

### 10. No Search Functionality

The docs site has no search. With 14 pages of content, finding specific information requires clicking through pages. A simple client-side search (e.g., lunr.js or a static search index) would help.

### 11. Mobile Responsiveness

The docs site uses a fixed sidebar layout. On narrow screens the sidebar may overlap content. The `docs.css` should be checked for responsive breakpoints.

---

## Pages Audited

| Page | Status | Changes |
|------|--------|---------|
| `index.html` | Updated | Stats, terminology, module system description |
| `data-flow.html` | Updated | Curator → activity hooks, terminology |
| `integration.html` | Updated | Terminology, diagram labels |
| `app-overview.html` | Updated | Stats, timestamp |
| `app-chat.html` | Updated | Curator → post-session hooks, models, terminology |
| `app-daily.html` | Updated | Daily curator → generic agent system |
| `app-vault.html` | Updated | Terminology (3 occurrences) |
| `app-services.html` | Updated | Terminology |
| `computer-overview.html` | Updated | (prior session) |
| `computer-api.html` | Updated | (prior session) |
| `computer-orchestrator.html` | Updated | (prior session) |
| `computer-agents.html` | Updated | (prior session) |
| `computer-database.html` | Updated | (prior session) |
| `computer-connectors.html` | Created | New page for bot connectors |
| `issues.html` | Updated | Removed curator issue, fixed paths, updated stats |
| `file-manifest.html` | Updated | Stats, removed dead entries, added new files |
