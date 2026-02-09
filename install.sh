#!/usr/bin/env bash
set -e

# Bootstrap script for Parachute Computer.
#
# First time:  creates venv, installs deps, installs wrapper, runs setup.
# After that:  just use `parachute update` to pull + reinstall + restart.

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

echo "Parachute Computer — $REPO_DIR"
echo ""

# --- Check Python ---

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found. Install Python 3.11+ first."
    echo "  macOS:  brew install python@3.13"
    echo "  Ubuntu: sudo apt install python3 python3-venv"
    exit 1
fi

PY_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)

if [ "$PY_MAJOR" -lt 3 ] || { [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -lt 11 ]; }; then
    echo "Error: Python >= 3.11 required, found $PY_VERSION"
    exit 1
fi

echo "Python $PY_VERSION"

# --- Create / update venv ---

if [ ! -d "$REPO_DIR/.venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv "$REPO_DIR/.venv"
fi

echo "Installing dependencies..."
"$REPO_DIR/.venv/bin/pip" install --upgrade pip setuptools wheel -q
"$REPO_DIR/.venv/bin/pip" install -e "$REPO_DIR" -q

# --- Install wrapper to ~/.local/bin ---

WRAPPER="$HOME/.local/bin/parachute"
mkdir -p "$HOME/.local/bin"
cat > "$WRAPPER" <<SCRIPT
#!/usr/bin/env bash
exec "$REPO_DIR/.venv/bin/python" -m parachute "\$@"
SCRIPT
chmod +x "$WRAPPER"

# --- Check PATH ---

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    echo "~/.local/bin is not in your PATH."
    if [[ "$SHELL" == *"zsh"* ]]; then
        RC="~/.zshrc"
    else
        RC="~/.bashrc"
    fi
    echo "Add this to $RC:"
    echo ""
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
    echo "Then restart your shell and run: parachute install"
    exit 0
fi

# --- Run interactive setup ---

echo ""
exec "$REPO_DIR/.venv/bin/parachute" install
