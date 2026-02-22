---
status: completed
priority: p2
issue_id: 94
tags: [code-review, security, brain-v2, python]
dependencies: []
---

# Brain v2: Default Password Fallback in TerminusDB Connection

## Problem Statement

`knowledge_graph.py` falls back to hardcoded password "root" when TERMINUSDB_ADMIN_PASS is not set, creating a security vulnerability in production deployments.

**Why it matters:** Default credentials are a critical security anti-pattern (CWE-798). If the environment variable is unset due to misconfiguration, the database becomes accessible with a well-known password.

## Findings

**Source:** security-sentinel agent (confidence: 90/100)

**Affected files:**
- `computer/modules/brain_v2/knowledge_graph.py:42-43`

**Current code:**
```python
password = os.getenv("TERMINUSDB_ADMIN_PASS", "root")
```

**Evidence:**
- Default "root" password is used if env var missing
- No validation that password was explicitly set
- README.md correctly instructs setting TERMINUSDB_ADMIN_PASS but doesn't enforce it
- server.py validates password exists (lines 213-223) but module doesn't verify

## Proposed Solutions

### Option A: Fail Fast on Missing Password (Recommended)
**Approach:** Raise exception during module initialization if TERMINUSDB_ADMIN_PASS not set

**Implementation:**
```python
password = os.getenv("TERMINUSDB_ADMIN_PASS")
if not password:
    raise ValueError(
        "TERMINUSDB_ADMIN_PASS environment variable required. "
        "Generate with: python -c 'import secrets; print(secrets.token_urlsafe(32))'"
    )
```

**Pros:**
- Forces explicit password configuration
- Fails at startup (not during first request)
- Clear error message with remediation steps
- Aligns with server.py validation pattern

**Cons:**
- Requires environment variable in all environments

**Effort:** Small (10 minutes)
**Risk:** Low

### Option B: Delegate to Existing Validation
**Approach:** Remove fallback, rely on server.py validation (lines 213-223)

**Pros:**
- Single source of truth for password validation
- No duplication

**Cons:**
- Less clear where validation happens
- Potential for inconsistency if module is loaded independently

**Effort:** Minimal (5 minutes)
**Risk:** Low

### Option C: Secure Random Generation
**Approach:** Generate random password if not set, log warning

**Pros:**
- Backwards compatible
- No default credentials

**Cons:**
- Hides misconfiguration
- Password changes on restart (not suitable for persistent DB)
- Still allows running without explicit config

**Effort:** Small (20 minutes)
**Risk:** Medium

## Recommended Action

(To be filled during triage)

## Technical Details

**Affected components:**
- `KnowledgeGraphService.__init__()` and `connect()` method
- TerminusDB authentication flow

**Current flow:**
1. server.py validates TERMINUSDB_ADMIN_PASS at startup (lines 213-223)
2. Module reads same env var with fallback
3. Inconsistency: server blocks startup but module would proceed with "root"

**Alignment note:** server.py already implements Option A validation. Module should match this pattern.

## Acceptance Criteria

- [ ] No hardcoded "root" password in code
- [ ] Clear error message if TERMINUSDB_ADMIN_PASS unset
- [ ] Error message includes generation command
- [ ] Fails at module initialization (not lazy-loaded connect)
- [ ] Manual test: Unset env var, verify error on startup

## Work Log

### 2026-02-22
- **Created:** security-sentinel agent flagged during /para-review of PR #97
- **Note:** server.py already validates password; module should align with this approach

## Resources

- **PR:** #97 (Brain v2 TerminusDB MVP)
- **Review agent:** security-sentinel
- **CWE-798:** [Use of Hard-coded Credentials](https://cwe.mitre.org/data/definitions/798.html)
- **Related code:** `computer/parachute/server.py:213-223` (existing validation)
