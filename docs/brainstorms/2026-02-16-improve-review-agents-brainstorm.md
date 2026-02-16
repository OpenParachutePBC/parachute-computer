---
title: Improve Review Agents for Python/Flutter Codebase
type: enhancement
date: 2026-02-16
modules: [computer, app]
labels: [brainstorm, computer, app, P2]
---

# Improve Review Agents for Python/Flutter Codebase

## What We're Building

Improve our existing review agents to produce higher-signal, lower-noise reviews that are deeply tailored to our Python/FastAPI + Flutter/Riverpod stack. Not adding new agents — making the ones we have actually great.

Three tracks:

1. **Rewrite `security-sentinel`** — currently has JavaScript/Rails patterns that don't apply to our codebase at all
2. **Deepen `python-reviewer` and `flutter-reviewer`** — add framework-creator-level opinions (Tiangolo for FastAPI, Remi Rousselet for Riverpod), confidence scoring, and codebase-specific conventions
3. **Add confidence scoring and staged review** to `para-review` command — filter noise, gate reviews (spec compliance -> conventions -> quality)

## Why This Approach

### The Problem

Our agents were forked from compound-engineering (a Rails/TypeScript project) and adapted. The Python and Flutter reviewers are strong, but:

- **`security-sentinel` is broken for our stack** — it literally greps for `req.(body|params|query)` in `.js` files and has a "When reviewing Rails applications" section. We have neither JS nor Rails.
- **No noise filtering** — every finding is treated equally. A naming nit sits next to a security hole. Anthropic's official code-review plugin scores findings 0-100 and filters below 80. We don't.
- **Missing framework-depth** — our reviewers encode good patterns but don't go as deep as the best. Kieran's agents at Every encode *his specific taste* (e.g., "Turbo Streams simple operations MUST use inline arrays, not separate `.turbo_stream.erb` files"). Our equivalents would be Tiangolo's opinions on dependency injection or Remi's opinions on provider scoping.

### What the Best Do Differently (Research Findings)

Studied compound-engineering, Kieran Klaassen's agents (Every.io), DHH Rails agent, Anthropic's official code-review plugin, and several open-source agent collections. Key patterns:

1. **Confidence scoring + filtering** (Anthropic) — Score 0-100, threshold at 80. Explicitly list what to filter: pre-existing issues, linter catches, pedantic nitpicks.
2. **Bifurcated strictness** (Kieran) — Very strict on modifications to existing code. Pragmatic on new isolated code. We already do this.
3. **Persona-based opinions** (DHH/Kieran) — Not "follow best practices" but "follow this person's specific taste." The most effective agents encode a specific person's opinionated conventions.
4. **Staged/gated reviews** (marostr) — Check spec compliance first ("did you build what was asked?"), then conventions, then quality. Each gates the next.
5. **10% LLM / 90% deterministic code** (pmihaylov) — Encode checks in scripts where possible, use LLM for judgment calls.

### What We Already Have (and It's Good)

- **`python-reviewer`** (155 lines) — Bifurcated strictness, pass/fail examples, FastAPI/Pydantic/async patterns, 5-second naming rule. Already close to Kieran's style.
- **`flutter-reviewer`** (175 lines) — Deep Riverpod rules (legacy provider = instant fail, ref.read in build = instant fail), widget composition, performance patterns, feature-first architecture.
- **`parachute-conventions-reviewer`** (143 lines) — Project-specific: module boundaries, trust levels, prompt injection defense, MCP tool design. Solid.

These don't need rewriting. They need deepening and a noise-filtering layer on top.

## Key Decisions

### 1. Rewrite security-sentinel for Python/Flutter (not patch — rewrite)

The current file is ~90% irrelevant to our stack. Replace with:

**Python/FastAPI security patterns:**
- `pickle.loads()` on untrusted data
- `yaml.load()` without `SafeLoader`
- `eval()`/`exec()` with external input
- `subprocess.Popen(shell=True)` with interpolated strings
- SQL string formatting (use parameterized queries)
- FastAPI CORS misconfiguration (`allow_origins=["*"]`)
- Pydantic validation bypass (`model_construct()` on external data)
- Missing `Depends()` auth on routes
- Hardcoded secrets (use `pydantic-settings`)
- Path traversal in file operations (use `pathlib` with validation)
- JWT/token handling issues (expiry, rotation, storage)

**Flutter/Dart security patterns:**
- Insecure HTTP (non-HTTPS) connections
- Hardcoded API keys in Dart code
- Platform channel data exposure
- Deep link hijacking / intent validation
- Insecure local storage (SharedPreferences for sensitive data)
- WebView JavaScript injection
- Certificate pinning absence

