import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:parachute/features/chat/widgets/message_bubble.dart';
import 'package:parachute/features/chat/widgets/chat_input.dart';
import 'package:parachute/features/chat/models/chat_message.dart';

// Actual markdown content from Community Murmur session that triggers disposal errors
const _realMarkdownContent1 = '''
Alright, here's the lay of the land:

## Current State

**Branch:** `feature/e2e-testing-suite`
**Status:** Clean working tree, synced with origin

---

## Recent Work (last ~15 commits)

The most recent sprint has been focused on:

1. **E2E Testing Suite** (Issue #23) - comprehensive Playwright tests added
2. **Frontend-Backend Integration** - auth context, data hooks connecting to Supabase
3. **Pre-votes table migration** - for the voting feature
4. **CI fixes** - TypeScript errors, Supabase env var fallbacks

---

## Open PRs

| PR | Branch | Status |
|----|--------|--------|
| **#26** | `feature/e2e-testing-suite` | Open, mergeable but "UNSTABLE" (likely CI issues) |
| **#25** | `feature/passkey-auth-voting` | Open - passkey auth work |
| **#21** | `feature/frontend-backend-integration` | Open |

---

## Open Issues (by priority)

**P0:**
- **#24** - Passkey Auth & On-Chain Voting (SchellingPointVotes)
- **#7** - Pre-Event Voting System

**P1:**
- **#20** - Frontend-Backend Integration (in progress via PR #21)
- **#13** - Quadratic Funding Distribution & Smart Contract
- **#9** - Attendance Voting System (Tap-to-Vote)
- **#3** - Event Access Control & NFT Gating

**P2:**
- **#14** - Supabase Real-time Subscriptions

**P3 (Stretch):**
- **#15, #16** - AI features (session merger, RAG chatbot)

---

## Where Things Stand

You're **10 commits ahead of main** on this branch. The E2E testing PR is ready to merge but showing as "UNSTABLE" - probably a flaky test or CI config issue.

The main active threads are:
1. **E2E testing** - mostly done, needs CI to pass
2. **Passkey auth voting** (PR #25) - separate branch for the Web3/smart wallet work
3. **Frontend-backend integration** (PR #21) - still open

Want me to dig into the CI failure on PR #26, or check out where the passkey auth work is at?
''';

