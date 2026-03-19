#!/bin/bash
set -euo pipefail
# wrangler CLI wrapper — authenticates via credential broker before each invocation.
# Deployed to /opt/parachute-tools/bin/wrangler (shadows system wrangler via PATH).
#
# Fetches a scoped token from the broker and injects it as CLOUDFLARE_API_TOKEN
# before exec-ing the real wrangler. Also ensures CLOUDFLARE_ACCOUNT_ID is set
# so wrangler doesn't need Memberships:Read permission.
#
# Requires: BROKER_SECRET env var, curl, jq

# Real wrangler binary — check tools volume and common locations
WRANGLER_REAL=""
if [ -x "/opt/parachute-tools/bin/wrangler-real" ]; then
    WRANGLER_REAL="/opt/parachute-tools/bin/wrangler-real"
elif command -v npx &>/dev/null; then
    WRANGLER_REAL="npx wrangler"
else
    for candidate in /usr/local/bin/wrangler /usr/bin/wrangler; do
        if [ -x "$candidate" ]; then
            WRANGLER_REAL="$candidate"
            break
        fi
    done
fi

if [ -z "$WRANGLER_REAL" ]; then
    echo "Error: wrangler CLI not found" >&2
    exit 1
fi

# Need broker secret
if [ -z "${BROKER_SECRET:-}" ]; then
    echo "Warning: BROKER_SECRET not set — running wrangler without broker auth" >&2
    exec $WRANGLER_REAL "$@"
fi

BROKER_URL="${CREDENTIAL_BROKER_URL:-http://host.docker.internal:3333/api}"

# Fetch token from broker
TOKEN_RESULT=$(curl -sf --connect-timeout 5 --max-time 10 \
    -H "Authorization: Bearer $BROKER_SECRET" \
    "${BROKER_URL}/credentials/cloudflare/token" 2>/dev/null) || {
    echo "Warning: Could not reach credential broker — running wrangler with existing env" >&2
    exec $WRANGLER_REAL "$@"
}

TOKEN=$(echo "$TOKEN_RESULT" | jq -r '.token // empty')
if [ -n "$TOKEN" ]; then
    export CLOUDFLARE_API_TOKEN="$TOKEN"
fi

# Also extract account_id if returned by broker
ACCOUNT_ID=$(echo "$TOKEN_RESULT" | jq -r '.account_id // empty')
if [ -n "$ACCOUNT_ID" ] && [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
    export CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID"
fi

exec $WRANGLER_REAL "$@"
