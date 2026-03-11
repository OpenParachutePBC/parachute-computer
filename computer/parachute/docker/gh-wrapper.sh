#!/bin/bash
set -euo pipefail
# gh CLI wrapper — authenticates via credential broker before each invocation.
# Replaces /usr/bin/gh; the real binary is moved to /usr/bin/gh-real.
#
# Auto-detects org from the current repo's git remote, fetches a short-lived
# token from the broker, and execs the real gh with GH_TOKEN set.
#
# Requires: BROKER_SECRET env var, curl, jq, git

# Auto-detect org from git remote
ORG=""
if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
    if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+)/ ]]; then
        ORG="${BASH_REMATCH[1]}"
    fi
fi

# Fallback to env var
if [ -z "$ORG" ]; then
    ORG="${GH_DEFAULT_ORG:-}"
fi

if [ -z "$ORG" ]; then
    echo "Error: Cannot determine GitHub org (no git remote or GH_DEFAULT_ORG)" >&2
    # Fall through to real gh without auth — it may work for public operations
    exec /usr/bin/gh-real "$@"
fi

# Need broker secret
if [ -z "${BROKER_SECRET:-}" ]; then
    echo "Error: BROKER_SECRET not set — credential broker unavailable" >&2
    exec /usr/bin/gh-real "$@"
fi

BROKER_URL="${CREDENTIAL_BROKER_URL:-http://host.docker.internal:3333/api}"

# Fetch token (broker resolves org -> installation internally)
TOKEN_RESULT=$(curl -sf --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer $BROKER_SECRET" \
    "${BROKER_URL}/credentials/github/token?org=${ORG}" 2>/dev/null) || {
    echo "Warning: Could not reach credential broker — running gh without auth" >&2
    exec /usr/bin/gh-real "$@"
}

TOKEN=$(echo "$TOKEN_RESULT" | jq -r '.token // empty')
if [ -z "$TOKEN" ]; then
    echo "Warning: Empty token from broker — running gh without auth" >&2
    exec /usr/bin/gh-real "$@"
fi

GH_TOKEN="$TOKEN" exec /usr/bin/gh-real "$@"
