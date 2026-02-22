---
status: pending
priority: p3
issue_id: 62
tags: [code-review, security, documentation, sandbox]
created: 2026-02-21
---

# Session ID Validation Regex Lacks Explanatory Comment

## Problem Statement

The session ID validation regex in `entrypoint.py` correctly prevents path traversal attacks but doesn't include a comment explaining *why* this specific pattern is used or what attacks it prevents. Future maintainers might not understand the security purpose.

**Impact:** Low - Code works correctly, but lacks documentation for maintainability and security awareness.

**Introduced in:** Commit 8f93d13 (per-session scratch directories)

## Findings

**Source:** Security Sentinel (Confidence: 82)

**Current code:**
```python
# computer/parachute/docker/entrypoint.py:104-108
session_id = os.environ.get("PARACHUTE_SESSION_ID")
if session_id and not re.match(r'^[a-zA-Z0-9_-]+$', session_id):
    emit({"type": "error", "error": "Invalid PARACHUTE_SESSION_ID format"})
    sys.exit(1)
```

**What's missing:**
No comment explaining that this regex prevents path traversal attacks like:
- `../` to escape scratch directory
- `/` to specify absolute paths
- `.` for current directory manipulation

**Why this matters:**
1. Future developers might relax the regex without understanding security implications
2. Code reviewers can't verify the pattern is correct without context
3. Security auditors need to understand the threat model

## Proposed Solutions

### Solution 1: Add Inline Security Comment (Recommended)

**Approach:** Add a comment above the validation explaining the security purpose.

**Implementation:**
```python
# computer/parachute/docker/entrypoint.py:104-111
session_id = os.environ.get("PARACHUTE_SESSION_ID")
if session_id:
    # Security: Prevent path traversal in /scratch/{session_id}/ paths.
    # Only allow alphanumeric, underscore, and hyphen (no /, \, ., or other special chars).
    # This prevents attacks like "../" (parent dir), "/" (absolute path), etc.
    if not re.match(r'^[a-zA-Z0-9_-]+$', session_id):
        emit({"type": "error", "error": "Invalid PARACHUTE_SESSION_ID format"})
        sys.exit(1)
```

**Pros:**
- Documents security rationale inline
- Helps future maintainers understand why pattern is strict
- Minimal code change (just comments)

**Cons:**
- None

**Effort:** Minimal (5 minutes)
**Risk:** None

### Solution 2: Extract to Named Function with Docstring

**Approach:** Move validation to a separate function with comprehensive docstring.

**Implementation:**
```python
def validate_session_id(session_id: str) -> bool:
    """Validate session ID format to prevent path traversal attacks.

    Session IDs are used in paths like /scratch/{session_id}/, so they must not
    contain path separators (/, \) or traversal sequences (., ..).

    Allowed characters: alphanumeric, underscore, hyphen

    Args:
        session_id: The session ID to validate

    Returns:
        True if valid, False otherwise

    Security:
        Prevents attacks like:
        - "../../../etc/passwd" (parent directory traversal)
        - "/etc/passwd" (absolute path)
        - "./sensitive" (current directory)
    """
    return bool(re.match(r'^[a-zA-Z0-9_-]+$', session_id))

# In main code:
if session_id and not validate_session_id(session_id):
    emit({"type": "error", "error": "Invalid PARACHUTE_SESSION_ID format"})
    sys.exit(1)
```

**Pros:**
- Comprehensive documentation
- Testable in isolation
- More formal documentation style

**Cons:**
- More verbose for a simple validation
- Adds function overhead for one use

**Effort:** Small (15 minutes)
**Risk:** Very low

## Recommended Action

Implement **Solution 1** - add an inline comment. The validation is simple enough that a well-placed comment is sufficient documentation without adding unnecessary abstraction.

## Technical Details

**Affected files:**
- `/Volumes/ExternalSSD/Parachute/Projects/parachute-computer/computer/parachute/docker/entrypoint.py:104-108`

**Components:**
- Docker entrypoint validation
- Session ID security

**Threat model:**
- **Attacker goal:** Escape /scratch/{session_id}/ directory to access other sessions or container filesystem
- **Attack vectors:** Path traversal via special characters in session_id
- **Mitigation:** Strict alphanumeric-only regex

**Database changes:** None

## Acceptance Criteria

- [ ] Add security comment above session ID validation
- [ ] Comment explains path traversal prevention
- [ ] Comment lists specific attack examples (../, /, .)
- [ ] Regex pattern remains unchanged

## Work Log

- **2026-02-21**: Issue identified during security review of commit 8f93d13

## Resources

**Related commits:**
- 8f93d13 - feat(sandbox): per-session scratch directories

**Security best practices:**
- OWASP Path Traversal: https://owasp.org/www-community/attacks/Path_Traversal
- Input validation for filesystem paths
