#!/bin/bash
set -euo pipefail
# Git credential helper — called by git with protocol/host/path on stdin.
# Parses org from the repo path, fetches a short-lived token from the broker.
#
# Installed via: git config --system credential.helper '!/usr/local/bin/github-token-helper.sh'
# Requires: BROKER_SECRET env var, curl, jq

# Only handle "get" operations
if [ "$1" != "get" ]; then
  exit 0
fi

# Parse git's credential request from stdin
HOST=""
ORG=""
while IFS='=' read -r key value; do
  case "$key" in
    host) HOST="$value" ;;
    path) ORG="${value%%/*}" ;;
  esac
done

# Only handle github.com requests
if [ "$HOST" != "github.com" ]; then
  exit 0
fi

# Need an org to look up
if [ -z "$ORG" ]; then
  exit 1
fi

# Need broker secret
if [ -z "${BROKER_SECRET:-}" ]; then
  exit 1
fi

BROKER_URL="${CREDENTIAL_BROKER_URL:-http://host.docker.internal:3333/api}"

# Fetch token (broker resolves org -> installation internally)
TOKEN_RESULT=$(curl -sf --connect-timeout 5 --max-time 10 \
  -H "Authorization: Bearer $BROKER_SECRET" \
  "${BROKER_URL}/credentials/github/token?org=${ORG}" 2>/dev/null) || exit 1

TOKEN=$(echo "$TOKEN_RESULT" | jq -r '.token // empty')
if [ -z "$TOKEN" ]; then
  exit 1
fi

echo "protocol=https"
echo "host=github.com"
echo "username=x-access-token"
echo "password=$TOKEN"
