---
title: "Persistent cards with read/unread state and card types"
type: feat
date: 2026-03-24
issue: 322
---

# Persistent Cards with Read/Unread State

Cards drift forward until seen. Unread cards are buoyant — they float to today's surface. Once read, they settle back to their home date.

## Acceptance Criteria

- [x] Card schema has `card_type` (STRING, default `"default"`) and `read_at` (STRING, nullable)
- [x] Card ID format: `{agent_name}:{card_type}:{date}` — deterministic, idempotent
- [x] `write_card` tool accepts optional `card_type` parameter
- [x] `GET /api/daily/cards/unread` returns unread cards within 7-day window
- [x] `POST /api/daily/cards/{card_id}/read` sets `read_at` timestamp
- [x] Re-running an agent that overwrites a read card resets `read_at` to null
- [x] Flutter model parses `card_type` and `read_at`
- [x] Today's journal page shows "Unread from past days" section (floated cards)
- [x] Cards auto-mark as read on collapse (not on expand)
- [x] Unread badge on Daily nav tab (same pattern as chat badge)
- [x] Existing cards migrate gracefully (old `{agent_name}:{date}` IDs still work)

---

## Phase 1: Schema & Backend

### 1.1 Add columns to Card table

**File**: `computer/parachute/db/brain_chat_store.py` (~line 252)

Add `card_type` and `read_at` to the Card table schema:

```python
await self.graph.ensure_node_table(
    "Card",
    {
        "card_id": "STRING",
        "agent_name": "STRING",
        "card_type": "STRING",      # NEW
        "display_name": "STRING",
        "content": "STRING",
        "generated_at": "STRING",
        "status": "STRING",
        "date": "STRING",
        "read_at": "STRING",         # NEW — null = unread
    },
    primary_key="card_id",
)
```

Kuzu's `ensure_node_table` handles existing tables — new columns get added via ALTER. Existing cards will have `card_type = null` and `read_at = null`.

### 1.2 Update `write_card` tool (SDK-native agents)

**File**: `computer/parachute/core/daily_agent_tools.py` (~line 171)

