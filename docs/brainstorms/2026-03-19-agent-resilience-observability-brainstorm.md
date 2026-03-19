# Agent Resilience & Observability

**Status:** Brainstorm
**Priority:** P1
**Labels:** daily, computer, app
**Issue:** #296
**Related:** #280 (Agent Primitive), #264 (Container Primitive)

---

## What We're Building

Three connected improvements to make agents reliable, debuggable, and properly integrated with the container system:

1. **Fix the silent failure** — Agent sandbox runs pass a slug-format session ID (`agent-daily-reflection`) where the Claude CLI requires a UUID, causing every scheduled run to fail silently. Separate session IDs (per-run, UUID) from container slugs (persistent, human-readable).

2. **Agent run history with logs** — Every agent run (success or failure) is recorded with its log trail. When a scheduled agent fails at 4 AM, you see the failure in the app and can tap it to read exactly what went wrong — the same place you'd see the agent's thinking and tool use on a successful run.

3. **Agent → Container routing** — Agents use the same container primitive as chats. An agent can run in its own dedicated container (default) or in a named container you've set up — so a daily agent can operate inside your LVB workspace where the right tools and project context already live.

## Why This Approach

**The daily reflection agent has been silently broken since launch.** The error was hard to find because: (a) daemon log directory exists but is empty, (b) the sandbox error message is generic ("Command failed with exit code 1"), (c) there's no UI or notification for scheduled agent failures, (d) you have to manually trigger via curl to reproduce. The actual error — "Invalid session ID. Must be a valid UUID" — was only visible by exec-ing into the Docker container and running the entrypoint manually.

**This points to a structural gap, not just a bug.** The system has good in-memory logging (1000-entry LogBuffer), good interactive error handling (AgentTriggerCard shows errors for manual runs), and good container plumbing. But scheduled/background agent runs bypass all of that. The logs are trapped, the errors are swallowed, and the UI only shows "hasn't run yet" — which looks identical to "tried and failed every day."

**Agents and containers are already connected — just badly.** The sandbox code auto-creates a container record in `_run_sandboxed()`, uses the agent slug as both session ID and container slug, and gives the agent no way to target an existing container. Making this explicit (agents have a container field, like chats) is the natural integration point from brainstorms #264 and #280.

## Key Decisions

### 1. Session ID ≠ Container Slug

The immediate bug fix and the conceptual cleanup:

- **Container slug**: `agent-daily-reflection` — persistent, human-readable, identifies the environment
- **Session ID**: UUID — per-run, identifies the SDK transcript
- **The entrypoint** should generate a UUID for `--session-id` when no resume ID is provided, not reuse the slug

This matches how chats already work: the container has a slug, each conversation turn gets a UUID session.

### 2. Agent runs are logged as graph nodes

Every agent invocation — scheduled, triggered, or manual — creates a run record:

- **Agent name**, **date**, **trigger type** (scheduled/event/manual)
- **Status**: running → completed | failed | timeout
- **Container slug**: which environment it ran in
- **SDK session ID**: the transcript ID for this run
- **Error message**: if failed, the actual error text (not "Command failed with exit code 1")
- **Duration**: how long it ran
- **Output**: whether it wrote a card, and which card ID

This is the `AgentRun` node type already mentioned in the agent primitive brainstorm (#280). It just needs to actually capture useful error information instead of silently swallowing it.

### 3. Error messages propagate fully

The current error chain loses information at each layer:

```
CLI: "Invalid session ID. Must be a valid UUID"
  → SDK ProcessError: "Command failed with exit code 1"
    → entrypoint.py: "Sandbox SDK error: Command failed with exit code 1"
      → _run_sandboxed: "Agent 'daily-reflection' sandbox error: ..."
        → UI: (nothing — scheduled run, no listener)
```

Fix: the entrypoint should capture stderr from the CLI process and include it in the error event. The `_stream_process` method already reads stderr on non-zero exit — the issue is that the SDK's ProcessError wraps the CLI error with a generic message before the entrypoint can read stderr directly.

### 4. Failed runs are visible in the app

When you open Daily and the reflection card shows "Generate" (because no output was written), there should be a way to know it *tried* and failed:

- The agent trigger card checks for recent failed runs
- Failed state shows the error message inline with a "View Log" button
- "View Log" opens the same log/thinking view used for successful runs, but with the error context
- This reuses the existing card detail / agent activity UI — not a separate error screen

### 5. Agents have a configurable container

Agent config gains a `container_slug` field:

- **Default**: `null` → system creates a dedicated `agent-{name}` container (current behavior, but now explicit)
- **Named container**: `"lvb-workspace"` → agent runs in that existing container, sharing its tools, installed packages, and project context
- **UI**: Container picker in agent edit screen, showing named containers from the containers list
- **Validation**: Container must exist and be compatible (Docker available, not deleted)

This answers open question #5 from the agent primitive brainstorm and implements "Caller → Container routing" from the container primitive brainstorm.

### 6. Daemon logs actually work

The immediate operational fix: the launchd plist routes stdout/stderr to `~/Library/Logs/Parachute/` but those files are empty or missing. This needs to work so that `parachute logs` (and manual inspection) show server output. The in-memory LogBuffer is good for API access, but disk logs are the safety net when the server crashes.

## Open Questions

1. **Run log retention**: How many agent runs do we keep? All of them (graph nodes are cheap)? Or prune after N days? Leaning toward keeping all — they're small and useful for debugging patterns.

2. **Log detail level**: Should agent run logs capture the full SDK event stream (thinking, tool use, tool results) or just the final status + error? The full stream is more useful but larger. Could store a summary on the run node and link to the SDK transcript for full detail.

3. **Notification on failure**: This brainstorm focuses on passive visibility (you see it when you open the app). Active notification (push notification, badge) is a separate concern — worth doing but not blocking this work. See #272 for agent completion notifications.

4. **Container sharing concurrency**: If two things try to use the same container simultaneously (a chat and a scheduled agent, or two triggered agents), what happens? The sandbox already has `_slug_locks` for container-level locking. Probably fine for single-user, but worth noting.

## What This Unlocks

- **Agents that actually work** — the daily reflection agent will run successfully once the UUID fix lands
- **Debuggable failures** — next time something breaks, you see it in the app instead of discovering it weeks later
- **Agents in project contexts** — a code review agent running in your project workspace, a research agent running in a container with browser tools installed
- **Honest system state** — "hasn't run" vs "tried and failed" vs "succeeded" are distinguishable states
- **Foundation for agent notifications** — run history is the prerequisite for knowing *when* tonotify
