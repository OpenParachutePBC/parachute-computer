import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:parachute/features/chat/models/chat_message.dart';
import 'package:parachute/features/chat/models/prompt_metadata.dart';
import 'package:parachute/features/chat/models/stream_event.dart';
import 'package:parachute/features/chat/providers/chat_stream_event_processor.dart';

void main() {
  // Test helpers
  late ChatStreamEventProcessor processor;
  late List<List<MessageContent>> updateCalls;
  late List<bool> updateStreamingFlags;
  late List<bool?> updateImmediateFlags;
  late int flushCallCount;

  PromptMetadata stubBuildMetadata(StreamEvent event) {
    return PromptMetadata(
      promptSource: event.promptSource ?? 'default',
      contextFiles: event.contextFiles,
      contextTokens: event.contextTokens,
    );
  }

  setUp(() {
    updateCalls = [];
    updateStreamingFlags = [];
    updateImmediateFlags = [];
    flushCallCount = 0;

    processor = ChatStreamEventProcessor(
      onUpdate: (content, {required bool isStreaming, bool immediate = false}) {
        // Deep copy the content list to snapshot it
        updateCalls.add(List.of(content));
        updateStreamingFlags.add(isStreaming);
        updateImmediateFlags.add(immediate);
      },
      onFlush: () => flushCallCount++,
      buildPromptMetadata: stubBuildMetadata,
    );
  });

  /// Create a StreamEvent with properly typed nested maps.
  /// Uses JSON round-trip to normalize Map<dynamic, dynamic> → Map<String, dynamic>,
  /// matching what jsonDecode produces in real SSE parsing.
  StreamEvent makeEvent(String type, [Map<String, dynamic> extra = const {}]) {
    final rawData = {'type': type, ...extra};
    final normalized = jsonDecode(jsonEncode(rawData)) as Map<String, dynamic>;
    return StreamEvent(
      type: StreamEventType.values.firstWhere(
        (e) => e.name == type,
        orElse: () => StreamEventType.unknown,
      ),
      data: normalized,
    );
  }

  group('ChatStreamEventProcessor', () {
    group('handles()', () {
      test('returns true for processor-handled event types', () {
        expect(processor.handles(StreamEventType.text), isTrue);
        expect(processor.handles(StreamEventType.toolUse), isTrue);
        expect(processor.handles(StreamEventType.toolResult), isTrue);
        expect(processor.handles(StreamEventType.thinking), isTrue);
        expect(processor.handles(StreamEventType.warning), isTrue);
        expect(processor.handles(StreamEventType.model), isTrue);
        expect(processor.handles(StreamEventType.promptMetadata), isTrue);
      });

      test('returns false for terminal/path-specific events', () {
        expect(processor.handles(StreamEventType.done), isFalse);
        expect(processor.handles(StreamEventType.error), isFalse);
        expect(processor.handles(StreamEventType.session), isFalse);
        expect(processor.handles(StreamEventType.userMessage), isFalse);
        expect(processor.handles(StreamEventType.userQuestion), isFalse);
        expect(processor.handles(StreamEventType.aborted), isFalse);
        expect(processor.handles(StreamEventType.sessionUnavailable), isFalse);
        expect(processor.handles(StreamEventType.typedError), isFalse);
        expect(processor.handles(StreamEventType.unknown), isFalse);
      });
    });

    group('text events', () {
      test('adds text content on first text event', () {
        final patch = processor.processEvent(
          makeEvent('text', {'content': 'Hello'}),
        );
        expect(patch, isNull);
        expect(processor.content, hasLength(1));
        expect(processor.content[0].type, ContentType.text);
        expect(processor.content[0].text, 'Hello');
        expect(updateCalls, hasLength(1));
        expect(updateStreamingFlags.last, isTrue);
      });

      test('replaces last text block (server sends accumulated text)', () {
        processor.processEvent(makeEvent('text', {'content': 'Hel'}));
        processor.processEvent(makeEvent('text', {'content': 'Hello world'}));

        expect(processor.content, hasLength(1));
        expect(processor.content[0].text, 'Hello world');
        expect(updateCalls, hasLength(2));
      });

      test('ignores null content', () {
        processor.processEvent(makeEvent('text', {}));
        expect(processor.content, isEmpty);
        expect(updateCalls, isEmpty);
      });
    });

    group('thinking events', () {
      test('appends thinking content', () {
        processor.processEvent(makeEvent('thinking', {'content': 'Let me think'}));

        expect(processor.content, hasLength(1));
        expect(processor.content[0].type, ContentType.thinking);
        expect(processor.content[0].text, 'Let me think');
      });

      test('ignores empty thinking content', () {
        processor.processEvent(makeEvent('thinking', {'content': ''}));
        expect(processor.content, isEmpty);
      });

      test('ignores null thinking content', () {
        processor.processEvent(makeEvent('thinking', {}));
        expect(processor.content, isEmpty);
      });
    });

    group('toolUse events', () {
      test('adds tool use content', () {
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't1', 'name': 'Read', 'input': {'file_path': '/test.txt'}},
        }));

        expect(processor.content, hasLength(1));
        expect(processor.content[0].type, ContentType.toolUse);
        expect(processor.content[0].toolCall!.name, 'Read');
      });

      test('flushes pending updates before tool call', () {
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't1', 'name': 'Read', 'input': {}},
        }));
        expect(flushCallCount, 1);
      });

      test('sends update with immediate flag', () {
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't1', 'name': 'Read', 'input': {}},
        }));
        expect(updateImmediateFlags.last, isTrue);
      });

      test('converts pending text to thinking before tool call', () {
        // First add some text
        processor.processEvent(makeEvent('text', {'content': 'Let me check that file'}));
        expect(processor.content[0].type, ContentType.text);

        // Then a tool use arrives — text should become thinking
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't1', 'name': 'Read', 'input': {}},
        }));

        expect(processor.content, hasLength(2));
        expect(processor.content[0].type, ContentType.thinking);
        expect(processor.content[0].text, 'Let me check that file');
        expect(processor.content[1].type, ContentType.toolUse);
      });

      test('does not convert empty text to thinking', () {
        // Add text then clear it
        processor.content.add(MessageContent.text(''));

        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't1', 'name': 'Read', 'input': {}},
        }));

        // Empty text should remain as text (not converted)
        expect(processor.content[0].type, ContentType.text);
      });

      test('ignores null tool call', () {
        processor.processEvent(makeEvent('toolUse', {}));
        // Flush still called, but no content added
        expect(flushCallCount, 1);
        expect(processor.content, isEmpty);
      });
    });

    group('toolResult events', () {
      test('attaches result to matching tool call', () {
        // First add a tool call
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't1', 'name': 'Read', 'input': {}},
        }));
        final beforeUpdateCount = updateCalls.length;

        // Then attach the result
        processor.processEvent(makeEvent('toolResult', {
          'toolUseId': 't1',
          'content': 'file contents here',
          'isError': false,
        }));

        expect(updateCalls.length, beforeUpdateCount + 1);
        final toolContent = processor.content.firstWhere(
          (c) => c.type == ContentType.toolUse,
        );
        expect(toolContent.toolCall!.result, 'file contents here');
        expect(toolContent.toolCall!.isError, isFalse);
      });

      test('marks error results', () {
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't2', 'name': 'Bash', 'input': {}},
        }));
        processor.processEvent(makeEvent('toolResult', {
          'toolUseId': 't2',
          'content': 'command not found',
          'isError': true,
        }));

        final toolContent = processor.content.firstWhere(
          (c) => c.type == ContentType.toolUse,
        );
        expect(toolContent.toolCall!.isError, isTrue);
      });

      test('ignores result for unknown tool ID', () {
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't1', 'name': 'Read', 'input': {}},
        }));
        final beforeUpdateCount = updateCalls.length;

        processor.processEvent(makeEvent('toolResult', {
          'toolUseId': 'nonexistent',
          'content': 'orphan result',
        }));

        // No update should have been called
        expect(updateCalls.length, beforeUpdateCount);
      });

      test('ignores result with null fields', () {
        final beforeUpdateCount = updateCalls.length;
        processor.processEvent(makeEvent('toolResult', {}));
        expect(updateCalls.length, beforeUpdateCount);
      });
    });

    group('warning events', () {
      test('formats warning with title and message', () {
        processor.processEvent(makeEvent('warning', {
          'title': 'Rate Limit',
          'message': 'Approaching limit',
        }));

        expect(processor.content, hasLength(1));
        expect(processor.content[0].type, ContentType.warning);
        expect(processor.content[0].text, 'Rate Limit: Approaching limit');
      });

      test('formats warning with details list', () {
        processor.processEvent(makeEvent('warning', {
          'title': 'Issues',
          'message': 'Found problems',
          'details': ['Problem 1', 'Problem 2'],
        }));

        final text = processor.content[0].text!;
        expect(text, contains('Issues: Found problems'));
        expect(text, contains('  - Problem 1'));
        expect(text, contains('  - Problem 2'));
      });

      test('uses defaults for missing title/message', () {
        processor.processEvent(makeEvent('warning', {}));

        expect(processor.content[0].text, 'Warning: ');
      });
    });

    group('model events', () {
      test('returns patch with model name', () {
        final patch = processor.processEvent(
          makeEvent('model', {'model': 'claude-sonnet-4-20250514'}),
        );

        expect(patch, isNotNull);
        expect(patch!.model, 'claude-sonnet-4-20250514');
        expect(patch.promptMetadata, isNull);
        // No content added
        expect(processor.content, isEmpty);
      });
    });

    group('promptMetadata events', () {
      test('returns patch with metadata via callback', () {
        final patch = processor.processEvent(
          makeEvent('promptMetadata', {
            'promptSource': 'module',
            'contextFiles': ['a.md'],
            'contextTokens': 100,
          }),
        );

        expect(patch, isNotNull);
        expect(patch!.promptMetadata, isNotNull);
        expect(patch.promptMetadata!.promptSource, 'module');
        expect(patch.promptMetadata!.contextFiles, ['a.md']);
        expect(patch.model, isNull);
      });
    });

    group('unhandled events', () {
      test('returns null for terminal events', () {
        expect(processor.processEvent(makeEvent('done', {})), isNull);
        expect(processor.processEvent(makeEvent('error', {})), isNull);
        expect(processor.processEvent(makeEvent('session', {})), isNull);
        expect(processor.content, isEmpty);
        expect(updateCalls, isEmpty);
      });
    });

    group('reset()', () {
      test('clears accumulated content', () {
        processor.processEvent(makeEvent('text', {'content': 'Hello'}));
        processor.processEvent(makeEvent('thinking', {'content': 'hmm'}));
        expect(processor.content, hasLength(2));

        processor.reset();
        expect(processor.content, isEmpty);
      });
    });

    group('complex sequences', () {
      test('text → toolUse → toolResult → text flow', () {
        // AI thinks out loud
        processor.processEvent(makeEvent('text', {'content': 'Let me read the file'}));
        expect(processor.content.last.type, ContentType.text);

        // Tool call — text becomes thinking
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't1', 'name': 'Read', 'input': {'file_path': '/a.dart'}},
        }));
        expect(processor.content[0].type, ContentType.thinking);
        expect(processor.content[1].type, ContentType.toolUse);

        // Tool result arrives
        processor.processEvent(makeEvent('toolResult', {
          'toolUseId': 't1',
          'content': 'class Foo {}',
          'isError': false,
        }));
        expect(processor.content[1].toolCall!.result, 'class Foo {}');

        // AI continues with text
        processor.processEvent(makeEvent('text', {'content': 'I found the class'}));
        expect(processor.content, hasLength(3));
        expect(processor.content[2].type, ContentType.text);
        expect(processor.content[2].text, 'I found the class');
      });

      test('multiple tool calls in sequence', () {
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't1', 'name': 'Read', 'input': {}},
        }));
        processor.processEvent(makeEvent('toolResult', {
          'toolUseId': 't1',
          'content': 'result 1',
        }));
        processor.processEvent(makeEvent('toolUse', {
          'tool': {'id': 't2', 'name': 'Bash', 'input': {}},
        }));
        processor.processEvent(makeEvent('toolResult', {
          'toolUseId': 't2',
          'content': 'result 2',
        }));

        expect(processor.content, hasLength(2));
        expect(processor.content[0].toolCall!.id, 't1');
        expect(processor.content[0].toolCall!.result, 'result 1');
        expect(processor.content[1].toolCall!.id, 't2');
        expect(processor.content[1].toolCall!.result, 'result 2');
      });
    });
  });
}
