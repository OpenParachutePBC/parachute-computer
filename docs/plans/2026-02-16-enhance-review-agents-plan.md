---
title: "enhance: Improve review agents for Python/Flutter codebase"
type: enhance
date: 2026-02-16
---

# Improve Review Agents for Python/Flutter Codebase

## Overview

Improve existing review agents to produce higher-signal, lower-noise reviews tailored to our Python/FastAPI + Flutter/Riverpod stack. Fix broken/misaligned agents, deepen framework expertise, add confidence scoring, and add staged review presentation.

**Brainstorm:** `docs/brainstorms/2026-02-16-improve-review-agents-brainstorm.md`
**Issue:** #44

## Problem Statement

Our review agents were forked from compound-engineering (a Rails/TypeScript project) and partially adapted. Research uncovered several critical issues:

1. **`security-sentinel` is broken** — has JS/Rails grep patterns (`req.(body|params|query)` in `.js` files), references Rails strong parameters and CSRF. None of this applies to our stack.
2. **`flutter-reviewer` is misaligned with the actual codebase** — mandates `@riverpod` code generation and flags `StateNotifierProvider`/`StateProvider` as instant failures, but the *entire codebase* uses these patterns. Zero `.g.dart` files exist. The agent would fail virtually every provider file.
3. **`python-reviewer` references patterns not in the codebase** — mentions `Depends()` DI chains (our routes call orchestrator directly) and `pydantic-settings` (we use a manual Settings class).
4. **`performance-oracle` has Rails references** — mentions ActiveRecord query optimization and "5KB bundle size per feature."
5. **No noise filtering** — every finding treated equally. No confidence scoring.
6. **No staged review** — all agents run in parallel with flat output.

## Proposed Solution

Five implementation phases, ordered by impact and dependency:

### Phase 1: Fix Misaligned Agents (Critical — Agents Actively Wrong)

#### 1A. Rewrite `security-sentinel.md`

Replace the entire file with Python/FastAPI + Flutter/Dart + Parachute-specific security patterns.

**Python/FastAPI patterns:**
- `pickle.loads()` on untrusted data → arbitrary code execution
- `yaml.load()` without `Loader=SafeLoader` → arbitrary code execution
- `eval()`/`exec()` with any external input
- `subprocess.Popen(shell=True)` with interpolated strings
- SQL string formatting (use parameterized queries)
- FastAPI CORS: `allow_origins=["*"]` in non-development config
- Pydantic bypass: `model_construct()` on external data (skips validation)
- Missing auth on routes that should be protected
- Hardcoded secrets (use env vars or `config.yaml`)
- Path traversal in file operations (validate against vault boundaries)
- `tempfile.mktemp()` race condition (use `mkstemp()` or `NamedTemporaryFile()`)

**Flutter/Dart patterns:**
- Hardcoded API keys or secrets in Dart code
- `SharedPreferences` for sensitive data (use `flutter_secure_storage`)
- Insecure HTTP connections (non-HTTPS) to non-localhost
- Platform channel data exposure without validation
- Deep link path handling without input validation
- `BuildContext` used after async gap without `mounted` check (security implications for navigation)

