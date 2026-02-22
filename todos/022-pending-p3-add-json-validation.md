---
status: pending
priority: p3
issue_id: 100
tags: [code-review, data-validation, robustness]
dependencies: []
---

# Missing JSON Validation: No Schema Validation for API Responses

## Problem Statement

API responses are parsed directly from JSON without validation. Malformed or unexpected JSON structure can cause crashes instead of graceful error handling. No runtime verification that responses match expected schema.

**Impact**: Minor. App crashes on malformed API responses instead of showing user-friendly errors. Difficult to debug when backend returns unexpected data.

## Findings

**Source**: architecture-strategist agent
**Confidence**: 68
**Locations**:
- `app/lib/features/brain_v2/models/brain_v2_entity.dart`
- `app/lib/features/brain_v2/models/brain_v2_schema.dart`
- `app/lib/features/brain_v2/models/brain_v2_field.dart`

**Evidence**:
```dart
// brain_v2_entity.dart - No validation
factory BrainV2Entity.fromJson(Map<String, dynamic> json) {
  return BrainV2Entity(
    id: json['@id'] as String,  // ← Can throw if missing or wrong type
    type: json['@type'] as String,  // ← Can throw
    fields: json['fields'] as Map<String, dynamic>? ?? {},
    tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? [],  // ← Can throw on cast
  );
}
```

**Failure Scenarios**:
1. Backend returns `{@id: 123}` (number instead of string) → crash
2. Backend returns `{fields: null}` → okay (handles with ??)
3. Backend returns `{tags: ["a", 1, "b"]}` (mixed types) → crash on cast
4. Backend returns malformed JSON → crash before fromJson

## Proposed Solutions

### Option 1: Add freezed with json_serializable (Recommended)
**Implementation**:

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'brain_v2_entity.freezed.dart';
part 'brain_v2_entity.g.dart';

@freezed
class BrainV2Entity with _$BrainV2Entity {
  const factory BrainV2Entity({
    @JsonKey(name: '@id') required String id,
    @JsonKey(name: '@type') required String type,
    @Default({}) Map<String, dynamic> fields,
    @Default([]) List<String> tags,
  }) = _BrainV2Entity;

  factory BrainV2Entity.fromJson(Map<String, dynamic> json) =>
      _$BrainV2EntityFromJson(json);
}
```

Run code generation:
```bash
flutter pub run build_runner build
```

**Pros**:
- Type-safe JSON parsing
- Automatic validation
- Immutable data classes
- Better error messages
- Industry standard

**Cons**:
- Code generation required
- Learning curve
- More dependencies

**Effort**: Medium (4-5 hours for all models)
**Risk**: Low

### Option 2: Manual validation in fromJson
**Implementation**:
```dart
factory BrainV2Entity.fromJson(Map<String, dynamic> json) {
  // Validate required fields
  if (!json.containsKey('@id') || json['@id'] is! String) {
    throw FormatException('Invalid or missing @id field');
  }
  if (!json.containsKey('@type') || json['@type'] is! String) {
    throw FormatException('Invalid or missing @type field');
  }

  // Validate optional fields
  final fields = json['fields'];
  if (fields != null && fields is! Map) {
    throw FormatException('Invalid fields format');
  }

  final tags = json['tags'];
  final tagsList = <String>[];
  if (tags != null) {
    if (tags is! List) {
      throw FormatException('Invalid tags format');
    }
    for (final tag in tags) {
      if (tag is String) {
        tagsList.add(tag);
      }
    }
  }

  return BrainV2Entity(
    id: json['@id'] as String,
    type: json['@type'] as String,
    fields: (fields as Map<String, dynamic>?) ?? {},
    tags: tagsList,
  );
}
```

**Pros**:
- No dependencies
- Full control
- Clear error messages

**Cons**:
- Verbose
- Easy to miss edge cases
- Manual maintenance

**Effort**: Medium (3-4 hours)
**Risk**: Low

### Option 3: Use json_schema validator
**Implementation**: Validate against JSON Schema before parsing

**Pros**:
- Declarative validation
- Reusable schemas

**Cons**:
- Additional dependency
- Complex setup
- Overkill for simple models

**Effort**: Large (5+ hours)
**Risk**: Medium

## Recommended Action

*To be filled during triage*

## Technical Details

**Affected Files**:
- `app/lib/features/brain_v2/models/brain_v2_entity.dart`
- `app/lib/features/brain_v2/models/brain_v2_schema.dart`
- `app/lib/features/brain_v2/models/brain_v2_field.dart`
- `app/pubspec.yaml` (add freezed if using Option 1)

**Dependencies for Option 1**:
```yaml
dependencies:
  freezed_annotation: ^2.4.1
  json_annotation: ^4.8.1

dev_dependencies:
  build_runner: ^2.4.6
  freezed: ^2.4.5
  json_serializable: ^6.7.1
```

**Error Handling**:
```dart
try {
  final entity = BrainV2Entity.fromJson(json);
} on FormatException catch (e) {
  print('Invalid JSON structure: $e');
  // Show user-friendly error
} on TypeError catch (e) {
  print('Type mismatch: $e');
  // Show user-friendly error
}
```

**Database Changes**: None

**API Changes**: None

## Acceptance Criteria

- [ ] All model classes validate JSON structure
- [ ] Missing required fields throw FormatException
- [ ] Wrong type fields throw FormatException
- [ ] Optional fields handle null/missing gracefully
- [ ] Type mismatches caught and reported
- [ ] Unit tests for invalid JSON inputs
- [ ] User sees friendly error instead of crash

## Work Log

### 2026-02-22
- **Action**: Identified during /para-review code review
- **Finding**: No JSON validation in model classes
- **Source**: architecture-strategist agent (confidence: 68)

## Resources

- **PR**: #100 - Brain v2 Flutter UI
- **Freezed**: https://pub.dev/packages/freezed
- **JSON Serializable**: https://pub.dev/packages/json_serializable
- **Best Practice**: Always validate external data
