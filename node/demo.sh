#!/bin/bash
# Agent Pilot Demo Script
# Demonstrates workflow agents processing documents

SERVER="http://localhost:3333"
VAULT="/Users/unforced/Symbols/Codes/experimenting/obsidian-agent-pilot/sample-vault"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║              Agent Pilot - Workflow Demo                       ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo

# Step 1: Show current inbox
echo "📥 STEP 1: Current Ideas Inbox"
echo "────────────────────────────────"
grep -A 10 "## Unprocessed Ideas" "$VAULT/ideas/inbox.md" | head -8
echo
read -p "Press Enter to spawn the idea-curator agent..."

# Step 2: Spawn the agent
echo
echo "🚀 STEP 2: Spawning idea-curator agent..."
echo "────────────────────────────────"
RESULT=$(curl -s -X POST "$SERVER/api/agents/spawn" \
  -H "Content-Type: application/json" \
  -d '{"agentPath": ".agents/idea-curator.md", "message": "Process all unprocessed ideas in the inbox"}')

QUEUE_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('queueId',''))")
echo "Queued with ID: $QUEUE_ID"
echo

# Step 3: Poll until complete
echo "⏳ STEP 3: Processing..."
echo "────────────────────────────────"
while true; do
  STATE=$(curl -s "$SERVER/api/queue")
  RUNNING=$(echo "$STATE" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('running',[])))")

  if [ "$RUNNING" = "0" ]; then
    echo "✅ Complete!"
    break
  fi

  echo -n "."
  sleep 3
done
echo

# Step 4: Show results
echo
echo "📊 STEP 4: Results"
echo "────────────────────────────────"
LATEST=$(curl -s "$SERVER/api/queue" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d['completed']:
    c = d['completed'][0]
    print(f\"Agent: {c['agentPath']}\")
    print(f\"Duration: {c['result']['durationMs']/1000:.1f}s\")
    print(f\"Response:\")
    print(c['result']['response'][:800])
")
echo "$LATEST"
echo

# Step 5: Show updated inbox
echo
echo "📝 STEP 5: Updated Inbox"
echo "────────────────────────────────"
head -25 "$VAULT/ideas/inbox.md"
echo

# Check for new files
echo
echo "📁 New files created:"
echo "────────────────────────────────"
find "$VAULT/ideas" -name "*.md" -mmin -2 -type f | while read f; do
  echo "  → $(basename "$f")"
done

echo
echo "Demo complete!"
