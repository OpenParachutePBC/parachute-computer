---
status: pending
priority: p1
issue_id: 100
tags: [code-review, flutter, memory-leak, resources]
dependencies: []
---

# Missing HTTP Client Disposal: Resource Leak

## Problem Statement

The `BrainV2Service` creates an `http.Client()` but never disposes of it. HTTP clients hold open connections, internal buffers, and system resources that must be explicitly released. Without disposal, these resources leak with each service instance.

**Impact**: Connection pool exhaustion, memory leaks, and potential "too many open files" errors on long-running app sessions. Each provider instance creates a new service with a new undisposed client.

## Findings

**Source**: flutter-reviewer agent
**Confidence**: 90
**Location**: `app/lib/features/brain_v2/services/brain_v2_service.dart:14-15`

**Evidence**:
```dart
class BrainV2Service {
  final String baseUrl;
  final http.Client client = http.Client();  // ← Created but never disposed

  BrainV2Service({required this.baseUrl});
  // No dispose() method
}
```

**Resource Leak**:
- Each service instance = new HTTP client
- HTTP client maintains connection pool
- No cleanup when service no longer needed
- Provider instances × HTTP clients = compounding leak

## Proposed Solutions

### Option 1: Add dispose method to service (Recommended)
**Implementation**:
```dart
class BrainV2Service {
  final String baseUrl;
  final http.Client client = http.Client();

  BrainV2Service({required this.baseUrl});

  void dispose() {
    client.close();
  }

  // All methods unchanged
}

// In provider (brain_v2_providers.dart)
final brainV2ServiceProvider = Provider<BrainV2Service?>((ref) {
  final service = BrainV2Service(baseUrl: 'http://localhost:3333');
  ref.onDispose(() => service.dispose());
  return service;
});
```

**Pros**:
- Explicit resource management
- Provider handles disposal automatically
- Standard Dart pattern
- No behavior changes

**Cons**: None

**Effort**: Small (10 minutes)
**Risk**: Very Low

### Option 2: Use Provider.autoDispose with ref.onDispose
**Implementation**:
```dart
final brainV2ServiceProvider = Provider.autoDispose<BrainV2Service>((ref) {
  final service = BrainV2Service(baseUrl: 'http://localhost:3333');
  ref.onDispose(() => service.client.close());
  return service;
});
```

**Pros**:
- Automatic cleanup when no watchers
- More aggressive resource management
- No service class changes

**Cons**:
- Service recreated more frequently
- May impact performance with frequent provider access

**Effort**: Small (5 minutes)
**Risk**: Low

### Option 3: Inject client externally
**Implementation**:
```dart
class BrainV2Service {
  final String baseUrl;
  final http.Client client;

  BrainV2Service({
    required this.baseUrl,
    required this.client,
  });
}

// Provider manages client lifecycle
final _httpClientProvider = Provider((ref) {
  final client = http.Client();
  ref.onDispose(() => client.close());
  return client;
});

final brainV2ServiceProvider = Provider<BrainV2Service>((ref) {
  final client = ref.watch(_httpClientProvider);
  return BrainV2Service(
    baseUrl: 'http://localhost:3333',
    client: client,
  );
});
```

**Pros**:
- Separation of concerns
- Client can be shared across services
- Testability (mock injection)

**Cons**:
- More complex setup
- Additional provider

**Effort**: Medium (20 minutes)
**Risk**: Low

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/services/brain_v2_service.dart` (lines 14-15, add dispose method)
- `app/lib/features/brain_v2/providers/brain_v2_providers.dart` (add ref.onDispose)

**Affected Components**:
- BrainV2Service (all HTTP operations)
- brainV2ServiceProvider
- All features using the service (entity list, detail, create, edit, delete)

**Resource Leak Details**:
- Each http.Client maintains:
  - Connection pool (default 6 connections)
  - Internal buffers
  - Socket handles
  - Timer for connection reuse

**Database Changes**: None

**API Changes**: None (internal only)

## Acceptance Criteria

- [ ] BrainV2Service has dispose() method that closes HTTP client
- [ ] Provider calls dispose via ref.onDispose callback
- [ ] No HTTP client resource leaks (verify with DevTools)
- [ ] All existing HTTP operations work unchanged
- [ ] Manual test: Navigate away from Brain v2 → verify client closed
- [ ] No "too many open files" errors during extended usage

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: HTTP client created but never disposed
- **Source**: flutter-reviewer agent (confidence: 90)
- **Pattern**: Common resource leak in Flutter services

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Related Issue**: #98 - Implement Brain v2 Flutter UI
- **Dart HTTP Docs**: https://pub.dev/documentation/http/latest/http/Client-class.html
- **Riverpod Disposal**: https://riverpod.dev/docs/concepts/provider_life_cycles
- **Location**: `brain_v2_service.dart:14-15`
