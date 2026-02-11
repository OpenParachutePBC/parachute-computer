# Intelligent Cost Optimization Brainstorm

**Date:** February 11, 2026
**Status:** Draft
**Related Systems:** Tinyclaw ClawRouter, Parachute Computer orchestrator

---

## What We're Building

Automatic model routing that evaluates incoming messages and selects the optimal Claude model (Haiku, Sonnet, Opus) based on complexity. This reduces API costs by ~70% while maintaining quality, with per-workspace controls to enable/disable optimization.

**Core Capabilities:**
1. **14-dimension scoring** - Analyze message complexity in <1ms locally
2. **Automatic routing** - Route simple queries to Haiku, complex to Opus
3. **Upgrade-only policy** - Agents can request better models but not downgrade
4. **Workspace controls** - Enable/disable routing per workspace or session
5. **Cost transparency** - Dashboard showing savings and routing decisions

---

## Why This Approach

**Inspiration from Tinyclaw:**
- Tinyclaw's ClawRouter saves ~70% on API costs across distributed team workflows
- Evaluates 14 dimensions: code presence, reasoning markers, token count, technical density, multi-step patterns, etc.
- Executes in <1ms with zero API overhead (local heuristics, no LLM calls)
- Allows model upgrades during conversation (Haiku→Sonnet) but prevents downgrades (preserves context quality)
- MIT licensed, battle-tested in production

**Parachute's Unique Considerations:**
- **Single-user context** - Personal use means lower absolute costs than multi-repo teams
- **Long conversations** - Users value quality over cost in extended sessions
- **Mobile experience** - Latency matters, can't afford slow routing
- **Trust in defaults** - Users expect "it just works" without configuration