const _realMarkdownContent2 = '''
Now I have a complete picture. Here's the comprehensive audit:

---

# 🔍 Complete App Functionality Audit

## Executive Summary

| Layer | Status | Mock/Fake | Real |
|-------|--------|-----------|------|
| **API Routes** | ✅ 100% Real | 0/19 | 19/19 |
| **Hooks** | ✅ 100% Real | 0/8 | 8/8 |
| **Pages** | ⚠️ 58% Real | 7/19 | 11/19 |

**The backend is solid. The problem is in the frontend pages that bypass the hooks and use hardcoded data.**

---

## 🔴 HIGH RISK - Pages Using Mock Data

These pages have **hardcoded demo data** and need to be connected to real APIs:

| Page | Problem | Mock Variables |
|------|---------|----------------|
| `/event/dashboard` | Complete mock dashboard | `eventStats`, `topSessions` (5 fake sessions) |
| `/event/schedule` | Entire schedule is fake | `venues`, `timeSlots`, `sessions` (13 fake sessions) |
| `/event/my-votes` | Mock voting data | `mockVotes` (4 fake sessions), hardcoded 100 credits |
| `/event/my-schedule` | Fake favorites | `mockFavoritedSessions` (3 fake sessions) |
| `/event/participants` | Fake participant list | `participants` (6 fake people with bios) |
| `/event/live` | Mock live session | `currentSession`, `votedSessions` |
| `/admin/distribution` | Fake distribution data | `distributionData` (8 fake rows), fake tx hash |

---

## 🟡 MEDIUM RISK - Partially Working

| Page | Issue |
|------|-------|
| `/admin/venues` | Uses real `useVenues` hook BUT time slots are hardcoded (`initialTimeSlots`) |
| `/admin/settings` | UI works but **no API save** - settings don't persist |
| `/admin/participants` | Mock data (4 fake participants) |
| `/admin/tablet/vote` | Simulates NFC scan with `setTimeout` and `mockNames` |
| `/admin/tablet/check-in` | Simulates NFC scan |
| `/profile` | Hardcoded profile (Alice Chen) |

---

## ✅ WORKING - Real API Integration

| Page | Hooks Used |
|------|------------|
| `/event/sessions` | `useSessions`, `useVotes`, `useAuth` |
| `/event/sessions/[id]` | `useSession`, `useVotes` |
| `/event/propose` | `useAuth`, real POST to `/api/events/{slug}/sessions` |
| `/event/my-sessions` | `useSessions` with `mine: true` filter |
| `/admin/sessions` | `useSessions`, approve/reject API calls |
| `/admin/schedule` | `useVenues`, `useSessions`, `useTimeSlots`, `useSchedule` |
| **Auth flow** | Real Supabase magic link (now fixed on main!) |

---

## ✅ API Routes - All Real

All 19 API routes use **real Supabase queries**:
- Events, Sessions, Venues, Time Slots - CRUD operations
- Votes - Quadratic voting with credit validation
- Schedule - Generation algorithm + publish/lock
- Access - Grant/revoke with CSV bulk import

**TODOs in API routes** (non-blocking):
- Email notifications not implemented (approve/reject/publish)
- On-chain EAS attestation not implemented

---

## ✅ Hooks - All Real

All 8 hooks make **real API calls**:
- `useAuth` → Supabase Auth SDK
- `useEvent` → GET /api/events/{slug}
- `useSessions` → GET /api/events/{slug}/sessions
- `useSession` → GET /api/events/{slug}/sessions/{id}
- `useVotes` → GET/POST /api/events/{slug}/votes
- `useVenues` → CRUD /api/events/{slug}/venues
- `useTimeSlots` → GET/POST /api/events/{slug}/time-slots
- `useSchedule` → POST generate/publish

---

## 🛠️ Recommended Fixes (Priority Order)

### Immediate (Core User Flow)
1. **`/event/my-votes`** - Replace `mockVotes` with `useVotes` hook
2. **`/event/schedule`** - Replace hardcoded data with real schedule API
3. **`/event/dashboard`** - Add dashboard stats API or aggregate from existing data

### Important (User Experience)
4. **`/event/my-schedule`** - Store favorites in DB, not local mock
5. **`/event/participants`** - Use participants API
6. **`/profile`** - Fetch from Supabase users table

### Nice to Have (Admin)
7. **`/admin/settings`** - Add settings persistence API
8. **`/admin/distribution`** - Implement real distribution logic
9. **`/admin/tablet/*`** - Real NFC integration (hardware dependent)

---

Would you like me to start fixing the high-priority pages? I can update `/event/my-votes`, `/event/schedule`, and `/event/dashboard` to use real data from the hooks that already exist.
''';

const _realMarkdownContent3 = '''
I've completed fixing all 5 high-priority pages that were using mock data. Here's a summary of the changes made:

## Summary of Fixes

### 1. `/event/my-votes` ✅
- Now uses `useVotes` hook to fetch real vote data
- Displays actual vote credits and history

### 2. `/event/schedule` ✅
- Now uses `useVenues`, `useTimeSlots`, `useSessions` hooks
- Shows real schedule grid when available

### 3. `/event/dashboard` ✅
- Now uses `useEvent` and `useSessions` hooks
- Calculates real statistics from session data
- Fixed type error with `votingConfig` and `budgetConfig`

### 4. `/event/my-schedule` ✅
- Created new `useFavorites` hook that persists to localStorage
- Now filters scheduled sessions to show only favorited ones
- Updated sessions page to use the shared favorites hook

### 5. `/event/participants` ✅
- Created new `useParticipants` hook
- Shows real participant data for admins
- Displays proper "Access Restricted" message for non-admins
- Shows stats for total registered, checked-in, and organizers

### New Files Created:
- `src/hooks/use-favorites.ts` - localStorage-based favorites persistence
- `src/hooks/use-participants.ts` - API hook for admin participant data

All pages now use real API data instead of mock/hardcoded data, and the build passes successfully.
''';

