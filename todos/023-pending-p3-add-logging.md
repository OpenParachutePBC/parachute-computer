---
status: pending
priority: p3
issue_id: 100
tags: [code-review, observability, debugging]
dependencies: []
---

# Missing Logging: No Observability for Production Issues

## Problem Statement

Brain v2 UI has no structured logging. When errors occur in production, there's no way to diagnose issues. No visibility into API calls, state changes, or user actions. Debugging production issues requires reproducing locally.

**Impact**: Minor. Difficult to debug production issues. No metrics on API performance. No audit trail of user actions. Hard to identify patterns in errors.

## Findings

**Source**: pattern-recognition-specialist agent
**Confidence**: 65
**Evidence**:

No logging in:
- `brain_v2_service.dart` - API calls have no logging
- `brain_v2_providers.dart` - State changes unlogged
- `brain_v2_entity_form_screen.dart` - User actions unlogged
- Error handlers - Errors caught but not logged

**Example Missing Logs**:
```dart
// No logging for API calls
Future<BrainV2Entity?> getEntity(String id) async {
  final uri = Uri.parse('$baseUrl/api/brain_v2/entities/by_id')...;
  final response = await client.get(uri, headers: _headers);
  // ← Should log: "GET /api/brain_v2/entities/by_id?id=... → 200 (150ms)"

  if (response.statusCode == 200) {
    return BrainV2Entity.fromJson(jsonDecode(response.body));
    // ← Should log: "Parsed entity: {type: Person, id: ...}"
  }
  return null;  // ← Should log: "Entity not found: $id"
}

// No logging for errors
catch (e) {
  ScaffoldMessenger.of(context).showSnackBar(...);
  // ← Should log: "Failed to create entity: $e\n$stackTrace"
}
```

## Proposed Solutions

### Option 1: Add logger package with structured logging (Recommended)
**Implementation**:

```dart
// lib/core/logging/app_logger.dart
import 'package:logger/logger.dart';

class AppLogger {
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      printTime: true,
    ),
  );

  static void debug(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.d(message, error: error, stackTrace: stackTrace);
  }

  static void info(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.i(message, error: error, stackTrace: stackTrace);
  }

  static void warning(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.w(message, error: error, stackTrace: stackTrace);
  }

  static void error(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.e(message, error: error, stackTrace: stackTrace);
  }

  // API call logging
  static void apiCall(String method, String endpoint, int statusCode, int duration) {
    final emoji = statusCode >= 200 && statusCode < 300 ? '✅' : '❌';
    info('$emoji API $method $endpoint → $statusCode (${duration}ms)');
  }

  // User action logging
  static void userAction(String action, [Map<String, dynamic>? metadata]) {
    info('👤 User: $action', metadata);
  }
}

// Usage in service
Future<BrainV2Entity?> getEntity(String id) async {
  final stopwatch = Stopwatch()..start();
  final uri = Uri.parse('$baseUrl/api/brain_v2/entities/by_id')...;

  try {
    final response = await client.get(uri, headers: _headers);
    stopwatch.stop();

    AppLogger.apiCall('GET', '/api/brain_v2/entities/by_id', response.statusCode, stopwatch.elapsedMilliseconds);

    if (response.statusCode == 200) {
      final entity = BrainV2Entity.fromJson(jsonDecode(response.body));
      AppLogger.debug('Parsed entity: ${entity.id} (${entity.type})');
      return entity;
    }

    AppLogger.warning('Entity not found: $id (status: ${response.statusCode})');
    return null;
  } catch (e, stack) {
    stopwatch.stop();
    AppLogger.error('Failed to fetch entity $id', e, stack);
    rethrow;
  }
}

// Usage in screens
void _handleSubmit() async {
  AppLogger.userAction('Submit entity form', {
    'entity_type': widget.entityType,
    'is_edit_mode': _isEditMode,
  });

  try {
    // ... submit logic
    AppLogger.info('Entity submitted successfully');
  } catch (e, stack) {
    AppLogger.error('Submit failed', e, stack);
  }
}
```

**Pros**:
- Structured logging
- Production-ready
- Easy to integrate with monitoring (Sentry, Firebase Crashlytics)
- Valuable debugging info
- Performance tracking

**Cons**:
- Additional dependency
- Log noise if over-used

**Effort**: Medium (3-4 hours)
**Risk**: Very Low

### Option 2: Use print() only
**Implementation**: Add strategic print() statements

**Pros**:
- No dependency
- Simple

**Cons**:
- Not structured
- No log levels
- Stripped in release builds
- Unprofessional

**Effort**: Small (1-2 hours)
**Risk**: Low

### Option 3: Custom analytics/telemetry
**Implementation**: Send logs to backend for analytics

**Pros**:
- Production monitoring
- Aggregate insights

**Cons**:
- Complex setup
- Privacy concerns
- Overkill for current needs

**Effort**: Large (8+ hours)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- Create: `app/lib/core/logging/app_logger.dart`
- Modify: `app/lib/features/brain_v2/services/brain_v2_service.dart` (add API logs)
- Modify: All screens (add user action logs, error logs)
- Modify: `app/pubspec.yaml` (add logger dependency)

**Dependency**:
```yaml
dependencies:
  logger: ^2.0.2
```

**Log Levels**:
- **Debug**: Detailed info (entity parsing, state changes)
- **Info**: Normal operations (API calls, user actions)
- **Warning**: Unexpected but handled (entity not found, validation)
- **Error**: Failures (API errors, exceptions)

**Production Configuration**:
```dart
// Only log warnings and errors in release mode
Logger(
  level: kReleaseMode ? Level.warning : Level.debug,
);
```

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] Logger package added and configured
- [ ] All API calls logged with timing
- [ ] All user actions logged
- [ ] All errors logged with stack traces
- [ ] Log levels appropriate (debug/info/warning/error)
- [ ] Logs excluded from release builds (or sent to analytics)
- [ ] Manual test: Trigger error → log appears with context

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: No structured logging in Brain v2
- **Source**: pattern-recognition-specialist agent (confidence: 65)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Logger Package**: https://pub.dev/packages/logger
- **Best Practice**: https://docs.flutter.dev/testing/errors
- **Production Logging**: Consider Sentry, Firebase Crashlytics for production
