#!/bin/bash
#
# Parachute Agent Installation Script for macOS
#
# This script sets up the Parachute Agent to run as a background service
# on macOS using launchd.
#
# Authentication: Uses Claude CLI (`claude login`), NOT API keys.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo ""
echo "======================================"
echo "   Parachute Agent Installer"
echo "======================================"
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_PATH="$(dirname "$SCRIPT_DIR")"

# Check if we're in the right directory
if [ ! -f "$INSTALL_PATH/server.js" ]; then
    echo -e "${RED}Error: server.js not found. Please run this script from the parachute-agent directory.${NC}"
    exit 1
fi

# Check for Node.js
if ! command -v node &> /dev/null; then
    echo -e "${RED}Error: Node.js is not installed. Please install Node.js first.${NC}"
    echo "Visit: https://nodejs.org/"
    exit 1
fi

NODE_PATH=$(which node)
NODE_BIN_DIR=$(dirname "$NODE_PATH")
NODE_VERSION=$(node --version)
echo -e "${GREEN}Found Node.js:${NC} $NODE_VERSION at $NODE_PATH"
echo -e "${GREEN}Node bin dir:${NC} $NODE_BIN_DIR"

# Check for Claude CLI
echo ""
echo "Checking Claude CLI authentication..."

# Claude CLI can be in various locations
CLAUDE_PATH=""
if command -v claude &> /dev/null; then
    CLAUDE_PATH=$(command -v claude)
elif [ -x "$HOME/.claude/local/claude" ]; then
    CLAUDE_PATH="$HOME/.claude/local/claude"
elif [ -x "/usr/local/bin/claude" ]; then
    CLAUDE_PATH="/usr/local/bin/claude"
fi

if [ -z "$CLAUDE_PATH" ]; then
    echo -e "${RED}Error: Claude CLI is not installed.${NC}"
    echo ""
    echo "Please install Claude Code first:"
    echo "  npm install -g @anthropic-ai/claude-code"
    echo ""
    echo "Then authenticate with:"
    echo "  claude login"
    exit 1
fi

# Check if Claude is working
if ! "$CLAUDE_PATH" --version &> /dev/null; then
    echo -e "${RED}Error: Claude CLI is not working properly.${NC}"
    exit 1
fi

echo -e "${GREEN}Found Claude CLI:${NC} $CLAUDE_PATH"

# Check authentication status by attempting a simple operation
# The SDK will use the stored credentials from `claude login`
echo ""
echo -e "${YELLOW}Note:${NC} This server uses Claude Agent SDK authentication."
echo "Make sure you have run 'claude login' before starting the service."
echo ""
echo "If you haven't logged in yet, press Ctrl+C and run:"
echo "  claude login"
echo ""
read -r -p "Press Enter to continue if you're already logged in..."

# Check for vault path
if [ -z "$VAULT_PATH" ]; then
    echo ""
    echo -e "${YELLOW}VAULT_PATH not set. Please enter the path to your Obsidian vault:${NC}"
    read -r VAULT_PATH
fi

# Expand ~ in path
VAULT_PATH="${VAULT_PATH/#\~/$HOME}"

if [ ! -d "$VAULT_PATH" ]; then
    echo -e "${RED}Error: Vault path does not exist: $VAULT_PATH${NC}"
    exit 1
fi

echo -e "${GREEN}Using vault:${NC} $VAULT_PATH"

# Set port
PORT="${PORT:-3333}"
echo -e "${GREEN}Using port:${NC} $PORT"

# Create logs directory
mkdir -p "$INSTALL_PATH/logs"

# Install dependencies
echo ""
echo "Installing dependencies..."
cd "$INSTALL_PATH"
npm install --production

# Create .env file if it doesn't exist
if [ ! -f "$INSTALL_PATH/.env" ]; then
    echo ""
    echo "Creating .env file..."
    cat > "$INSTALL_PATH/.env" << EOF
# Parachute Agent Configuration
# Authentication: Uses Claude Agent SDK via 'claude login' - no API keys needed!

VAULT_PATH=$VAULT_PATH
PORT=$PORT
NODE_ENV=production

# API Authentication (optional - recommended for remote access)
# When set, clients must include this in the X-API-Key header
# API_KEY=your-secret-api-key-here

# CORS Origins (comma-separated, or * for all)
# CORS_ORIGINS=http://localhost:3000,http://192.168.1.100:3000
EOF
    echo -e "${GREEN}Created .env file at $INSTALL_PATH/.env${NC}"
fi

# Create launchd plist
echo ""
echo "Setting up launchd service..."

PLIST_PATH="$HOME/Library/LaunchAgents/xyz.openparachute.agent.plist"

# Generate plist from template
sed -e "s|INSTALL_PATH|$INSTALL_PATH|g" \
    -e "s|VAULT_PATH_PLACEHOLDER|$VAULT_PATH|g" \
    -e "s|HOME_PLACEHOLDER|$HOME|g" \
    -e "s|NODE_BIN_PATH|$NODE_BIN_DIR|g" \
    -e "s|/usr/local/bin/node|$NODE_PATH|g" \
    "$SCRIPT_DIR/xyz.openparachute.agent.plist" > "$PLIST_PATH"

echo -e "${GREEN}Created launchd plist at $PLIST_PATH${NC}"

# Unload existing service if running
launchctl unload "$PLIST_PATH" 2>/dev/null || true

# Load the service
launchctl load "$PLIST_PATH"

echo ""
echo "======================================"
echo -e "${GREEN}Installation Complete!${NC}"
echo "======================================"
echo ""
echo "The Parachute Agent is now running as a background service."
echo ""
echo -e "${YELLOW}Important:${NC} Authentication is handled via 'claude login'."
echo "If the service fails to start, ensure you've run 'claude login' first."
echo ""
echo "Useful commands:"
echo "  View logs:     tail -f $INSTALL_PATH/logs/stdout.log"
echo "  Stop service:  launchctl unload $PLIST_PATH"
echo "  Start service: launchctl load $PLIST_PATH"
echo "  Check status:  curl http://localhost:$PORT/api/health"
echo ""
echo "Access the dashboard at: http://localhost:$PORT/"
echo ""

# Test if the service is running
sleep 2
if curl -s "http://localhost:$PORT/api/health" > /dev/null 2>&1; then
    echo -e "${GREEN}Service is running and healthy!${NC}"
else
    echo -e "${YELLOW}Service may still be starting. Check logs if issues persist.${NC}"
    echo ""
    echo "If you see authentication errors, run 'claude login' and restart the service."
fi
