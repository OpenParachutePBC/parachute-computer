# AskUserQuestion Lost When Switching Sessions

**Type:** Bug
**Component:** app (chat UI)
**Priority:** P2
**Affects:** User experience, question-based workflows

---

## Problem

When Claude asks a question via AskUserQuestion during a chat, the question UI disappears if the user switches to a different session and then returns. The user sees only the raw JSON tool call in the transcript and must manually parse it to understand what was asked.

**Current behavior:**
1. Agent calls AskUserQuestion → UI shows UserQuestionCard
2. User switches to different chat session
3. User returns to original session
4. **Question UI is gone** - only raw tool call visible

**Expected behavior:**
- Question should persist and remain visible when returning to the session
- User should see the interactive question card, not raw JSON

---

## Root Cause

AskUserQuestion state is **ephemeral only** - not persisted anywhere:

- ❌ Not stored in message history (`ChatMessagesState.messages`)
- ❌ Not saved to database (sessions.db)
- ❌ Not written to SDK transcript (JSONL)
- ✅ Only exists in `ChatMessagesState.pendingUserQuestion` (runtime state)

**Code location:**
```dart
// app/lib/features/chat/providers/chat_message_providers.dart:108-111
final Map<String, dynamic>? pendingUserQuestion;
```

This field is:
- Set when SSE `user_question` event arrives (line 1598-1609)
- Cleared after user answers (line 1775)
- **Lost when switching sessions** (new state created in constructor)

---

## User Impact

**Severity:** Medium-High
- Breaks question-based workflows (brainstorming, planning, configuration)
- Forces users to parse JSON manually (poor UX)
- No way to recover question after app restart or navigation
- Especially problematic for long-running sessions where questions arrive while user is elsewhere

**Frequency:** Common
- Happens every time user navigates away from a session with an active question
- Mobile users switch sessions frequently
- Desktop users with multiple chat tabs

---

## Technical Details

### Current Architecture

**Backend (computer/):**
- `PermissionHandler.ask_user_question()` creates `UserQuestionRequest` with Future
- Emits SSE event: `UserQuestionEvent` with `requestId`, `questions[]`
- Blocks tool execution waiting for answer (5 min timeout)

**Frontend (app/):**
- Receives SSE event → updates `pendingUserQuestion`
- Renders `UserQuestionCard` above input field (not in message list)
- Submits answer via `POST /api/chat/:sessionId/answer`
- Clears `pendingUserQuestion` on success

**Session Switch Behavior:**
```dart
// chat_message_providers.dart:301-313
void prepareForSessionSwitch() {
  _resetTransientState();  // Does NOT preserve pendingUserQuestion
  state = state.copyWith(isLoading: true);
  // Messages cleared, new state created on loadSession()
}
```

### Why Questions Aren't Persisted

Questions are tied to **streaming execution context**:
- Only valid while agent is waiting for answer
- Backend Future resolves when answer received OR 5-min timeout
- After timeout, agent continues with empty answers `{}`
- No durable record of what was asked or answered

**Open question:** Should answered questions be visible in chat history?

---

## Proposed Solutions

### Option A: Persist Questions in Message History (Recommended)

**Treat questions as special message types:**
- Store question in `ChatMessagesState.messages` as `MessageType.userQuestion`
- Include in SDK transcript (new JSONL event type)
- Show in chat history with "Answered" badge after response
- Persist user's selected answers in message content

**Pros:**
- Full audit trail of questions asked and answered
- Natural UX - questions appear inline with conversation
- Survives session switches, app restarts, transcript replays
- Matches how other tools (Bash, Read, etc.) show up in history

**Cons:**
- Requires message model changes
- Backend needs to emit question as message (not just SSE event)
- Need to design "answered question" message bubble UI

### Option B: Preserve Ephemeral State on Navigation

**Keep questions in runtime state, but don't clear on session switch:**
- Store `pendingUserQuestion` per-session (not global)
- When switching away, preserve question in a map: `sessionId → pendingQuestion`
- When switching back, restore from map
- Still lost on app restart

**Pros:**
- Minimal backend changes
- Preserves current "questions are ephemeral" model
- Simple implementation (pure state management)

**Cons:**
- Questions still lost on app restart
- No audit trail of what was asked/answered
- Doesn't solve all navigation cases (e.g., app backgrounding)

### Option C: Block Session Switch While Question Pending

**Prevent navigation until question answered:**
- Show modal warning: "Answer the question before switching"
- Disable session list / navigation while `pendingUserQuestion != null`
- Force user to answer or explicitly dismiss

**Pros:**
- Zero persistence needed
- Forces completion of question-based workflows
- No complex state management

**Cons:**
- Poor UX - feels restrictive
- Doesn't handle background streams (bot connectors)
- Breaks expected navigation behavior

---

## Recommendation

**Implement Option A: Persist Questions in Message History**

**Why:**
1. **Best UX** - Questions visible inline, just like tool calls and results
2. **Complete audit trail** - See what was asked and how user answered
3. **Robust** - Survives all navigation, restarts, transcript replays
4. **Consistent** - Matches how other interactive elements (permissions, errors) are handled
5. **Future-proof** - Enables features like "edit previous answer", question analytics

**Implementation phases:**
1. Add `MessageType.userQuestion` to message model
2. Backend emits question as message (in addition to SSE event for real-time UI)
3. Frontend renders question message with UserQuestionCard (collapsed if answered)
4. Store answers in message content when submitted
5. Update transcript parser to handle question messages

---

## Success Criteria

- [ ] User switches sessions → question remains visible on return
- [ ] App restarts → unanswered questions show "pending" state
- [ ] Answered questions appear in chat history with selected answers
- [ ] SDK transcript includes question/answer pairs (full audit trail)
- [ ] Bot connectors (Telegram/Discord) handle questions correctly
- [ ] Session list shows indicator for "has unanswered question"

---

## Related Issues

- Part of larger "chat state persistence" improvements
- Related to supervisor model picker persistence (also uses AskUserQuestion)
- Similar to permission request cleanup (issue #64) - interactive prompts need persistence

---

## Files to Modify

**Backend:**
- `computer/parachute/models/events.py` - New message event type
- `computer/parachute/core/orchestrator.py` - Emit question as message
- `computer/parachute/core/permission_handler.py` - Store answer in message

**Frontend:**
- `app/lib/features/chat/models/chat_message.dart` - Add question message type
- `app/lib/features/chat/widgets/user_question_card.dart` - Support "answered" read-only mode
- `app/lib/features/chat/providers/chat_message_providers.dart` - Treat questions as messages
- `app/lib/features/chat/screens/chat_screen.dart` - Render question messages inline

**Tests:**
- Session switch with pending question
- App restart with unanswered question
- Transcript replay with question/answer pair
