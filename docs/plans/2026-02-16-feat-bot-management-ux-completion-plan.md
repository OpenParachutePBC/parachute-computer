---
title: "feat: Bot Management UX Completion"
type: feat
date: 2026-02-16
issue: 23
---

# Bot Management UX Completion

## Enhancement Summary

**Deepened on:** 2026-02-16
**Sections enhanced:** All 4 phases + technical considerations
**Research sources:** SpecFlow analysis, repo-research, source code review of all referenced files

### Key Improvements
1. Added concrete implementation details with exact file locations and line numbers
2. Identified critical missing deny capability (no deny anywhere in app, not just inline)
3. Added `pending_approval` vs `pending_initialization` state machine clarification
4. Grounded polling provider pattern in existing Riverpod conventions from codebase

### New Considerations Discovered
- `SessionConfigSheet` has NO deny button — this is the most critical gap (not just inline UX)
- The existing callback pattern (`onDelete`, `onArchive`, `onUnarchive`) on `SessionListItem` already supports `Future<void> Function()?` — approve/deny should follow the same pattern
- Two separate approve flows (pairing vs activate) can leave sessions in inconsistent states
- `chatSessionsProvider` returns raw server list with no client-side sorting — pending prioritization is straightforward

---

## Overview

Complete the bot management user experience in the Flutter app. The backend is fully implemented — bot connectors, pairing requests, approval/denial APIs, CLI commands, and Settings UI all exist. Research revealed the brainstorm's gap analysis is outdated. The **actual remaining gaps** are narrower and more specific than originally scoped.

## Problem Statement

When an unknown user messages the Parachute Telegram/Discord bot, a pairing request is created and a pending session appears in the Chat list. The owner **cannot deny** pairing requests from the app (only via CLI). Approving requires a non-obvious long-press gesture. There's no real-time notification when new requests arrive. These friction points make bot management feel incomplete despite a solid backend.

## Actual Gap Analysis (vs Brainstorm Claims)

| Brainstorm Claims Missing | Actual Status |
|---------------------------|---------------|
| Pending sessions in Chat UI | **Done** — badges, first message preview in `SessionListItem` |
| `parachute bot` CLI commands | **Done** — full tree in `cli.py:1341-1808` |
| Bot config in Settings UI | **Done** — `BotConnectorsSection` with token, users, trust, start/stop/test |
| Per-user trust overrides | **Partial** — backend stores overrides, no UI to change post-approval |

### Real Remaining Gaps

1. **No deny action in the Flutter app** — `SessionConfigSheet` (`session_config_sheet.dart:405-427`) only has "Activate"/"Save". No "Deny" button exists anywhere in the app.
2. **No inline approve/deny** — Requires long-press -> bottom sheet -> configure -> activate (4 steps).
3. **No real-time pairing alerts** — `chatSessionsProvider` is `FutureProvider.autoDispose` (`chat_session_providers.dart:50`) — fetches once, no polling.
4. **No denial notification to bot users** — `deny_pairing` in `bots.py:400` archives session but sends no message to the denied user.
5. **Pending sessions not prioritized** — Server returns sessions sorted by `updatedAt` desc; pending sessions are mixed in chronologically.

## Proposed Solution

### Phase 1: Deny Capability + Inline Actions (Core UX)

Add deny to both the `SessionConfigSheet` and as inline buttons on `SessionListItem`. This is the highest-impact change.

**Inline button behavior:**
- **Approve**: One-tap using the platform's default DM/group trust level from `bots.yaml`. Calls `POST /api/bots/pairing/{request_id}/approve`. The long-press -> `SessionConfigSheet` path remains for choosing a different trust level.
- **Deny**: Requires brief confirmation dialog. Calls `POST /api/bots/pairing/{request_id}/deny`.

**Files to modify:**

#### `app/lib/features/chat/services/chat_session_service.dart`

Add two methods to `ChatSessionService` extension (this is `part of 'chat_service.dart'`):