**Parachute-specific security:**
- Trust level violations (Telegram/Discord at wrong trust level)
- Prompt injection surface in MCP tools
- Module boundary violations that create security gaps
- Vault access from sandboxed context

### 2. Deepen python-reviewer with Tiangolo-level FastAPI opinions

Add sections for:
- **Dependency injection philosophy** — Tiangolo's pattern of dependencies as the primary abstraction. `Depends()` for everything cross-cutting, not middleware.
- **Pydantic v2 patterns** — `model_validator`, `field_validator`, computed fields, JSON schema customization
- **Structured concurrency** — `asyncio.TaskGroup` over `gather()`, proper cancellation
- **Our module system patterns** — how modules register, how MCP tools are defined, vault structure conventions

### 3. Deepen flutter-reviewer with Remi-level Riverpod opinions

Add sections for:
- **Provider lifecycle management** — Remi's opinions on `keepAlive`, auto-dispose, ref.onDispose patterns
- **Notifier design** — when to use `AsyncNotifier` vs function providers, state mutation patterns
- **Testing providers** — `ProviderContainer.test()` patterns, override strategies
- **Our app-specific patterns** — module screen structure, server connection provider, theme conventions

### 4. Add confidence scoring to all review agents

Each finding gets a confidence score (0-100):
- **90-100**: Definite bug, security hole, or convention violation with clear evidence
- **70-89**: Likely issue, strong signal but could be intentional
- **50-69**: Possible issue, worth noting but may be noise
- **Below 50**: Filtered out, don't report

Filtering rules (inspired by Anthropic's plugin):
- Pre-existing issues not introduced in this PR → filter
- Issues that linters already catch (ruff, dart analyze) → filter
- General quality complaints not tied to a specific convention → filter
- Pedantic nitpicks on code the PR didn't modify → filter

### 5. Add staged review to para-review command

Three stages, each gating the next:

**Stage 1: Spec Compliance** — "Did you build what was asked?"
- Compare PR against linked issue/plan
- Check that acceptance criteria are met
- Flag missing or extra scope
- If this fails, stop — don't review style on wrong code

**Stage 2: Framework Conventions** — python-reviewer / flutter-reviewer / parachute-conventions-reviewer
- Language/framework idioms
- Project-specific patterns
- Module boundary compliance

**Stage 3: Cross-Cutting Quality** — security-sentinel, performance-oracle, architecture-strategist, etc.
- Security vulnerabilities
- Performance issues
- Architectural concerns
- Agent-native accessibility

## Open Questions

1. **How opinionated should we get?** The DHH agent literally rejects service objects for CRUD apps. Should our FastAPI agent reject certain patterns that strongly (e.g., rejecting middleware for cross-cutting concerns in favor of `Depends()`)? Leaning yes — strong opinions create consistency.

2. **Should confidence scoring be in the agents or in para-review?** Could add scoring instructions to each agent, OR add a filtering pass in para-review that scores findings after collection. Leaning: in each agent (findings arrive pre-scored, less post-processing).

3. **Staged review adds latency** — running Stage 1 before Stage 2 means sequential, not parallel. Worth the trade-off? Could run all in parallel but present results in staged order with gating. Leaning: parallel execution, staged presentation.

## Scope & Effort

| Track | Files | Effort |
|-------|-------|--------|
| Rewrite security-sentinel | 1 agent file | Medium — research Python/Flutter security patterns |
| Deepen python-reviewer | 1 agent file | Small — add ~30 lines of deeper patterns |
| Deepen flutter-reviewer | 1 agent file | Small — add ~30 lines of deeper patterns |
| Add confidence scoring | 3 agent files + para-review command | Medium — scoring instructions + filtering logic |
| Add staged review | para-review command | Small — restructure existing command |

Total: ~5 files, medium effort overall. No new agents needed.

## References

- [Anthropic Official Code Review Plugin](https://github.com/anthropics/claude-code/blob/main/plugins/code-review/README.md) — confidence scoring pattern
- [Compound Engineering Plugin](https://github.com/EveryInc/compound-engineering-plugin) — original source of our agents
- [Kieran Klaassen: I Stopped Reading Code](https://every.to/source-code/i-stopped-reading-code-my-code-reviews-got-better) — persona-based review pattern
- [Three-Stage Code Review](https://gist.github.com/marostr/4ff8fff0b930a615998097a36a4eae37) — staged/gated review pattern
- [Building an AI Code Reviewer](https://pmihaylov.com/code-reviews-with-claude-code/) — 10% LLM / 90% deterministic pattern
- [FastAPI Best Practices (Tiangolo)](https://fastapi.tiangolo.com/tutorial/dependencies/) — dependency injection philosophy
- [Riverpod Documentation (Remi Rousselet)](https://riverpod.dev/) — provider design patterns