- Add optional `card_type` parameter to the tool schema (default: `"default"`)
- Change card_id generation: `f"{agent_name}:{card_type}:{date_str}"`
- Include `card_type` in the MERGE SET
- On MERGE of existing card, reset `read_at` to empty string (Kuzu doesn't have null SET, use `''`): `c.read_at = ''`

### 1.3 Update `_write_initial_card` (running status)

**File**: `computer/parachute/core/daily_agent.py` (~line 374)

- Accept `card_type` parameter (default `"default"`)
- Update card_id: `f"{agent_name}:{card_type}:{output_date}"`
- Set `c.card_type = $card_type` and `c.read_at = ''`

### 1.4 Update `_mark_card_failed`

**File**: `computer/parachute/core/daily_agent.py` (~line 400)

No change needed — matches by `card_id` which the caller already has.

### 1.5 Update MCP bridge `write_card`

**File**: `computer/parachute/api/mcp_tools.py` (~line 85)

- Add `card_type` to inputSchema (optional, default `"default"`)
- Update card_id generation and SET clause
- Reset `read_at` on write

### 1.6 Update HTTP `POST /cards/write` endpoint

**File**: `computer/modules/daily/module.py` (~line 1961)

- Accept `card_type` from body (default `"default"`)
- Update card_id and SET clause

### 1.7 New API endpoints

**File**: `computer/modules/daily/module.py`

Add two new endpoints (register BEFORE the `cards/{agent_name}` route to avoid path conflicts):

```python
@router.get("/cards/unread")
async def list_unread_cards():
    """Fetch all unread cards within 7-day window."""
    # Cypher: MATCH (c:Card) WHERE (c.read_at IS NULL OR c.read_at = '')
    #         AND c.status = 'done'
    #         AND c.date >= $cutoff_date
    #         RETURN c ORDER BY c.date DESC, c.generated_at DESC

@router.post("/cards/{card_id}/read")
async def mark_card_read(card_id: str):
    """Set read_at timestamp on a card."""
    # Cypher: MATCH (c:Card {card_id: $card_id}) SET c.read_at = $now
    # Return 404 if no match
```

**Route ordering**: `/cards/unread` must be registered before `/cards/{agent_name}` — otherwise FastAPI matches "unread" as an agent_name. Same for `/cards/{card_id}/read`.

### 1.8 Update existing card query responses

**File**: `computer/modules/daily/module.py` (~line 1879)

The existing `GET /cards` and `GET /cards/{agent_name}` endpoints return Cypher row dicts directly — `card_type` and `read_at` will automatically appear in responses once the schema columns exist. No code change needed, but verify the Cypher `RETURN c` includes new fields.

---

## Phase 2: Flutter Model & API

### 2.1 Update `AgentCard` model

**File**: `app/lib/features/daily/journal/models/agent_card.dart`

```dart
class AgentCard {
  // ... existing fields ...
  final String cardType;      // NEW — "default", "reflection", etc.
  final String? readAt;       // NEW — ISO timestamp, null = unread

  bool get isRead => readAt != null && readAt!.isNotEmpty;
  bool get isUnread => !isRead;
}
```

Update `fromJson` to parse `card_type` (default `"default"`) and `read_at`.

### 2.2 Add API methods to `DailyApiService`

**File**: `app/lib/features/daily/journal/services/daily_api_service.dart`

```dart
/// Fetch all unread cards (7-day window)
Future<List<AgentCard>> fetchUnreadCards() async { ... }

/// Mark a card as read
Future<bool> markCardRead(String cardId) async { ... }
```

### 2.3 Add unread cards provider

**File**: `app/lib/features/daily/journal/providers/journal_providers.dart`

```dart
/// Fetch all unread cards (cross-date, 7-day window).
/// Used for the "Unread from past days" section and the nav badge.
final unreadCardsProvider = FutureProvider.autoDispose<List<AgentCard>>((ref) async {
  ref.watch(journalRefreshTriggerProvider);
  final isAvailable = ref.watch(isServerAvailableProvider);
  if (!isAvailable) return [];
  final api = ref.watch(dailyApiServiceProvider);
  return api.fetchUnreadCards();
});
```

---

## Phase 3: Flutter UI

### 3.1 Auto-read on collapse

**File**: `app/lib/features/daily/journal/widgets/agent_output_header.dart`

In `_toggle()` method — when collapsing an unread card, fire the mark-read API:

```dart
void _toggle() {
  final wasExpanded = _isExpanded;
  setState(() {
    _isExpanded = !_isExpanded;
    _isExpanded ? _controller.forward() : _controller.reverse();
  });
  // Mark read on collapse (not expand) — handles accidental taps
  if (wasExpanded && widget.card.isUnread) {
    widget.onMarkRead?.call(widget.card.cardId);
  }
}
```

Add `onMarkRead` callback to `AgentOutputHeader`. The parent (`JournalAgentOutputsSection`) wires it to the API call + optimistic state update.

### 3.2 Unread visual styling

**File**: `app/lib/features/daily/journal/widgets/agent_output_header.dart`

When `card.isUnread`:
- Show a small dot indicator (accent color) next to the card title
- Slightly bolder border or background tint

When `card.isRead`:
- Standard muted styling (as today)

Keep it subtle — a dot and slight tint difference, not a loud badge.

### 3.3 "Unread from past days" section on today's journal

**File**: `app/lib/features/daily/journal/widgets/journal_agent_outputs_section.dart` (or new widget)

On today's journal page, above today's cards:
- Watch `unreadCardsProvider`
- Filter to cards where `card.date != today` (past-day floaters only)
- If any exist, show a section header "Earlier" or "Unread" with the cards
- Each card shows its date as secondary text (e.g., "Mar 22")
- Cards use the same `AgentOutputHeader` with `onMarkRead` wired up
- Section collapses away when empty (no empty state)

### 3.4 Unread badge on Daily nav tab

**File**: `app/lib/main.dart` (~line 268)

Follow the same pattern as `_buildChatTabIcon`:

```dart
Widget _buildDailyTabIcon(bool isDark, bool selected) {
  final unreadCount = ref.watch(unreadCardsProvider).valueOrNull?.length ?? 0;
  final icon = Icon(
    selected ? Icons.wb_sunny : Icons.wb_sunny_outlined,
    color: selected ? ... : ...,
  );
  if (unreadCount > 0) {
    return Badge(label: Text('$unreadCount'), child: icon);
  }
  return icon;
}
```

---

## Phase 4: Migration & Backward Compatibility

### 4.1 Old card IDs

Existing cards have IDs like `process-day:2026-03-24` (two segments). New cards have `process-day:reflection:2026-03-24` (three segments).

Strategy: **don't migrate old IDs**. The MERGE key is `card_id` — old cards keep their old IDs. New writes use the new format. Both formats are valid strings, no parsing assumptions.

The `GET /cards?date=` and `GET /cards/unread` endpoints filter by `c.date` and `c.read_at`, not by parsing the card_id — so both formats work.

Old cards will have `card_type = null` (or empty) and `read_at = null` (or empty). In Flutter, treat `card_type == null || card_type == ''` as `"default"`. Treat `read_at == null || read_at == ''` as unread.

### 4.2 Existing agents

Agents that don't pass `card_type` to `write_card` get `"default"`. Their card_id becomes `{agent_name}:default:{date}` — a NEW card_id, separate from the old `{agent_name}:{date}`. The old card becomes orphaned.

**One-time cleanup**: After deploy, run a Cypher query to delete old-format cards that have a corresponding new-format card:

```cypher
MATCH (old:Card) WHERE old.card_id =~ '^[a-z-]+:\\d{4}-\\d{2}-\\d{2}$'
WITH old, old.agent_name + ':default:' + old.date AS new_id
MATCH (new:Card {card_id: new_id})
DELETE old
```

Or simpler: just let old cards age out. They'll stop appearing after 7 days since they have no `card_type` set and won't match the unread window query.

---

## Files Changed

### Python (computer/)
| File | Change |
|------|--------|
| `parachute/db/brain_chat_store.py` | Add `card_type`, `read_at` columns to Card table |
| `parachute/core/daily_agent_tools.py` | `write_card` accepts `card_type`, new ID format, reset `read_at` |
| `parachute/core/daily_agent.py` | `_write_initial_card` accepts `card_type`, new ID format |
| `parachute/api/mcp_tools.py` | MCP `write_card` accepts `card_type`, new ID format |
| `modules/daily/module.py` | New endpoints: `GET /cards/unread`, `POST /cards/{card_id}/read`; update `POST /cards/write` |

### Flutter (app/)
| File | Change |
|------|--------|
| `models/agent_card.dart` | Add `cardType`, `readAt`, `isRead`/`isUnread` getters |
| `services/daily_api_service.dart` | Add `fetchUnreadCards()`, `markCardRead()` |
| `providers/journal_providers.dart` | Add `unreadCardsProvider` |
| `widgets/agent_output_header.dart` | `onMarkRead` callback on collapse, unread dot styling |
| `widgets/journal_agent_outputs_section.dart` | Wire `onMarkRead`, floated unread section |
| `main.dart` | Unread badge on Daily tab icon |

---

## Design Decisions

1. **Deterministic IDs** (`{agent_name}:{card_type}:{date}`) — preserves idempotent MERGE, prevents duplicates on re-runs
2. **`read_at` reset on overwrite** — new content from a re-run deserves a fresh read
3. **7-day float window** — prevents ancient cards from piling up
4. **Auto-read on collapse, not expand** — handles accidental taps gracefully
5. **Card type ≠ tag** — card_type is structural identity baked into the ID; tags (#321) are organizational metadata, many-to-many
6. **No migration of old IDs** — old cards age out naturally; new writes use new format

## Open Questions (resolved)

- **Unread badge includes today's unread cards** — yes, all unread
- **Re-run resets read_at** — yes, new content = new read
