#!/bin/bash
#
# Restart the Parachute Agent server
# This properly kills any existing process and restarts the launchd service
#

set -e

PLIST="$HOME/Library/LaunchAgents/xyz.openparachute.agent.plist"

echo "Stopping Parachute Agent..."

# Unload the service first (ignore errors if not loaded)
launchctl unload "$PLIST" 2>/dev/null || true

# Kill any node processes on port 3333
lsof -ti:3333 | xargs kill -9 2>/dev/null || true

# Give it a moment
sleep 1

# Verify port is free
if lsof -i:3333 >/dev/null 2>&1; then
    echo "Error: Port 3333 still in use"
    exit 1
fi

echo "Starting Parachute Agent..."
launchctl load "$PLIST"

# Wait for server to start
sleep 2

# Check health
if curl -s http://localhost:3333/api/health | grep -q '"status":"ok"'; then
    echo "✅ Server restarted successfully"
else
    echo "❌ Server may not have started correctly"
    echo "Check logs: tail -50 $(dirname "$PLIST")/../Symbols/Codes/parachute/agent/logs/stdout.log"
    exit 1
fi
