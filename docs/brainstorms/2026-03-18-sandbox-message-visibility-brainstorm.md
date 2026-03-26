# Sandbox Message Visibility — Kill the Synthetic Mirror

**Status:** brainstorm
**Priority:** P1
**Labels:** chat, computer, bug
**Issue:** #287

## What We're Building

Fix dropped messages in sandboxed chats by reading transcripts from the container's actual JSONL (which persists via bind mount) instead of a synthetic mirror that only writes on the `"done"` event.

## The Problem

In sandboxed chats, messages frequently appear to be "dropped." The user sends a message, the AI thinks and works, but when returning to the chat the response isn't visible. However, the AI clearly has context — it can recall its own prior response if asked. This is persistent across app restarts.

### Root Cause

There are **two copies** of every sandboxed session transcript:

| Copy | Path | Written by | When |
|------|------|-----------|------|
| **Container (real)** | `vault/.parachute/sandbox/envs/<slug>/home/.claude/projects/...` | SDK inside Docker, incrementally | As events occur |
| **Host (synthetic mirror)** | `~/.claude/projects/{encoded-cwd}/{session_id}.jsonl` | `write_sandbox_transcript()` | Only on `"done"` event |

The message loading code (`load_sdk_messages_by_id()`) reads from `~/.claude/projects/` — the synthetic mirror path. But the mirror is only written when the stream completes with a `"done"` event. If the SSE stream drops before that (which #283 showed happens frequently), the mirror is never written.

Meanwhile, the container's own JSONL is fine — the SDK writes incrementally, and the bind mount (`vault/.parachute/sandbox/envs/<slug>/home/` → `/home/sandbox/`) persists it to the host filesystem automatically.

### Why the AI Still Has Context

When the user sends a follow-up message, the container resumes from its own JSONL (inside the bind mount). The SDK finds its transcript at `/home/sandbox/.claude/projects/...` and picks up where it left off. The data is there — it's just that nobody's reading it for the UI.

## Why This Approach

**Kill the synthetic mirror entirely.** Read from the container's actual JSONL instead.

Reasons:
- **One source of truth** — Two copies that drift is worse than one canonical copy
- **Already persistent** — The bind mount makes the container JSONL durable. It survives container restarts, Docker rebuilds, and vault migrations
- **Incrementally written** — No dependency on a terminal `"done"` event
- **Richer data** — Real SDK JSONL has full event history (thinking, tool use, results), not a reconstruction

### What Changes

1. **`load_sdk_messages_by_id()`** — For sandboxed sessions, resolve the container slug from the session record, then read from `vault/.parachute/sandbox/envs/<slug>/home/.claude/projects/{encoded-cwd}/{session_id}.jsonl`
2. **`get_session_transcript()`** — Same path resolution for full transcript viewer
3. **`write_sandbox_transcript()`** — Remove entirely (or demote to debug logging)
4. **History injection on retry** — Already reads via `_load_sdk_messages()`, so it inherits the fix

### Edge Cases to Handle

- **Container deleted** — If the env was pruned, the bind mount directory may still exist (Docker doesn't delete mount sources). If it's truly gone, messages are lost — but that's the same as today.
- **Session without container_id** — Legacy sessions created before container tracking. Fall back to the old `~/.claude/projects/` path for these.
- **Path discovery** — The container SDK encodes its CWD (e.g., `/home/sandbox` → `-home-sandbox`). We need to know or discover this encoding to find the right JSONL.

## Key Decisions

- **Kill the synthetic mirror** — Don't maintain two copies. One source of truth.
- **Container JSONL is the primary read path** — It's already there, already incremental, already the real data.
- **Graceful fallback for legacy** — Old sessions without container_id still read from `~/.claude/projects/`.

## Open Questions

- Should we proactively verify the container JSONL exists when loading a session, and surface a clear error if not?
- Any concern about reading JSONL that the SDK might be actively writing to? (Probably fine — JSONL is append-only and line-delimited.)
- Do we need to handle the encoded CWD difference? Container sees `/home/sandbox`, host transcript was encoded from the effective working directory. Need to confirm these align.