**Parachute-specific patterns (complement parachute-conventions-reviewer, don't duplicate):**
- Untrusted sources (Telegram, Discord) not defaulting to Docker/sandboxed trust level
- MCP tool accepting arbitrary text for execution without input schema constraints
- Tool capable of modifying system config (.bashrc, SSH keys) from untrusted context
- External data reaching system prompts without sanitization (prompt injection surface)
- Container escape vectors: symlinks, broad volume mounts, missing capability drops
- API key stored in plaintext (should be SHA-256 hashed)
- Missing `secrets.compare_digest` for token comparison (timing attack)

**Keep the reporting protocol** (executive summary, detailed findings, risk matrix, remediation roadmap) — that part is fine.

**Delineation from other agents:** security-sentinel owns *vulnerability* findings. python-reviewer section 12 owns *code safety* patterns (the overlap on `pickle`/`eval`/`exec` is intentional redundancy — Anthropic's pattern uses multi-agent redundancy for critical checks). parachute-conventions-reviewer owns *architectural security* (trust levels, module boundaries, prompt injection defense at the design level).

`.claude/agents/review/security-sentinel.md`

#### 1B. Fix `flutter-reviewer.md` Riverpod Section

The Riverpod section (section 6) must match the actual codebase patterns:

**Replace code-generation mandates with the patterns actually used:**
- Remove: "FAIL: ANY use of `StateNotifierProvider`, `StateProvider`, or `ChangeNotifierProvider`"
- Remove: All `@riverpod` annotation requirements, `.g.dart` references
- Add: Manual provider declaration patterns (`final myProvider = Provider<T>((ref) => ...)`)
- Keep: `ref.watch` in build, `ref.read` only in callbacks, `ref.listen` for side effects, `ref.invalidate` over manual reset, `ref.onDispose` for cleanup — these rules are correct
- Add: Provider type selection table matching `app/CLAUDE.md`:
  - `Provider<T>` for singleton services
  - `FutureProvider<T>.autoDispose` for async data that should refresh
  - `StateNotifierProvider` for complex mutable state
  - `StreamProvider` for reactive streams
  - `StateProvider` for simple UI state
  - `AsyncNotifier` (without code gen) for async state with CRUD

**Fix architecture section (section 7):**
- Replace `lib/src/features/.../data/domain/presentation/` with actual structure:
  ```
  lib/
    core/       # shared providers, services, models, theme, widgets
    features/
      chat/     # models/, providers/, services/, screens/, widgets/
      daily/    # journal/, recorder/, capture/, search/
      brain/
      vault/
      settings/
      onboarding/
  ```

**Add app-specific conventions from `app/CLAUDE.md`:**
- Theme: Use `BrandColors.forest` not `DesignTokens.forestGreen`
- Layout overflow prevention rules (bottom sheets, rows with badges, dialog dimensions)
- `ref.listen` must be inside `build()`, never in `initState` or callbacks
- Sherpa-ONNX pin: must use 1.12.20 (1.12.21+ crashes)
- Core package is inlined — do NOT re-add as dependency
- `ChatSession` API: no `module` field, `title` is nullable (use `displayTitle`)

`.claude/agents/review/flutter-reviewer.md`

#### 1C. Fix `python-reviewer.md` Codebase Alignment

Small targeted fixes:

- [ ] Update DI section: Routes call orchestrator directly, not through `Depends()` chains. `Depends()` is used for cross-cutting concerns (auth middleware), not for the service layer.
- [ ] Update config reference: Manual `Settings` class in `config.py` with precedence: env vars > `.env` > `vault/.parachute/config.yaml` > defaults. Not `pydantic-settings`.
- [ ] Add: Routers call orchestrator, never touch DB directly (from `computer/CLAUDE.md`)
- [ ] Add: SSE streaming via async generators in orchestrator
- [ ] Add: Module-level `logger = logging.getLogger(__name__)` (from `computer/CLAUDE.md`)
- [ ] Add: Session permissions model with glob-based file access patterns

`.claude/agents/review/python-reviewer.md`

#### 1D. Fix `performance-oracle.md` Stack References

- [ ] Remove Rails/ActiveRecord references
- [ ] Remove "5KB bundle size per feature" web-centric metric
- [ ] Add: SSE streaming throughput concerns
- [ ] Add: SQLite query efficiency patterns
- [ ] Add: Docker container startup latency
- [ ] Add: `asyncio.to_thread()` for blocking operations
- [ ] Add: Flutter widget rebuild optimization (`MediaQuery.sizeOf(context)`, `const` widgets, `ListView.builder`)

`.claude/agents/review/performance-oracle.md`

### Phase 2: Deepen Framework Expertise

#### 2A. Deepen `python-reviewer.md` with FastAPI Depth

Add ~30 lines of deeper patterns:

- [ ] **Dependency injection philosophy:** `Depends()` for auth, rate limiting, pagination — not for the service layer. Middleware is acceptable for request timing, CORS, and logging. Don't be dogmatic.
- [ ] **Pydantic v2 patterns:** `model_validator(mode='before')` for complex validation, `field_validator` for single-field rules, computed fields via `@computed_field`, `ConfigDict(from_attributes=True)` for ORM mapping
- [ ] **Structured concurrency:** `asyncio.TaskGroup` over `gather()` (auto-cancellation on failure), proper `CancelledError` handling, never fire-and-forget `create_task()`
- [ ] **FastAPI lifespan:** `@asynccontextmanager async def lifespan(app)` over deprecated `@app.on_event("startup")`
- [ ] **Error propagation across MCP:** Domain exceptions translate to structured MCP error responses, not raw HTTP errors

`.claude/agents/review/python-reviewer.md`

#### 2B. Deepen `flutter-reviewer.md` with Riverpod Depth

Add ~30 lines of deeper patterns:

- [ ] **Provider lifecycle:** Auto-dispose is the default and almost always correct. `keepAlive: true` only for app-wide singletons (auth state, server connection, module config). Provider disposal order matters — dispose listeners before the source.
- [ ] **Notifier design:** Use `AsyncNotifier` when state has CRUD operations with methods. Use function providers when deriving a value from other providers with no mutation. If a Notifier has no methods beyond `build()`, it should be a function provider.
- [ ] **`select()` for granular rebuilds:** When watching a provider with many fields but only using one, use `ref.watch(provider.select((state) => state.specificField))` to avoid unnecessary rebuilds.
- [ ] **`family` provider memory:** Family providers with many distinct parameter values grow memory. Use `.autoDispose` on families to prevent leaks.
- [ ] **Platform-specific code:** `Platform.isIOS`/`Platform.isAndroid` checks should be in platform service providers, not scattered in widgets. Sherpa-ONNX integration via isolates with `ref.onDispose` for cleanup.

`.claude/agents/review/flutter-reviewer.md`

### Phase 3: Add Confidence Scoring

Add confidence scoring instructions to all review agents that produce findings. Each finding gets scored 0-100.

**Scoring rubric (add to each agent):**

```markdown
## Confidence Scoring

Score every finding 0-100. Only report findings scoring 80+.

**90-100 — Certain:** Clear evidence in code. Definite bug, vulnerability, or convention violation.
  Example: `ref.read()` called inside `build()` → 95 (greppable, always wrong)
  Example: `pickle.loads(user_input)` → 98 (always a vulnerability)

**80-89 — High confidence:** Strong signal, pattern clearly matches a known issue.
  Example: Missing `ref.onDispose()` with a StreamSubscription → 85 (likely leak, but could be managed elsewhere)
  Example: `async def` route calling sync DB without `to_thread()` → 82 (depends on call frequency)

**70-79 — Moderate:** Possibly intentional or context-dependent. DO NOT REPORT unless security-related.
  Example: Broad CORS config in development-only code → 72 (intentional for dev)

**Below 70 — Low:** Likely noise. DO NOT REPORT.

**Filtering rules — always exclude:**
- Pre-existing issues not introduced in this PR/change
- Issues that ruff or dart analyze would catch
- General quality complaints not tied to a specific convention from this agent
- Nitpicks on code that was not modified in this change

**Exception: Security floor.** Security findings that score 60+ are ALWAYS reported, even below the 80 threshold. A below-threshold security finding should be labeled: "⚠️ Low confidence security finding — may be intentional, please verify."
```

**Apply to these agents:**

- [ ] `security-sentinel.md` (already being rewritten — include from the start)
- [ ] `python-reviewer.md`
- [ ] `flutter-reviewer.md`
- [ ] `parachute-conventions-reviewer.md`
- [ ] `performance-oracle.md`
- [ ] `code-simplicity-reviewer.md`
- [ ] `architecture-strategist.md`
- [ ] `pattern-recognition-specialist.md`
- [ ] `agent-native-reviewer.md`

All 9 review agents get scoring for consistency.

### Phase 4: Add Staged Review Presentation to `para-review`

Add staged presentation to the synthesis step (section 5) of `para-review.md`. All agents still run in parallel — staging is for presentation and gating, not execution order.

**Stage 1: Spec Compliance** (performed by the lead during synthesis, not a separate agent)
- If PR links to an issue or plan, compare the diff against acceptance criteria
- Flag missing scope (acceptance criteria not addressed) and extra scope (changes not in the spec)
- If no linked issue/plan exists, use PR title + description as the spec (don't fail — just note "no formal spec found")
- This stage is advisory — it never blocks the review, just provides context

**Stage 2: Framework Conventions** (python-reviewer, flutter-reviewer, parachute-conventions-reviewer findings)
- Language/framework idioms
- Project-specific patterns
- Module boundary compliance

**Stage 3: Cross-Cutting Quality** (security-sentinel, performance-oracle, architecture-strategist, code-simplicity-reviewer, pattern-recognition-specialist, agent-native-reviewer findings)
- Security vulnerabilities
- Performance issues
- Architectural concerns
- Code quality and patterns

**Presentation format update:** Modify the summary report template to group findings by stage:

```markdown
## Review Results

### Stage 1: Spec Compliance
[Spec comparison or "No formal spec linked"]

### Stage 2: Framework Conventions (X findings)
**P1 Critical:** ...
**P2 Important:** ...

### Stage 3: Cross-Cutting Quality (Y findings)
**P1 Critical:** ...
**P2 Important:** ...
```

**Deduplication:** When multiple agents flag the same issue (same file:line, similar description), merge into one finding with the highest severity and list all contributing agents.

`.claude/commands/para-review.md`

### Phase 5: Cleanup

- [ ] Remove `git-history-analyzer` references from `para-review.md` (agent doesn't exist as a file — it's a built-in Task subagent type, not a custom agent)
- [ ] Fix inconsistent section numbering in `para-review.md` (sections go 1, 4, 6, 4, 5, 7)

## Acceptance Criteria

- [ ] `security-sentinel.md` has zero JS/Rails patterns and covers Python, Flutter, and Parachute-specific security
- [ ] `flutter-reviewer.md` Riverpod section matches actual codebase (manual providers, no code-gen mandate)
- [ ] `flutter-reviewer.md` architecture section matches actual `lib/` structure
- [ ] `python-reviewer.md` references actual patterns (orchestrator layer, manual Settings, SSE streaming)
- [ ] `performance-oracle.md` has zero Rails references, covers SSE/SQLite/Docker/Flutter performance
- [ ] All 9 review agents include confidence scoring rubric with 80+ threshold and security floor at 60
- [ ] `para-review.md` presents findings in staged format (spec compliance → conventions → quality)
- [ ] `para-review.md` includes deduplication logic for overlapping findings
- [ ] `para-review.md` section numbering is consistent
- [ ] No references to `git-history-analyzer` as a custom agent (it's a built-in subagent type)

## Success Metrics

- Review findings are actionable (fewer "noise" findings that get dismissed)
- Security findings are relevant to our actual stack (Python/FastAPI, Flutter/Dart, Docker sandbox)
- Flutter reviewer doesn't flag the entire codebase as wrong
- Staged presentation makes it easy to see the most important issues first

## Dependencies & Risks

- **No runtime dependencies** — all changes are to markdown agent/command files
- **Risk: Over-opinionation** — being too prescriptive could flag legitimate code as wrong. Mitigation: confidence scoring with security floor.
- **Risk: Drift** — agents could drift from codebase again as patterns evolve. Mitigation: `parachute-conventions-reviewer` and CLAUDE.md are the source of truth; agents should reference them.

## References & Research

- **Brainstorm:** `docs/brainstorms/2026-02-16-improve-review-agents-brainstorm.md`
- **Issue:** #44
- **Anthropic Code Review Plugin:** https://github.com/anthropics/claude-code/blob/main/plugins/code-review/README.md (confidence scoring pattern)
- **Compound Engineering Plugin:** https://github.com/EveryInc/compound-engineering-plugin (original agent source)
- **Kieran Klaassen:** https://every.to/source-code/i-stopped-reading-code-my-code-reviews-got-better (persona-based review)
- **Three-Stage Code Review:** https://gist.github.com/marostr/4ff8fff0b930a615998097a36a4eae37 (staged gating)
- **Existing agents:** `.claude/agents/review/` (9 files, 1115 lines total)
- **Existing command:** `.claude/commands/para-review.md` (508 lines)
- **Computer conventions:** `computer/CLAUDE.md`
- **App conventions:** `app/CLAUDE.md`