void main() {
  group('Chat screen disposal with REAL Community Murmur content', () {
    testWidgets('disposes cleanly with complex markdown tables', (tester) async {
      final messages = [
        ChatMessage(
          id: '1',
          sessionId: 'test-session',
          role: MessageRole.user,
          content: [MessageContent(type: ContentType.text, text: 'give me the status')],
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: '2',
          sessionId: 'test-session',
          role: MessageRole.assistant,
          content: [MessageContent(type: ContentType.text, text: _realMarkdownContent1)],
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: '3',
          sessionId: 'test-session',
          role: MessageRole.user,
          content: [MessageContent(type: ContentType.text, text: 'do a comprehensive audit')],
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: '4',
          sessionId: 'test-session',
          role: MessageRole.assistant,
          content: [MessageContent(type: ContentType.text, text: _realMarkdownContent2)],
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: '5',
          sessionId: 'test-session',
          role: MessageRole.user,
          content: [MessageContent(type: ContentType.text, text: 'great, fix those')],
          timestamp: DateTime.now(),
        ),
        ChatMessage(
          id: '6',
          sessionId: 'test-session',
          role: MessageRole.assistant,
          content: [MessageContent(type: ContentType.text, text: _realMarkdownContent3)],
          timestamp: DateTime.now(),
        ),
      ];

      // Build full chat screen with real markdown content
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Navigator(
              onGenerateRoute: (settings) {
                return MaterialPageRoute(
                  builder: (context) => Scaffold(
                    appBar: AppBar(
                      leading: IconButton(
                        icon: Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      title: Text('Community Murmur Test'),
                    ),
                    body: Column(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              return MessageBubble(
                                message: messages[index],
                                vaultPath: '/tmp/test',
                              );
                            },
                          ),
                        ),
                        ChatInput(
                          onSend: (text, attachments) {},
                          enabled: true,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      print('Chat screen with real markdown tables rendered');

      // Scroll through messages to ensure they're all built
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      print('Scrolled down');

      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      print('Scrolled more');

      // Navigate away - this should trigger the disposal
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      print('Navigation complete - disposal should have happened');
    });

    testWidgets('disposes cleanly with focus then navigate', (tester) async {
      final messages = [
        ChatMessage(
          id: '1',
          sessionId: 'test-session',
          role: MessageRole.assistant,
          content: [MessageContent(type: ContentType.text, text: _realMarkdownContent2)],
          timestamp: DateTime.now(),
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Navigator(
              onGenerateRoute: (settings) {
                return MaterialPageRoute(
                  builder: (context) => Scaffold(
                    body: Column(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              return MessageBubble(
                                message: messages[index],
                                vaultPath: '/tmp/test',
                              );
                            },
                          ),
                        ),
                        ChatInput(
                          onSend: (text, attachments) {},
                          enabled: true,
                        ),
                      ],
                    ),
                    floatingActionButton: FloatingActionButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Icon(Icons.close),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      print('Screen with complex markdown rendered');

      // Focus the text field
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      print('TextField focused');

      // Navigate away while focused - this is more likely to trigger issues
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      print('Navigated away while focused');
    });

    testWidgets('rapid scroll and exit with complex markdown', (tester) async {
      // Create many messages to simulate real session
      final messages = <ChatMessage>[];
      for (int i = 0; i < 20; i++) {
        messages.add(ChatMessage(
          id: 'user-$i',
          sessionId: 'test-session',
          role: MessageRole.user,
          content: [MessageContent(type: ContentType.text, text: 'Message $i')],
          timestamp: DateTime.now(),
        ));
        messages.add(ChatMessage(
          id: 'assistant-$i',
          sessionId: 'test-session',
          role: MessageRole.assistant,
          content: [MessageContent(type: ContentType.text, text: i % 3 == 0 ? _realMarkdownContent1 : i % 3 == 1 ? _realMarkdownContent2 : _realMarkdownContent3)],
          timestamp: DateTime.now(),
        ));
      }

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Navigator(
              onGenerateRoute: (settings) {
                return MaterialPageRoute(
                  builder: (context) => Scaffold(
                    appBar: AppBar(
                      leading: IconButton(
                        icon: Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    body: Column(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            itemCount: messages.length,
                            itemBuilder: (context, index) {
                              return MessageBubble(
                                message: messages[index],
                                vaultPath: '/tmp/test',
                              );
                            },
                          ),
                        ),
                        ChatInput(
                          onSend: (text, attachments) {},
                          enabled: true,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      print('Large chat with ${messages.length} messages rendered');

      // Rapid scrolling
      for (int i = 0; i < 5; i++) {
        await tester.drag(find.byType(ListView), const Offset(0, -1000));
        await tester.pump(); // Don't wait for settle - simulate rapid scrolling
      }
      print('Rapid scrolling done');

      // Immediately exit while things may still be building
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      print('Exit during scroll complete');
    });
  });
}
