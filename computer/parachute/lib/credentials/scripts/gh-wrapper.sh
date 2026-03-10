#!/bin/bash
set -euo pipefail
# gh CLI wrapper — authenticates via credential broker before each invocation.
# Deployed to /opt/parachute-tools/bin/gh (shadows /usr/bin/gh via PATH).
#
# Auto-detects org from the current repo's git remote, fetches a short-lived
# token from the broker, and execs the real gh with GH_TOKEN set.
#
# Requires: BROKER_SECRET env var, curl, jq, git

# Real gh binary — check both tools volume and system locations
GH_REAL=""
if [ -x "/opt/parachute-tools/bin/gh-real" ]; then
    GH_REAL="/opt/parachute-tools/bin/gh-real"
elif [ -x "/usr/bin/gh" ]; then
    # /usr/bin/gh is the actual binary (we're the wrapper in tools/bin/)
    GH_REAL="/usr/bin/gh"
else
    echo "Error: gh CLI not found" >&2
    exit 1
fi

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
    exec "$GH_REAL" "$@"
fi

# Validate org name — alphanumeric, hyphens, underscores only.
# Prevents URL injection via crafted git remote URLs.
if ! [[ "$ORG" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,38}$ ]]; then
    echo "Error: Invalid org name format: $ORG" >&2
    exec "$GH_REAL" "$@"
fi

# Need broker secret
if [ -z "${BROKER_SECRET:-}" ]; then
    echo "Error: BROKER_SECRET not set — credential broker unavailable" >&2
    exec "$GH_REAL" "$@"
fi

BROKER_URL="${CREDENTIAL_BROKER_URL:-http://host.docker.internal:3333/api}"

# Fetch token (broker resolves org -> installation internally)
TOKEN_RESULT=$(curl -sf --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer $BROKER_SECRET" \
    "${BROKER_URL}/credentials/github/token?org=${ORG}" 2>/dev/null) || {
    echo "Warning: Could not reach credential broker — running gh without auth" >&2
    exec "$GH_REAL" "$@"
}

TOKEN=$(echo "$TOKEN_RESULT" | jq -r '.token // empty')
if [ -z "$TOKEN" ]; then
    echo "Warning: Empty token from broker — running gh without auth" >&2
    exec "$GH_REAL" "$@"
fi

GH_TOKEN="$TOKEN" exec "$GH_REAL" "$@"
