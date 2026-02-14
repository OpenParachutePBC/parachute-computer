#!/bin/bash
# Parachute Computer Setup Script
# This sets up the Lima VM for running Parachute with full isolation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/parachute.yaml"

echo "╔══════════════════════════════════════════════════════╗"
echo "║        Parachute Computer Setup                      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# Check if Lima is installed
if ! command -v limactl &> /dev/null; then
    echo "Lima is not installed."
    echo ""

    # Check if Homebrew is available
    if command -v brew &> /dev/null; then
        echo "Installing Lima via Homebrew..."
        brew install lima
    else
        echo "Please install Lima manually:"
        echo "  brew install lima"
        echo ""
        echo "Or see: https://lima-vm.io/docs/installation/"
        exit 1
    fi
fi

echo "✓ Lima is installed: $(limactl --version)"
echo ""

# Check if VM already exists
if limactl list --json 2>/dev/null | grep -q '"name":"parachute"'; then
    echo "Parachute VM already exists."

    # Check if running
    if limactl list --json | grep -A5 '"name":"parachute"' | grep -q '"status":"Running"'; then
        echo "✓ VM is already running"
    else
        echo "Starting VM..."
        limactl start parachute
    fi
else
    echo "Creating Parachute VM..."
    echo "This will download Ubuntu and set up the environment."
    echo "This may take a few minutes on first run."
    echo ""

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Error: Config file not found at $CONFIG_FILE"
        exit 1
    fi

    limactl start "$CONFIG_FILE"
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║        Parachute Computer is ready!                  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Your home directory (~) inside the VM IS your Parachute vault."
echo "Claude can only access files in your vault - complete isolation."
echo ""
echo "Quick start:"
echo "  lima                    # Enter the VM"
echo "  claude login            # Authenticate with Claude"
echo "  start-server            # Start the Parachute server"
echo ""
echo "The server will be accessible at http://localhost:3333"
echo ""
echo "To stop: limactl stop parachute"
echo "To start: limactl start parachute"
