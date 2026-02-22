---
status: pending
priority: p2
issue_id: 100
tags: [code-review, configuration, deployment]
dependencies: []
---

# Hardcoded Localhost: No Configuration for Server URL

## Problem Statement

The server baseUrl is hardcoded to `http://localhost:3333` in the provider definition. This prevents deployment to production, testing against staging servers, or running on physical devices that can't access localhost.

**Impact**: App cannot connect to remote servers. Physical device testing requires code changes and recompilation. No environment-based configuration (dev/staging/prod).

## Findings

**Source**: architecture-strategist agent
**Confidence**: 85
**Location**: `app/lib/features/brain_v2/providers/brain_v2_providers.dart:15`

**Evidence**:
```dart
// Line 15 - Hardcoded localhost
final brainV2ServiceProvider = Provider<BrainV2Service?>((ref) {
  return BrainV2Service(baseUrl: 'http://localhost:3333');  // ← Hardcoded!
});
```

**Problems**:
- Cannot test on physical devices (localhost ≠ host machine)
- Cannot deploy to production
- Cannot switch between dev/staging/prod
- Requires code change + recompile for each environment

## Proposed Solutions

### Option 1: Environment-based configuration (Recommended)
**Implementation**:

```dart
// lib/core/config/app_config.dart
class AppConfig {
  static String get serverBaseUrl {
    const String? envUrl = String.fromEnvironment('SERVER_URL');
    if (envUrl != null && envUrl.isNotEmpty) {
      return envUrl;
    }

    // Default based on platform
    if (kDebugMode) {
      // In debug mode, use localhost
      if (Platform.isAndroid) {
        return 'http://10.0.2.2:3333';  // Android emulator host
      } else if (Platform.isIOS) {
        return 'http://localhost:3333';  // iOS simulator
      } else {
        return 'http://localhost:3333';  // Desktop
      }
    }

    // Production default
    return 'https://api.parachute.computer';
  }
}

// In provider
final brainV2ServiceProvider = Provider<BrainV2Service?>((ref) {
  return BrainV2Service(baseUrl: AppConfig.serverBaseUrl);
});
```

Build with environment variable:
```bash
flutter run --dart-define=SERVER_URL=http://192.168.1.100:3333
flutter build apk --dart-define=SERVER_URL=https://api.parachute.computer
```

**Pros**:
- Supports all environments (dev/staging/prod)
- No code changes needed
- Can override at build time
- Platform-specific defaults

**Cons**:
- Requires build-time configuration

**Effort**: Medium (2-3 hours)
**Risk**: Low

### Option 2: Runtime configuration with settings screen
**Implementation**:

```dart
// Add settings provider
final serverUrlProvider = StateProvider<String>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return prefs.getString('server_url') ?? AppConfig.defaultServerUrl;
});

// Settings screen
class ServerSettingsScreen extends ConsumerWidget {
  Widget build(context, ref) {
    return TextField(
      initialValue: ref.watch(serverUrlProvider),
      onSubmitted: (value) {
        ref.read(serverUrlProvider.notifier).state = value;
        // Save to SharedPreferences
      },
    );
  }
}
```

**Pros**:
- User can change server without rebuild
- Useful for testing
- No build configuration

**Cons**:
- Requires UI for settings
- User must know server URL
- More complex

**Effort**: Large (4-5 hours)
**Risk**: Low

### Option 3: Auto-discovery with mDNS
**Implementation**: Use Bonjour/mDNS to discover local server

**Pros**:
- No configuration needed
- Automatic local server discovery

**Cons**:
- Complex implementation
- Doesn't work for remote servers
- Overkill for current needs

**Effort**: Large (6+ hours)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- Create: `app/lib/core/config/app_config.dart`
- Modify: `app/lib/features/brain_v2/providers/brain_v2_providers.dart` (line 15)
- Modify: All other module providers (chat, daily, etc.) for consistency

**Environment Examples**:
```bash
# Development - local server
flutter run

# Development - physical device testing
flutter run --dart-define=SERVER_URL=http://192.168.1.100:3333

# Staging
flutter build apk --dart-define=SERVER_URL=https://staging-api.parachute.computer

# Production
flutter build apk --dart-define=SERVER_URL=https://api.parachute.computer
```

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] Server URL uses AppConfig instead of hardcoded string
- [ ] Default URL works for iOS simulator, Android emulator, and desktop
- [ ] Can override URL with --dart-define at build time
- [ ] Different builds can target different servers without code changes
- [ ] Manual test: Flutter run on Android emulator → connects to local server
- [ ] Manual test: Build with custom SERVER_URL → connects to specified server

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: Hardcoded localhost URL prevents deployment
- **Source**: architecture-strategist agent (confidence: 85)
- **Pattern**: Common configuration issue in Flutter apps

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Flutter Environment**: https://docs.flutter.dev/deployment/flavors
- **Dart Define**: https://dartcode.org/docs/using-dart-define-in-flutter/
- **Android Emulator**: `10.0.2.2` is special IP for host machine
