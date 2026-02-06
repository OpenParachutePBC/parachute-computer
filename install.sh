#!/usr/bin/env bash
set -e

# Always run from the repo root (where this script lives)
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

echo "Installing from $REPO_DIR"

# Create venv if needed
if [ ! -d "$REPO_DIR/.venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$REPO_DIR/.venv"
fi

echo "Installing parachute-computer..."
"$REPO_DIR/.venv/bin/pip" install -e "$REPO_DIR" -q

# Run setup
"$REPO_DIR/.venv/bin/parachute" setup

echo ""
echo "================================================"
echo "  To use parachute, activate the venv first:"
echo ""
echo "    source $REPO_DIR/.venv/bin/activate"
echo "    parachute server"
echo "================================================"