```dart
/// Approve a bot pairing request
///
/// Adds user to allowlist, clears pending_approval, sends approval message.
Future<void> approvePairing(String requestId) async {
  final response = await client.post(
    Uri.parse('$baseUrl/api/bots/pairing/${Uri.encodeComponent(requestId)}/approve'),
    headers: defaultHeaders,
  ).timeout(ChatService.requestTimeout);

  if (response.statusCode != 200) {
    throw NetworkError('Failed to approve pairing', statusCode: response.statusCode);
  }
}

/// Deny a bot pairing request
///
/// Archives the session and marks request as denied.
Future<void> denyPairing(String requestId) async {
  final response = await client.post(
    Uri.parse('$baseUrl/api/bots/pairing/${Uri.encodeComponent(requestId)}/deny'),
    headers: defaultHeaders,
  ).timeout(ChatService.requestTimeout);

  if (response.statusCode != 200) {
    throw NetworkError('Failed to deny pairing', statusCode: response.statusCode);
  }
}
```

#### `app/lib/features/chat/widgets/session_list_item.dart`

**Current pattern** (lines 12-28): `SessionListItem` is a `StatelessWidget` that already accepts `Future<void> Function()?` callbacks for `onDelete`, `onArchive`, `onUnarchive`. Follow the same pattern:

```dart
class SessionListItem extends StatelessWidget {
  // ... existing fields ...
  final Future<void> Function()? onApprove;   // NEW
  final Future<void> Function()? onDeny;       // NEW

  const SessionListItem({
    // ... existing params ...
    this.onApprove,    // NEW
    this.onDeny,       // NEW
  });
```

**Inline buttons**: Render in the row below the first message preview, only when `session.isPendingApproval && session.pairingRequestId != null`. Use `Row` with two `IconButton`s:

```dart
if (session.isPendingApproval && onApprove != null && onDeny != null) ...[
  const SizedBox(height: Spacing.xs),
  Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      // Approve button
      SizedBox(
        height: 32,
        child: TextButton.icon(
          onPressed: onApprove,
          icon: Icon(Icons.check_circle_outline, size: 16,
            color: BrandColors.forest),
          label: Text('Approve', style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            color: BrandColors.forest)),
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
            minimumSize: Size.zero,
          ),
        ),
      ),
      const SizedBox(width: Spacing.sm),
      // Deny button
      SizedBox(
        height: 32,
        child: TextButton.icon(
          onPressed: onDeny,
          icon: Icon(Icons.cancel_outlined, size: 16,
            color: BrandColors.error),
          label: Text('Deny', style: TextStyle(
            fontSize: TypographyTokens.labelSmall,
            color: BrandColors.error)),
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
            minimumSize: Size.zero,
          ),
        ),
      ),
    ],
  ),
],
```

**Design decisions:**
- Use `TextButton.icon` (not bare `IconButton`) for accessibility — icon-only buttons need labels for screen readers and are less discoverable on desktop
- 32px height keeps them compact within the list item
- Use `BrandColors.forest` for approve, `BrandColors.error` for deny (consistent with existing codebase colors)
- Place below the first message preview, above the timestamp row — visually groups the action with the pending context

#### `app/lib/features/chat/widgets/session_list_panel.dart`

**Pass callbacks when building `SessionListItem`** (around line 193 where `ListView.builder` is):

```dart
SessionListItem(
  session: session,
  onTap: () => _selectSession(session),
  onDelete: () => _deleteSession(session.id),
  onArchive: () => _archiveSession(session.id),
  // NEW: Pairing request actions
  onApprove: session.isPendingApproval && session.pairingRequestId != null
    ? () => _approvePairing(session)
    : null,
  onDeny: session.isPendingApproval && session.pairingRequestId != null
    ? () => _denyPairing(session)
    : null,
),
```

