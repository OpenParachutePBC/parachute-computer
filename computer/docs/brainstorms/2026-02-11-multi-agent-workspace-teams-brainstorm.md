# Multi-Agent Workspace Teams Brainstorm

**Date:** February 11, 2026
**Status:** Draft
**Related Systems:** Tinyclaw (Lucian's fork), Parachute Computer orchestrator

---

## What We're Building

Enable agents within a Parachute workspace to coordinate by messaging each other, creating sub-agent sessions, and working as teams to solve complex tasks. This transforms Parachute from single-agent sessions into a collaborative multi-agent system while maintaining security boundaries through workspace scoping and trust levels.

**Core Capabilities:**
1. **Inter-session messaging** - Agents send messages to other sessions via MCP tools
2. **Session creation** - Agents spawn new agent sessions (sandboxed or trusted)
3. **Workspace teams** - Agents within same workspace auto-discover and coordinate
4. **Trust level enforcement** - Sandboxed agents can only create/message other sandboxed sessions
5. **Chatbot spawning** - Agents can request creation of new chatbot instances for different channels

---

## Why This Approach

**Inspiration from Tinyclaw:**
- Tinyclaw enables distributed multi-repo coordination via cross-thread MCP tools
- Each Telegram forum topic = one agent session = one repository
- Agents use `send_message(threadId, message)` and `list_threads()` to coordinate
- Messages appear in both recipient's context AND the UI (Telegram topic)

**Parachute's Unique Constraints:**
- **Local-first** - no central coordinator, everything happens in user's vault
- **Trust boundaries** - sandbox isolation must be preserved
- **Workspace-scoped** - coordination happens within workspace, not globally
- **Mobile/desktop UI** - need to visualize multi-agent collaboration elegantly

**Why Workspace Teams over other patterns:**
- ✅ Clean separation of concerns (work projects, personal, research teams)
- ✅ Security boundary aligns with existing workspace model
- ✅ Natural UI grouping (workspace = team dashboard)
- ✅ Prevents chaos of global agent discovery
- ✅ Aligns with future autonomous execution (workspace = execution context)

---

## Key Design Decisions

### 1. Message Flow Architecture

**Decision:** Async fire-and-forget messaging with optional response polling

**How it works:**
- Agent A calls `send_to_session(session_id, message)`
- Message written to SQLite `inter_session_messages` table
- Agent B's next streaming turn polls for pending messages
- Agent B processes message as new user input
- Agent B's response appears in its own session (visible to user in UI)
- Agent A can poll Agent B's session for responses via `get_session_messages(session_id, since=timestamp)`

**Why not synchronous?**
- Avoids deadlocks (Agent A waiting for Agent B while Agent B waits for Agent A)
- Allows agent collaboration without blocking user sessions
- Simpler implementation (no WebSocket/SSE between sessions)

**Trade-off:** Agents must explicitly poll for responses, adds latency

---

### 2. Trust Level Permissions

**Decision:** Sandboxed agents can ONLY create and message other sandboxed sessions in same workspace

**Rules:**
- ✅ Sandbox → Sandbox (same workspace): automatic
- ❌ Sandbox → Trusted: blocked
- ❌ Sandbox → different workspace: blocked
- ✅ Trusted → Trusted (same workspace): automatic
- ✅ Trusted → Sandbox (same workspace): automatic
- ⚠️ Trusted → different workspace: requires user permission

**Why these boundaries?**
- Sandbox agents can't escalate privileges by messaging trusted agents
- Workspace isolation prevents cross-contamination
- Trusted agents have flexibility for legitimate cross-workspace coordination
- Aligns with existing Docker sandbox model

**Implementation:** Check in orchestrator before delivering inter-session messages

---

### 3. Session Creation Permissions

**Decision:** Agents can create sessions at their trust level or lower, within their workspace

**Flow:**
1. Agent calls `create_agent_session(agent_name, initial_message, trust_level?)`
2. Orchestrator validates:
   - Caller is sandbox → can only create sandbox sessions
   - Caller is trusted → can create sandbox or trusted (defaults to sandbox)
   - New session inherits caller's workspace
3. New session ID returned to caller
4. New session appears in UI under workspace sessions

**Why default to sandbox?**
- Principle of least privilege
- Prevents accidental privilege escalation
- Trusted agents can explicitly request trusted sub-sessions if needed

**Special case - Chatbot spawning:**
- Chatbot sessions are always sandboxed (they talk to external users)
- Spawning new chatbot = creating new session + registering bot connector
- Example: Discord bot in #general wants to also join #dev-chat
  - Calls `create_chatbot_session("discord", channel_id="#dev-chat")`
  - Returns new session_id
  - Bot connector auto-registers and starts listening

---

### 4. MCP Tools API

**New tools added to workspace-enabled sessions:**

```typescript
// Discover available sessions in current workspace
list_workspace_sessions(): SessionInfo[]

// Send message to another session (async)
send_to_session(session_id: string, message: string): { status: "delivered" | "blocked" }

// Poll for responses from another session
get_session_messages(session_id: string, since?: timestamp): Message[]

// Create new agent session
create_agent_session(
  agent_name: string,
  initial_message: string,
  trust_level?: "sandbox" | "trusted"
): { session_id: string }

// Special chatbot variant
create_chatbot_session(
  platform: "telegram" | "discord",
  channel_id: string
): { session_id: string, bot_invite_url?: string }
```

**Tool availability:**
- Only available when session has a workspace assigned
- Filtered by trust level (sandboxed sessions don't see trusted-only tools)
- Exposed via orchestrator's MCP discovery (same as existing MCP servers)

---

### 5. UI Visualization

**Workspace Dashboard View:**
```
Workspace: Product Launch

Active Agents:
┌─ Research Agent (session_abc)     [Sandbox]  ● 3 messages pending
├─ Writer Agent (session_def)       [Sandbox]  ● Active
├─ Code Review Agent (session_ghi)  [Trusted]  ○ Idle
└─ Discord Bot - #announcements     [Sandbox]  ● Active

Recent Coordination:
• Research → Writer: "Found 3 competitor examples"
• Writer → Code Review: "Draft ready for review"
• Discord Bot spawned #product-chat instance
```

**Session Detail View:**
- Show inbound/outbound agent messages with special styling
- Distinguish user messages from inter-agent messages
- Link to related sessions (click to jump)

**Implementation:**
- Mobile: Workspace tab with agent grid + activity feed
- Desktop: Sidebar shows workspace sessions, main pane shows selected session

---

## Open Questions

### Technical

1. **Message queue cleanup:** How long do we keep inter-session messages? Forever? Expire after 7 days?
   - Proposal: Keep until recipient session processes them, then archive to session transcript

2. **Circular messaging detection:** What if Agent A → Agent B → Agent A in a loop?
   - Proposal: Track message ancestry, block if depth > 5 hops
   - Alternative: Time-based rate limiting (max 10 inter-agent messages per minute)

3. **Session discovery scope:** Should agents see ALL workspace sessions or only active ones?
   - Proposal: Only show sessions active in last 24h to reduce noise

4. **Cost attribution:** When Agent A spawns Agent B, who pays for Agent B's tokens?
   - Proposal: All costs attributed to root user session that triggered the chain
   - Need workspace-level cost dashboard to track this

### UX

5. **User visibility:** Should users be notified when agents message each other?
   - Proposal: Show in activity feed but don't interrupt
   - Alternative: Only notify if agent requests user input via `AskUserQuestion`

6. **Manual intervention:** How do users stop runaway agent teams?
   - Proposal: Workspace-level "Pause all agents" button
   - Emergency stop kills all sessions in workspace

7. **Agent naming:** How do we help users understand which agent is which in the team?
   - Proposal: Custom display names per session (Research Agent, not session_abc123)
   - Agents can set their own display name via metadata

### Security

8. **Workspace escape:** Could malicious agent trick another into creating cross-workspace session?
   - Mitigation: All session creation enforces workspace inheritance from caller
   - Trust level checks happen in orchestrator (agent can't override)

9. **Resource exhaustion:** Agent spawns 100 sub-agents to DDoS itself?
   - Proposal: Max 10 active sessions per workspace
   - Max 3 session creations per parent session

10. **External chatbot abuse:** Rogue agent spawns chatbot that spams Discord?
    - Proposal: Chatbot creation requires user approval (via `AskUserQuestion`)
    - Rate limiting on chatbot message sending (external to this brainstorm)

---

## Success Criteria

**MVP (Minimum Viable Product):**
- ✅ Agents can message other agents in same workspace
- ✅ Sandboxed agents can create sandboxed sub-sessions
- ✅ Messages appear in recipient session transcript
- ✅ Basic UI shows workspace sessions + inter-agent messages
- ✅ Trust level enforcement works

**V1 (Full Featured):**
- ✅ All MVP criteria
- ✅ Chatbot spawning support (Discord, Telegram)
- ✅ Workspace dashboard with agent activity feed
- ✅ Cost attribution and workspace-level analytics
- ✅ Circular messaging detection
- ✅ Resource limits (max sessions, rate limiting)

**Success Metrics:**
- Users create multi-agent workflows (evidence: >1 session per workspace on average)
- Agents successfully coordinate without user intervention (measure: inter-agent messages sent)
- No security incidents (sandbox escapes, privilege escalation)
- Performance remains acceptable (latency <500ms for message delivery)

---

## Implementation Notes

**Database Schema Changes:**
```sql
-- New table for inter-session messages
CREATE TABLE inter_session_messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_session_id TEXT NOT NULL,
  to_session_id TEXT NOT NULL,
  message TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  processed_at TIMESTAMP NULL,
  workspace_id TEXT NOT NULL,

  FOREIGN KEY (from_session_id) REFERENCES sessions(id),
  FOREIGN KEY (to_session_id) REFERENCES sessions(id)
);

CREATE INDEX idx_inter_session_to ON inter_session_messages(to_session_id, processed_at);
```

**Orchestrator Changes:**
1. Add `_poll_inter_session_messages(session_id)` called before streaming
2. Add `_validate_session_creation(caller_session, target_trust_level)`
3. Add `_deliver_inter_session_message(from, to, message)` with trust checks
4. Expose new MCP tools via `_discover_capabilities()`

**API Endpoints (new):**
```python
# In chat module or new workspace module
POST /api/workspace/{workspace_id}/sessions  # Create session
GET  /api/workspace/{workspace_id}/sessions  # List sessions
POST /api/session/{session_id}/messages      # Send inter-session message
GET  /api/session/{session_id}/messages      # Get messages (for polling)
```

**UI Components:**
- `WorkspaceDashboard.dart` - Grid of active sessions
- `AgentActivityFeed.dart` - Real-time inter-agent messages
- `SessionGraph.dart` - Visual graph of agent coordination

---

## Related Work

**Tinyclaw References:**
- Cross-thread messaging: `send_message(threadId, message)` MCP tool
- Session discovery: `list_threads()` MCP tool
- Master thread pattern: elevated visibility across all threads
- File-based queue: atomic writes, dead-letter queue for failures

**Parachute Existing Patterns:**
- Custom agents: `vault/.parachute/agents/*.yaml`
- Task tool: Spawns subagents but no inter-agent messaging
- Workspace model: Isolated working directories
- Trust levels: Sandbox (Docker) vs Trusted (bare metal)
- Session manager: SQLite metadata + Claude SDK JSONL transcripts

**Future Considerations:**
- Autonomous execution: Heartbeat loops that trigger agent teams
- Cost optimization: Route different agents to different models (Haiku for simple tasks)
- Real-time dashboard: Live view of agent coordination for debugging

---

## Next Steps

1. **Validate with users:** Does "workspace teams" mental model make sense?
2. **Prototype inter-session messaging:** Simplest possible implementation (no UI)
3. **Design workspace dashboard UI:** Mockups for mobile + desktop
4. **Implement trust level checks:** Extend orchestrator validation
5. **Build MCP tools:** Expose in existing MCP discovery flow
6. **Add database migration:** `inter_session_messages` table
7. **Test security boundaries:** Sandbox escape attempts, privilege escalation
8. **Ship MVP:** Basic messaging + session creation
9. **Iterate on UX:** Activity feed, cost attribution, resource limits

---

**Document Version:** 1.0
**Last Updated:** February 11, 2026
**Next Review:** After user validation & technical feasibility assessment
