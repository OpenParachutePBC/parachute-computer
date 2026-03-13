import 'package:flutter_test/flutter_test.dart';
import 'package:parachute/features/chat/models/stream_event.dart';
import 'package:parachute/features/chat/models/typed_error.dart';

void main() {
  group('StreamEvent.parse', () {
    test('returns null for non-data lines', () {
      expect(StreamEvent.parse(''), isNull);
      expect(StreamEvent.parse('event: ping'), isNull);
      expect(StreamEvent.parse(':comment'), isNull);
    });

    test('parses [DONE] sentinel as done event', () {
      final event = StreamEvent.parse('data: [DONE]');
      expect(event, isNotNull);
      expect(event!.type, StreamEventType.done);
      expect(event.data, isEmpty);
    });

    test('parses empty data payload as done event', () {
      final event = StreamEvent.parse('data: ');
      expect(event, isNotNull);
      expect(event!.type, StreamEventType.done);
    });

    test('parses session event', () {
      final event = StreamEvent.parse(
        'data: {"type":"session","sessionId":"abc123","trustLevel":"full","title":"Test Chat"}',
      );
      expect(event, isNotNull);
      expect(event!.type, StreamEventType.session);
      expect(event.sessionId, 'abc123');
      expect(event.trustLevel, 'full');
      expect(event.sessionTitle, 'Test Chat');
    });

    test('parses prompt_metadata event', () {
      final event = StreamEvent.parse(
        'data: {"type":"prompt_metadata","promptSource":"module","promptSourcePath":"Chat/CLAUDE.md","contextFiles":["a.md","b.md"],"contextTokens":500,"contextTruncated":false,"agentName":"default","availableAgents":["research"],"basePromptTokens":100,"totalPromptTokens":600,"trustMode":true}',
      );
      expect(event, isNotNull);
      expect(event!.type, StreamEventType.promptMetadata);
      expect(event.promptSource, 'module');
      expect(event.promptSourcePath, 'Chat/CLAUDE.md');
      expect(event.contextFiles, ['a.md', 'b.md']);
      expect(event.contextTokens, 500);
      expect(event.contextTruncated, isFalse);
      expect(event.agentName, 'default');
      expect(event.availableAgents, ['research']);
      expect(event.basePromptTokens, 100);
      expect(event.totalPromptTokens, 600);
      expect(event.trustMode, isTrue);
    });

    test('parses user_message event', () {
      final event = StreamEvent.parse(
        'data: {"type":"user_message","content":"Hello world"}',
      );
      expect(event!.type, StreamEventType.userMessage);
      expect(event.userMessageContent, 'Hello world');
    });

    test('parses text event', () {
      final event = StreamEvent.parse(
        'data: {"type":"text","content":"Hello from AI"}',
      );
      expect(event!.type, StreamEventType.text);
      expect(event.textContent, 'Hello from AI');
    });

    test('parses thinking event', () {
      final event = StreamEvent.parse(
        'data: {"type":"thinking","content":"Let me think..."}',
      );
      expect(event!.type, StreamEventType.thinking);
      expect(event.thinkingContent, 'Let me think...');
    });

    test('parses tool_use event', () {
      final event = StreamEvent.parse(
        'data: {"type":"tool_use","tool":{"id":"t1","name":"Read","input":{"file_path":"/foo.txt"}}}',
      );
      expect(event!.type, StreamEventType.toolUse);
      expect(event.toolCall, isNotNull);
      expect(event.toolCall!.id, 't1');
      expect(event.toolCall!.name, 'Read');
      expect(event.toolCall!.input['file_path'], '/foo.txt');
    });

    test('parses tool_result event', () {
      final event = StreamEvent.parse(
        'data: {"type":"tool_result","toolUseId":"t1","content":"file contents","isError":false}',
      );
      expect(event!.type, StreamEventType.toolResult);
      expect(event.toolUseId, 't1');
      expect(event.toolResultContent, 'file contents');
      expect(event.toolResultIsError, isFalse);
    });

    test('parses tool_result error event', () {
      final event = StreamEvent.parse(
        'data: {"type":"tool_result","toolUseId":"t2","content":"not found","isError":true}',
      );
      expect(event!.toolResultIsError, isTrue);
    });

    test('parses model event', () {
      final event = StreamEvent.parse(
        'data: {"type":"model","model":"claude-sonnet-4-20250514"}',
      );
      expect(event!.type, StreamEventType.model);
      expect(event.model, 'claude-sonnet-4-20250514');
    });

    test('parses done event with duration and model', () {
      final event = StreamEvent.parse(
        'data: {"type":"done","model":"claude-sonnet-4-20250514","durationMs":1234,"title":"Chat Title"}',
      );
      expect(event!.type, StreamEventType.done);
      expect(event.model, 'claude-sonnet-4-20250514');
      expect(event.durationMs, 1234);
      expect(event.sessionTitle, 'Chat Title');
    });

    test('parses error event', () {
      final event = StreamEvent.parse(
        'data: {"type":"error","error":"Something went wrong"}',
      );
      expect(event!.type, StreamEventType.error);
      expect(event.errorMessage, 'Something went wrong');
    });

    test('parses warning event', () {
      final event = StreamEvent.parse(
        'data: {"type":"warning","content":"Rate limit approaching"}',
      );
      expect(event!.type, StreamEventType.warning);
      expect(event.textContent, 'Rate limit approaching');
    });

    test('parses user_question event', () {
      final event = StreamEvent.parse(
        'data: {"type":"user_question","requestId":"req1","questions":[{"question":"Which?","header":"Choice","options":[{"label":"A","description":"Option A"}],"multiSelect":false}]}',
      );
      expect(event!.type, StreamEventType.userQuestion);
      expect(event.questionRequestId, 'req1');
      expect(event.questions, hasLength(1));
      expect(event.questions.first['question'], 'Which?');
    });

    test('parses session_unavailable event', () {
      final event = StreamEvent.parse(
        'data: {"type":"session_unavailable","reason":"sdk_session_not_found","hasMarkdownHistory":true,"messageCount":5,"message":"Session expired"}',
      );
      expect(event!.type, StreamEventType.sessionUnavailable);
      expect(event.unavailableReason, 'sdk_session_not_found');
      expect(event.hasMarkdownHistory, isTrue);
      expect(event.markdownMessageCount, 5);
      expect(event.unavailableMessage, 'Session expired');
    });

    test('parses aborted event', () {
      final event = StreamEvent.parse(
        'data: {"type":"aborted","message":"User cancelled"}',
      );
      expect(event!.type, StreamEventType.aborted);
      expect(event.abortedMessage, 'User cancelled');
    });

    test('parses typed_error event', () {
      final event = StreamEvent.parse(
        'data: {"type":"typed_error","code":"rate_limited","title":"Rate Limited","message":"Too many requests","canRetry":true,"retryDelayMs":5000}',
      );
      expect(event!.type, StreamEventType.typedError);
      expect(event.typedError, isNotNull);
      expect(event.typedError!.code, ErrorCode.rateLimited);
      expect(event.typedError!.title, 'Rate Limited');
      expect(event.canRetry, isTrue);
      expect(event.retryDelayMs, 5000);
    });

    test('maps unknown type to StreamEventType.unknown', () {
      final event = StreamEvent.parse(
        'data: {"type":"rate_limit_event","content":"slow down"}',
      );
      expect(event!.type, StreamEventType.unknown);
    });

    test('maps missing type field to unknown', () {
      final event = StreamEvent.parse('data: {"content":"no type"}');
      expect(event!.type, StreamEventType.unknown);
    });

    test('returns error event for malformed JSON', () {
      final event = StreamEvent.parse('data: {not valid json');
      expect(event, isNotNull);
      expect(event!.type, StreamEventType.error);
      expect(event.data['raw'], '{not valid json');
    });

    test('session resume info parsing', () {
      final event = StreamEvent.parse(
        'data: {"type":"session","sessionId":"s1","sessionResume":{"sdkSessionId":"sdk1","transcript":[]}}',
      );
      expect(event!.sessionResumeInfo, isNotNull);
    });

    // Accessor defaults
    test('accessors return safe defaults for missing fields', () {
      final event = StreamEvent.parse('data: {"type":"text"}');
      expect(event!.sessionId, isNull);
      expect(event.trustLevel, isNull);
      expect(event.textContent, isNull);
      expect(event.model, isNull);
      expect(event.durationMs, isNull);
      expect(event.toolCall, isNull);
      expect(event.errorMessage, isNull);
      expect(event.toolUseId, isNull);
      expect(event.toolResultContent, isNull);
      expect(event.toolResultIsError, isFalse);
      expect(event.hasMarkdownHistory, isFalse);
      expect(event.markdownMessageCount, 0);
      expect(event.contextFiles, isEmpty);
      expect(event.contextTokens, 0);
      expect(event.contextTruncated, isFalse);
      expect(event.availableAgents, isEmpty);
      expect(event.basePromptTokens, 0);
      expect(event.totalPromptTokens, 0);
      expect(event.trustMode, isTrue); // defaults to true
      expect(event.questions, isEmpty);
    });

    test('canRetry is false for non-typed errors', () {
      final event = StreamEvent.parse(
        'data: {"type":"error","error":"plain error"}',
      );
      expect(event!.canRetry, isFalse);
      expect(event.retryDelayMs, isNull);
    });
  });
}