**Handler methods on `SessionListPanel`** (it's a `ConsumerStatefulWidget` with access to `ref`):

```dart
Future<void> _approvePairing(ChatSession session) async {
  try {
    final service = ref.read(chatServiceProvider);
    await service.approvePairing(session.pairingRequestId!);
    ref.invalidate(chatSessionsProvider);
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to approve: $e')),
      );
    }
  }
}

Future<void> _denyPairing(ChatSession session) async {
  // Confirmation dialog (deny is destructive)
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Deny this user?'),
      content: const Text('They will not be notified and the session will be archived.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: BrandColors.error),
          child: const Text('Deny'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    final service = ref.read(chatServiceProvider);
    await service.denyPairing(session.pairingRequestId!);
    ref.invalidate(chatSessionsProvider);
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to deny: $e')),
      );
    }
  }
}
```

#### `app/lib/features/chat/widgets/session_config_sheet.dart`

Add "Deny" button for `pending_approval` sessions. Currently the bottom of the sheet (lines 405-427) has only the "Save"/"Activate" button. Add a deny button above it:

```dart
// Deny button (only for pending approval sessions, not pending initialization)
if (widget.session.isPendingApproval && widget.session.pairingRequestId != null) ...[
  SizedBox(height: Spacing.sm),
  SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: _isSaving ? null : _deny,
      style: OutlinedButton.styleFrom(
        foregroundColor: BrandColors.error,
        side: BorderSide(color: BrandColors.error),
        padding: EdgeInsets.symmetric(vertical: Spacing.sm),
      ),
      child: const Text('Deny Request'),
    ),
  ),
],
```

**Add `_deny()` method:**

```dart
Future<void> _deny() async {
  setState(() { _isSaving = true; _error = null; });
  try {
    final featureFlags = ref.read(featureFlagsServiceProvider);
    final serverUrl = await featureFlags.getAiServerUrl();
    final apiKey = await ref.read(apiKeyProvider.future);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (apiKey != null && apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
    final response = await http.post(
      Uri.parse('$serverUrl/api/bots/pairing/${widget.session.pairingRequestId}/deny'),
      headers: headers,
    );
    if (mounted) {
      if (response.statusCode == 200) {
        Navigator.of(context).pop(true); // true = changed, triggers refresh
      } else {
        setState(() => _error = 'Deny failed (${response.statusCode})');
      }
    }
  } catch (e) {
    if (mounted) setState(() => _error = 'Deny failed: $e');
  } finally {
    if (mounted) setState(() => _isSaving = false);
  }
}
```

**Important:** `_isActivation` checks `isPendingInitialization`, NOT `isPendingApproval`. These are different states:
- `isPendingApproval` = unknown user awaiting owner decision (shows "Pending" badge)
- `isPendingInitialization` = known user's session awaiting workspace/trust config (shows "Setup" badge)

The deny button should only appear for `isPendingApproval` sessions.

### Phase 2: Pending Session Prioritization

Sort pending sessions to the top of the session list so they're impossible to miss.

#### `app/lib/features/chat/providers/chat_session_providers.dart`

Modify `chatSessionsProvider` (line 50) to sort pending sessions to top after fetching:

```dart
final chatSessionsProvider = FutureProvider.autoDispose<List<ChatSession>>((ref) async {
  final service = ref.watch(chatServiceProvider);
  final localReader = ref.watch(localSessionReaderProvider);

  try {
    final serverSessions = await service.getSessions();
    debugPrint('[ChatProviders] Loaded ${serverSessions.length} sessions from server');
    // Sort: pending approval first, then by updatedAt descending
    serverSessions.sort((a, b) {
      if (a.isPendingApproval && !b.isPendingApproval) return -1;
      if (!a.isPendingApproval && b.isPendingApproval) return 1;
      // Within same category, sort by most recent first
      return (b.updatedAt ?? b.createdAt).compareTo(a.updatedAt ?? a.createdAt);
    });
    return serverSessions;
  } catch (e) {
    // ... existing fallback logic unchanged ...
  }
});
```

**Why client-side sort:** The server's `GET /api/chat` already returns sessions sorted by `updatedAt` desc. Adding a `pending_first` query param would require server changes. Client-side sort on an already-fetched list of max 500 sessions is negligible cost and keeps the change minimal.

### Phase 3: Real-Time Pairing Alerts

Add lightweight polling for pending request count and a badge on the Chat tab.

#### `computer/parachute/api/bots.py`

Add endpoint after the existing `GET /api/bots/pairing` (line 338):

```python
@router.get("/bots/pairing/count")
async def get_pending_pairing_count() -> dict:
    """Get count of pending pairing requests. Lightweight endpoint for polling."""
    count = await _db.get_pending_pairing_count()
    return {"pending": count}
```

#### `computer/parachute/db/database.py`

Add method (near existing pairing methods at lines 758-880):

```python
async def get_pending_pairing_count(self) -> int:
    """Get count of pending pairing requests."""
    async with aiosqlite.connect(self.db_path) as db:
        cursor = await db.execute(
            "SELECT COUNT(*) FROM pairing_requests WHERE status = 'pending'"
        )
        row = await cursor.fetchone()
        return row[0] if row else 0
```

#### `app/lib/features/chat/providers/chat_session_providers.dart`

Add polling provider. The app has no existing polling pattern, but Riverpod's `StreamProvider` with `Stream.periodic` is the cleanest approach:

```dart
/// Polls for pending pairing request count every 30 seconds.
/// Returns 0 if server is unreachable.
final pendingPairingCountProvider = StreamProvider.autoDispose<int>((ref) {
  final service = ref.watch(chatServiceProvider);

  return Stream.periodic(const Duration(seconds: 30), (_) => _)
      .asyncMap((_) async {
    try {
      // Call the lightweight count endpoint
      final response = await http.get(
        Uri.parse('${service.baseUrl}/api/bots/pairing/count'),
        headers: service.defaultHeaders,
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['pending'] as int? ?? 0;
      }
      return 0;
    } catch (_) {
      return 0;
    }
  });
});
```

**Why `StreamProvider` + `Stream.periodic`:**
- `autoDispose` ensures the timer stops when no widget watches it (app backgrounded, tab switched)
- No manual timer cleanup needed
- Consistent with Riverpod patterns in `app/CLAUDE.md`

#### `app/lib/main.dart`

Add badge to the Chat `NavigationDestination` (around line 570-578). Wrap the icon with a `Badge` widget:

```dart
NavigationDestination(
  icon: Consumer(
    builder: (context, ref, child) {
      final pendingCount = ref.watch(pendingPairingCountProvider).valueOrNull ?? 0;
      return Badge(
        isLabelVisible: pendingCount > 0,
        label: Text('$pendingCount'),
        child: Icon(
          Icons.chat_bubble_outline,
          color: isDark ? BrandColors.nightTextSecondary : BrandColors.driftwood,
        ),
      );
    },
  ),
  selectedIcon: Consumer(
    builder: (context, ref, child) {
      final pendingCount = ref.watch(pendingPairingCountProvider).valueOrNull ?? 0;
      return Badge(
        isLabelVisible: pendingCount > 0,
        label: Text('$pendingCount'),
        child: Icon(
          Icons.chat_bubble,
          color: isDark ? BrandColors.nightTurquoise : BrandColors.turquoise,
        ),
      );
    },
  ),
  label: 'Chat',
),
```

**Note:** Flutter's `Badge` widget (Material 3) is built-in since Flutter 3.7. No additional package needed.

### Phase 4: Denial Notification (Bot Connector)

Send a message to denied users so they're not left waiting.

#### `computer/parachute/connectors/base.py`

Add method to `BotConnector` base class. The existing `send_approval_message` pattern (called from `bots.py:391`) provides the template:

```python
async def send_denial_message(self, chat_id: str) -> None:
    """Send denial notification to a user. Override in subclass."""
    logger.warning(f"send_denial_message not implemented for {self.__class__.__name__}")
```

**Note:** Use a default implementation (not abstract) so existing connectors don't break if they haven't implemented it yet.

#### `computer/parachute/connectors/telegram.py`

```python
async def send_denial_message(self, chat_id: str) -> None:
    """Send denial notification to Telegram user."""
    try:
        await self.bot.send_message(
            chat_id=int(chat_id),
            text="Your request was not approved.",
        )
    except Exception as e:
        logger.warning(f"Failed to send denial message to {chat_id}: {e}")
```

#### `computer/parachute/connectors/discord_bot.py`

```python
async def send_denial_message(self, chat_id: str) -> None:
    """Send denial notification to Discord user."""
    try:
        channel = self.bot.get_channel(int(chat_id))
        if channel:
            await channel.send("Your request was not approved.")
    except Exception as e:
        logger.warning(f"Failed to send denial message to {chat_id}: {e}")
```

#### `computer/parachute/api/bots.py`

In `deny_pairing` endpoint (line 400), add denial notification after archiving:

```python
# After existing deny logic...
connector = _connectors.get(pr.platform)
if connector and hasattr(connector, 'send_denial_message'):
    try:
        await connector.send_denial_message(pr.platform_chat_id)
    except Exception as e:
        logger.warning(f"Failed to send denial notification: {e}")
        # Don't fail the deny operation if notification fails
```

## Technical Considerations

### State Consistency: Approve Flow

Two separate endpoints handle approval:
- `POST /api/bots/pairing/{id}/approve` (`bots.py:349`) — adds to allowlist, clears `pending_approval`, sends approval message
- `POST /api/chat/{id}/activate` (`sessions.py:167`) — sets workspace, trust level, response mode, clears `pending_initialization`

**Decision**: Inline approve calls the pairing endpoint only. The `SessionConfigSheet` continues to use the activate endpoint for full configuration. Both paths result in a functional session.

**Edge case**: If `pairing_request_id` is missing from session metadata (older server version), inline buttons won't render (guarded by `session.pairingRequestId != null`). The long-press -> sheet path remains as fallback.

### `pending_approval` vs `pending_initialization` State Machine

These are two different states with different UX:

```
Unknown user messages bot
  → Session created with metadata: { pending_approval: true, pairing_request_id: "..." }
  → Shows "Pending" badge (amber) + inline approve/deny

Owner approves (via inline or CLI)
  → pending_approval cleared
  → User added to allowlist
  → If session also has pending_initialization: shows "Setup" badge (orange)
  → Owner configures via SessionConfigSheet (trust, workspace, response mode)

Owner activates (via SessionConfigSheet)
  → pending_initialization cleared
  → Session becomes normal active session
```

**Critical**: Inline approve/deny buttons should ONLY appear for `isPendingApproval`, NOT for `isPendingInitialization`. The sheet's existing "Activate" button handles the initialization step.

### Widget Architecture

`SessionListItem` is a `StatelessWidget` (line 12) with existing callback pattern:
```dart
final Future<void> Function()? onDelete;
final Future<void> Function()? onArchive;
final Future<void> Function()? onUnarchive;
```

Adding `onApprove` and `onDeny` follows the identical pattern. No need to convert to `ConsumerWidget`. The parent `SessionListPanel` (which IS a `ConsumerStatefulWidget`) handles the API calls and provider invalidation.

### Polling vs SSE for Alerts

SSE exists for chat streaming but extending it for session-list events is over-engineering. A `GET /api/bots/pairing/count` endpoint returning `{"pending": 0}` is:
- ~1ms server-side (single COUNT query)
- ~100 bytes per response
- 2 requests/minute when app is in foreground
- Zero requests when app is backgrounded (provider auto-disposes)

### Security

- No new attack surface — all endpoints already exist and are authenticated
- `pairingRequestId` is a UUID stored in session metadata — no user input in the approve/deny URLs
- Denial message uses a static string ("Your request was not approved.") — no user-controlled content
- Race condition on double-approve: server's `approve_pairing` checks status first and returns 400 if already approved

## Acceptance Criteria

### Phase 1: Deny + Inline Actions
- [ ] `SessionConfigSheet` shows "Deny Request" button for `pending_approval` sessions (`session_config_sheet.dart`)
- [ ] Deny calls `POST /api/bots/pairing/{id}/deny` and closes sheet with `true` result
- [ ] `SessionListItem` shows inline Approve/Deny buttons for `pending_approval` sessions (`session_list_item.dart`)
- [ ] Inline approve calls `POST /api/bots/pairing/{id}/approve` (platform default trust)
- [ ] Inline deny shows confirmation dialog before proceeding
- [ ] Session list refreshes (`ref.invalidate(chatSessionsProvider)`) after both actions
- [ ] Error states show SnackBar feedback
- [ ] Buttons only render when `pairingRequestId` is non-null (graceful fallback)

### Phase 2: Prioritization
- [ ] Pending approval sessions sort to top of session list (`chat_session_providers.dart`)
- [ ] Non-pending sessions retain `updatedAt` descending order below

### Phase 3: Real-Time Alerts
- [ ] `GET /api/bots/pairing/count` endpoint returns `{"pending": N}` (`bots.py`)
- [ ] `get_pending_pairing_count()` DB method added (`database.py`)
- [ ] `pendingPairingCountProvider` polls every 30 seconds (`chat_session_providers.dart`)
- [ ] Chat tab `NavigationDestination` shows `Badge` with count when > 0 (`main.dart`)
- [ ] Badge disappears when count reaches 0
- [ ] Polling stops when provider is disposed (app backgrounded)

### Phase 4: Denial Notification
- [ ] `send_denial_message` method on `BotConnector` base class (`base.py`)
- [ ] Telegram implementation sends "Your request was not approved." (`telegram.py`)
- [ ] Discord implementation sends denial DM (`discord_bot.py`)
- [ ] `deny_pairing` endpoint calls `send_denial_message` if connector is running (`bots.py`)
- [ ] Gracefully handles offline connector (logs warning, doesn't fail the deny)

## Deferred to Follow-Up Issues

- **Per-user trust level management UI** — Requires new API endpoint and a user list view. Scoped separately.
- **Pairing request rate limiting** — Prevent abuse by flooding pairing requests
- **Bot connector crash/restart notifications** — Proactive alerts when a connector goes offline

## References

### Internal (with line numbers)
- `app/lib/features/chat/widgets/session_list_item.dart:12-28` — Widget class with callback pattern
- `app/lib/features/chat/widgets/session_list_item.dart:122-127` — Existing pending badges
- `app/lib/features/chat/widgets/session_list_item.dart:145-159` — First message preview
- `app/lib/features/chat/widgets/session_list_panel.dart:193` — ListView.builder for sessions
- `app/lib/features/chat/widgets/session_config_sheet.dart:49` — `_isActivation` checks `isPendingInitialization`
- `app/lib/features/chat/widgets/session_config_sheet.dart:405-427` — Save/Activate button (only button)
- `app/lib/features/chat/services/chat_session_service.dart` — Part file of `chat_service.dart`
- `app/lib/features/chat/models/chat_session.dart:129-141` — `isPendingApproval`, `pairingRequestId` accessors
- `app/lib/features/chat/providers/chat_session_providers.dart:50-72` — `chatSessionsProvider`
- `app/lib/main.dart:570-578` — Chat tab NavigationDestination
- `computer/parachute/api/bots.py:338-345` — `GET /api/bots/pairing` endpoint
- `computer/parachute/api/bots.py:349-397` — `approve_pairing` endpoint
- `computer/parachute/api/bots.py:400-421` — `deny_pairing` endpoint
- `computer/parachute/api/sessions.py:167` — Session activate endpoint
- `computer/parachute/connectors/base.py:142-204` — `handle_unknown_user` + pairing creation
- `computer/parachute/db/database.py:758-880` — DB methods for pairing requests

### Related Issues
- #23: Original brainstorm (this plan updates the gap analysis)