**Why auto-routing vs manual selection:**
- ✅ Reduces cognitive load (users don't think about model choice)
- ✅ Optimizes cost without sacrificing quality (smart heuristics)
- ✅ Works behind the scenes (no UX changes for most users)
- ✅ Pays for itself quickly (even single users save on API costs)
- ⚠️ Trade-off: Less explicit control, but workspace override available

---

## Key Design Decisions

### 1. Routing Algorithm

**Decision:** Use Tinyclaw's 14-dimension scoring system with Parachute-specific tuning

**How it works:**
```typescript
// Evaluate message on 14 weighted dimensions
const score = evaluate({
  codePresence: hasCodeBlocks(message),
  reasoningMarkers: countPatterns(message, ["because", "therefore", "thus"]),
  tokenCount: estimateTokens(message),
  technicalTerms: countTechnicalVocab(message),
  multiStepPatterns: detectSequences(message),
  questionComplexity: analyzeQuestionStructure(message),
  priorContext: getConversationLength(session),
  attachments: countAttachments(message),
  // ... 6 more dimensions
});

// Route based on score thresholds
if (score < 30) return "haiku";        // Simple queries, status checks
if (score < 70) return "sonnet";       // Moderate analysis, code review
return "opus";                          // Complex reasoning, architecture
```

**Dimensions (14 total):**
1. Code block presence (boolean × weight)
2. Reasoning markers ("because", "therefore", "however")
3. Token count (longer = more complex)
4. Technical terminology density
5. Multi-step patterns ("first... then... finally")
6. Question complexity (single vs compound questions)
7. Prior conversation length (deep context = upgrade to Opus)
8. Attachment count (images, PDFs increase complexity)
9. Uncertainty markers ("maybe", "possibly")
10. Imperative vs interrogative (commands vs questions)
11. Domain-specific keywords (legal, medical, code = higher weight)
12. Comparative analysis ("compare X and Y")
13. Temporal references ("previous message", "earlier you said")
14. Negation complexity ("not X but Y")

**Why 14 dimensions vs simpler heuristics?**
- Catches edge cases (short message with complex code)
- Validated by Tinyclaw's production usage
- Fast enough (<1ms) to not add latency
- Weighted scoring allows tuning per dimension

---

### 2. Workspace-Level Controls

**Decision:** Routing is opt-in per workspace with granular override options

**Configuration levels:**
```yaml
# Workspace settings (vault/.parachute/workspaces/{workspace_id}/config.yaml)
cost_optimization:
  enabled: true               # Master toggle
  routing_mode: "auto"        # "auto" | "always_haiku" | "always_sonnet" | "always_opus"
  upgrade_allowed: true       # Can agents request better models mid-conversation?
  minimum_model: "haiku"      # Floor (never route below this)
  maximum_model: "opus"       # Ceiling (never route above this)
```

**Session-level override:**
- User can force specific model for current session: "Use Opus for this conversation"
- Persisted in session metadata, overrides workspace settings
- Shows indicator in UI: "🔒 Fixed to Opus"

**Why opt-in vs opt-out?**
- Parachute users value quality first, cost second (personal use)
- Avoids surprising users with model switches
- Power users can enable globally, casual users never see it
- Safer rollout strategy (ship disabled by default, enable per workspace)

**Alternative approach (considered but rejected):**
- Global default "on" - Too aggressive, might degrade UX for users who don't care about cost
- Per-session toggle - Too much friction, users won't engage
- Automatic after N sessions - Confusing, inconsistent behavior

---

### 3. Model Upgrade Policy

**Decision:** Allow agents to upgrade models mid-conversation, never downgrade

**Example flow:**
```
User: "Quick question: is the server running?"
Router: → Haiku (simple query, score=15)

User: "Analyze the architecture and suggest refactoring approaches"
Router: → Opus (complex reasoning, score=85)

Agent (Opus): "I recommend three approaches... [detailed analysis]"

User: "Thanks! What's the status of PR #42?"
Router: → Opus (preserve context quality, don't downgrade)
```

**Why upgrade-only?**
- Prevents quality degradation mid-conversation
- Avoids confusion (Opus → Haiku might drop context nuance)
- Aligns with Tinyclaw's proven approach
- Simple to implement (track session's "highest model used")

**Downgrade triggers (rejected):**
- Time-based: After 5 minutes of no activity, reset to Haiku
  - ❌ Breaks conversation continuity
- Explicit user request: "Switch back to Haiku"
  - ✅ Could support this as manual override
- Cost threshold: After $5 spent, force Haiku
  - ❌ Too complex, users lose control

---

### 4. Cost Transparency

**Decision:** Show routing decisions + savings in workspace dashboard

**UI Components:**

**1. Routing Indicator (per message):**
```
┌─ Message                                    [Haiku] ──┐
│ User: Quick status check?                           │
│ Parachute: Server is running ✓                      │
│ Cost: $0.0001 (routed to Haiku, saved $0.002)       │
└──────────────────────────────────────────────────────┘
```

**2. Workspace Dashboard:**
```
💰 Cost Optimization (Last 30 days)

Routing Summary:
• 45 messages to Haiku   ($0.12)
• 23 messages to Sonnet  ($1.43)
• 8 messages to Opus     ($2.10)

Savings: $4.35 (67% reduction)
Without routing: $6.80
Actual spend: $2.45

Top Routed Conversations:
1. "Code review workflow" - 12 messages, saved $1.20
2. "Quick daily standup" - 8 messages, saved $0.80
```

**3. Developer Debug View (optional):**
```
Routing Decision for message #42:
• Code presence: 8/10
• Token count: 156 (score: 5/10)
• Reasoning markers: 3 (score: 6/10)
• Technical terms: 12 (score: 7/10)
• ... [show all 14 dimensions]
• Total score: 72/100 → Sonnet
```

**Why show routing decisions?**
- Builds trust in the system (users see it working)
- Educational (users learn which queries are "expensive")
- Debugging (if routing seems wrong, users can report)
- Gamification (users optimize their prompts to save costs)

---

### 5. Integration Points

**Decision:** Hook into orchestrator before Claude SDK call, minimal disruption

**Orchestrator flow changes:**
```python
# parachute/core/orchestrator.py

async def stream_agent_response(session_id, message):
    # 1. Load session metadata
    session = await session_manager.get_session(session_id)

    # 2. Check workspace routing settings
    workspace = session.workspace_id
    routing_config = load_workspace_routing_config(workspace)

    # 3. Determine model (NEW)
    if routing_config.enabled and not session.model_override:
        model = await router.evaluate_and_route(
            message=message,
            session_context=session.transcript,
            current_model=session.current_model,
            constraints={
                "minimum": routing_config.minimum_model,
                "maximum": routing_config.maximum_model,
                "upgrade_allowed": routing_config.upgrade_allowed,
            }
        )
        # Log routing decision
        await session_manager.record_routing_decision(session_id, model, router.last_score)
    else:
        # Use workspace default or session override
        model = session.model_override or workspace.default_model

    # 4. Call Claude SDK with selected model (existing code)
    async for event in claude_sdk.stream(session_id, message, model=model):
        yield event
```

**New module:** `parachute/core/router.py`
- `evaluate_and_route(message, context, current_model, constraints)` → model name
- `calculate_complexity_score(message)` → 0-100
- `load_routing_config(workspace_id)` → RoutingConfig object

**Database schema changes:**
```sql
-- Add routing metadata to sessions table
ALTER TABLE sessions ADD COLUMN current_model TEXT;
ALTER TABLE sessions ADD COLUMN model_override TEXT NULL;

-- Track routing decisions for analytics
CREATE TABLE routing_decisions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  selected_model TEXT NOT NULL,
  complexity_score INTEGER NOT NULL,
  would_have_used TEXT NOT NULL,  -- Model without routing
  estimated_savings REAL NOT NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

  FOREIGN KEY (session_id) REFERENCES sessions(id)
);

CREATE INDEX idx_routing_workspace ON routing_decisions(session_id, created_at);
```

---

## Open Questions

### Technical

1. **Tinyclaw code integration:** Should we fork ClawRouter or reimplement in Python?
   - Proposal: Reimplement in Python (avoid TypeScript dependency, simpler)
   - Tinyclaw is MIT licensed, we can use the algorithm

2. **Score tuning:** Do we use Tinyclaw's exact weights or tune for Parachute usage?
   - Proposal: Start with Tinyclaw's weights, collect data, tune over time
   - Add `parachute doctor routing-stats` to analyze routing accuracy

3. **Caching:** Should we cache routing decisions for similar messages?
   - Proposal: No caching initially (adds complexity, <1ms is fast enough)
   - Revisit if routing becomes bottleneck (unlikely)

4. **Model availability:** What if Haiku is unavailable (rate limit, outage)?
   - Proposal: Fallback chain: Haiku → Sonnet → Opus
   - Show warning in UI: "⚠️ Haiku unavailable, using Sonnet"

### UX

5. **User education:** How do we explain routing to non-technical users?
   - Proposal: Simple tooltip: "💡 Automatically using faster models for simple questions"
   - Link to docs: "Learn more about cost optimization"

6. **Notification frequency:** Should we notify on every routing decision?
   - Proposal: Only show in message metadata (hover/tap to see)
   - Summary notification at end of session: "Saved $0.50 this conversation"

7. **Manual override friction:** How easy should it be to force a specific model?
   - Proposal: Chat command: "/use opus" or "/use sonnet"
   - Persists for current session only
   - Mobile: Quick action in session settings

### Business

8. **Cost attribution:** Who benefits from savings - user or Parachute?
   - Proposal: User keeps all savings (builds goodwill)
   - Alternative: Parachute takes 20% (helps fund development)
   - Decision: User keeps 100% (we're not an API reseller)

9. **Free tier impact:** Does this reduce revenue for Anthropic?
   - Answer: Unlikely - Parachute users pay Anthropic directly via Claude Code
   - Routing optimizes user's bill, doesn't affect Anthropic relationship

10. **Enterprise use case:** Would businesses want different routing rules?
    - Potential: Company-wide policies (e.g., "always use Sonnet for code review")
    - Not in scope for MVP, but architecture should allow it

---

## Success Criteria

**MVP (Minimum Viable Product):**
- ✅ Router evaluates messages in <1ms
- ✅ Routing decision hooks into orchestrator before SDK call
- ✅ Workspace-level enable/disable toggle
- ✅ Session-level model override works
- ✅ Basic cost savings tracking (total saved, model distribution)

**V1 (Full Featured):**
- ✅ All MVP criteria
- ✅ Upgrade-only policy enforced
- ✅ Workspace dashboard with 30-day analytics
- ✅ Per-message routing indicator (show/hide toggle)
- ✅ Chat commands for manual override (/use opus)
- ✅ Routing debug view for developers
- ✅ Tuned scoring weights for Parachute usage patterns

**Success Metrics:**
- **Adoption:** 30% of workspaces enable cost optimization within 90 days
- **Savings:** Average user saves 50-70% on API costs (measured via routing_decisions table)
- **Quality:** No increase in "regenerate" or "use better model" requests (proxy for quality degradation)
- **Performance:** p95 routing latency <2ms (doesn't add user-visible delay)

---

## Implementation Notes

**Phase 1: Router Core (Week 1)**
```python
# parachute/core/router.py

class CostOptimizationRouter:
    """
    Evaluates message complexity and routes to optimal model.
    Based on Tinyclaw's ClawRouter (MIT license).
    """

    COMPLEXITY_WEIGHTS = {
        "code_presence": 10,
        "reasoning_markers": 8,
        "token_count": 6,
        # ... 11 more dimensions
    }

    THRESHOLDS = {
        "haiku": 30,    # 0-29 → Haiku
        "sonnet": 70,   # 30-69 → Sonnet
        # 70-100 → Opus
    }

    def evaluate_and_route(
        self,
        message: str,
        session_context: list[dict],
        current_model: str | None,
        constraints: RoutingConstraints,
    ) -> str:
        # Calculate complexity score
        score = self._calculate_score(message, session_context)

        # Apply constraints (min/max model)
        model = self._score_to_model(score)
        model = self._apply_constraints(model, current_model, constraints)

        # Store for analytics
        self.last_score = score
        self.last_model = model

        return model

    def _calculate_score(self, message: str, context: list) -> int:
        """Calculate 0-100 complexity score based on 14 dimensions."""
        # Implementation details...
        pass
```

**Phase 2: Orchestrator Integration (Week 1-2)**
- Add routing hook in `stream_agent_response()`
- Load workspace routing config
- Record routing decisions to database
- Handle model override logic

**Phase 3: UI Components (Week 2-3)**
- Workspace settings toggle for cost optimization
- Session model override control
- Cost savings dashboard (mobile + desktop)
- Per-message routing indicator

**Phase 4: Analytics & Tuning (Week 3-4)**
- Collect routing decision data for 2 weeks
- Analyze accuracy (did Haiku handle "simple" queries well?)
- Tune COMPLEXITY_WEIGHTS based on real usage
- Add `parachute doctor routing-stats` command

**API Endpoints (new):**
```python
# In workspace module or new cost_optimization module
GET  /api/workspace/{id}/routing-config
PUT  /api/workspace/{id}/routing-config
GET  /api/workspace/{id}/routing-analytics?days=30
GET  /api/session/{id}/routing-decisions
POST /api/session/{id}/override-model  # Manual override
```

**Configuration Schema:**
```yaml
# vault/.parachute/workspaces/{workspace_id}/config.yaml

cost_optimization:
  enabled: false              # Default: off (opt-in)
  routing_mode: "auto"        # "auto" | "always_haiku" | "always_sonnet" | "always_opus"
  upgrade_allowed: true       # Allow mid-conversation upgrades
  minimum_model: "haiku"      # Never route below this
  maximum_model: "opus"       # Never route above this
  notify_on_routing: false    # Show routing notifications (default: silent)
```

---

## Related Work

**Tinyclaw ClawRouter:**
- 14-dimension complexity scoring
- <1ms evaluation time
- Upgrade-only policy (Haiku→Sonnet→Opus)
- MIT licensed, production-validated
- GitHub: `BlockRunAI/ClawRouter`

**Parachute Existing Patterns:**
- Model selection: `default_model` in workspace config
- Orchestrator: Centralized agent execution control
- Workspace model: Isolated working directories with per-workspace settings
- Session metadata: SQLite storage for session state

**Industry Benchmarks:**
- Anthropic pricing (Feb 2026):
  - Haiku: $0.25/1M input, $1.25/1M output
  - Sonnet: $3/1M input, $15/1M output
  - Opus: $15/1M input, $75/1M output
- Average savings with smart routing: 60-75% (based on Tinyclaw data)

**Future Considerations:**
- Multi-agent coordination: Route different agents to different models (Research→Haiku, Analysis→Opus)
- Adaptive routing: Learn user's quality preferences over time (ML-based tuning)
- Cost budgets: "Spend max $10/month, then downgrade to Haiku-only"

---

## Next Steps

1. **Validate business case:** Survey users on cost sensitivity (is 70% savings compelling?)
2. **Prototype router:** Implement 14-dimension scoring in Python, benchmark performance
3. **A/B test routing:** Enable for internal team, measure quality impact
4. **Design UI mockups:** Workspace settings toggle + cost dashboard
5. **Implement orchestrator hook:** Add routing logic before SDK call
6. **Ship MVP:** Opt-in per workspace, basic analytics
7. **Collect data:** Monitor routing decisions for 30 days
8. **Tune weights:** Adjust COMPLEXITY_WEIGHTS based on real usage
9. **Launch V1:** Full dashboard, chat commands, model override UI

---

**Document Version:** 1.0
**Last Updated:** February 11, 2026
**Next Review:** After prototype performance validation
