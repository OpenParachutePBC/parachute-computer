import 'package:flutter_test/flutter_test.dart';
import 'package:parachute/features/chat/models/chat_message.dart';

void main() {
  group('MessageContent factories', () {
    test('text creates text content', () {
      final content = MessageContent.text('hello');
      expect(content.type, ContentType.text);
      expect(content.text, 'hello');
      expect(content.toolCall, isNull);
    });

    test('thinking creates thinking content', () {
      final content = MessageContent.thinking('hmm');
      expect(content.type, ContentType.thinking);
      expect(content.text, 'hmm');
    });

    test('warning creates warning content', () {
      final content = MessageContent.warning('watch out');
      expect(content.type, ContentType.warning);
      expect(content.text, 'watch out');
    });

    test('toolUse creates tool use content', () {
      final tool = ToolCall(id: 't1', name: 'Read', input: {'file_path': '/a'});
      final content = MessageContent.toolUse(tool);
      expect(content.type, ContentType.toolUse);
      expect(content.toolCall!.name, 'Read');
    });

    test('userQuestion creates user question content', () {
      final data = UserQuestionData(
        toolUseId: 'q1',
        questions: [{'question': 'Which?'}],
      );
      final content = MessageContent.userQuestion(data);
      expect(content.type, ContentType.userQuestion);
      expect(content.userQuestionData!.toolUseId, 'q1');
    });
  });

  group('ToolCall', () {
    test('fromJson parses all fields', () {
      final tool = ToolCall.fromJson({
        'id': 't1',
        'name': 'Bash',
        'input': {'command': 'ls'},
        'result': 'file.txt',
        'isError': false,
      });
      expect(tool.id, 't1');
      expect(tool.name, 'Bash');
      expect(tool.input['command'], 'ls');
      expect(tool.result, 'file.txt');
      expect(tool.isError, isFalse);
    });

    test('fromJson with missing fields uses defaults', () {
      final tool = ToolCall.fromJson({});
      expect(tool.id, '');
      expect(tool.name, '');
      expect(tool.input, isEmpty);
      expect(tool.result, isNull);
      expect(tool.isError, isFalse);
    });

    test('withResult creates copy with result attached', () {
      final tool = ToolCall(id: 't1', name: 'Read', input: {});
      final withResult = tool.withResult('contents', isError: false);
      expect(withResult.id, 't1');
      expect(withResult.name, 'Read');
      expect(withResult.result, 'contents');
expect(withResult.isError, isFalse);
    });

    test('withResult preserves original and marks error', () {
      final tool = ToolCall(id: 't1', name: 'Bash', input: {'command': 'rm'});
      final withErr = tool.withResult('permission denied', isError: true);
      expect(withErr.isError, isTrue);
      expect(withErr.result, 'permission denied');
      expect(withErr.input['command'], 'rm');
    });

    group('summary', () {
      test('shows file_path for Read tool', () {
        final tool = ToolCall(id: '1', name: 'Read', input: {'file_path': '/foo.txt'});
        expect(tool.summary, '/foo.txt');
      });

      test('shows truncated command for Bash tool', () {
        final shortCmd = ToolCall(id: '1', name: 'Bash', input: {'command': 'ls -la'});
        expect(shortCmd.summary, 'ls -la');

        final longCmd = ToolCall(
          id: '1',
          name: 'Bash',
          input: {'command': 'a' * 60},
        );
        expect(longCmd.summary.length, 50);
        expect(longCmd.summary.endsWith('...'), isTrue);
      });

      test('shows pattern for Glob and Grep tools', () {
        final glob = ToolCall(id: '1', name: 'Glob', input: {'pattern': '**/*.dart'});
        expect(glob.summary, '**/*.dart');

        final grep = ToolCall(id: '1', name: 'Grep', input: {'pattern': 'TODO'});
        expect(grep.summary, 'TODO');
      });

      test('shows file_path for Write and Edit tools', () {
        final write = ToolCall(id: '1', name: 'Write', input: {'file_path': '/out.txt'});
        expect(write.summary, '/out.txt');

        final edit = ToolCall(id: '1', name: 'Edit', input: {'file_path': '/mod.txt'});
        expect(edit.summary, '/mod.txt');
      });

      test('falls back to common fields for unknown tools', () {
        final t = ToolCall(id: '1', name: 'CustomTool', input: {'query': 'search term'});
        expect(t.summary, 'search term');
      });

      test('returns empty string when no known fields', () {
        final t = ToolCall(id: '1', name: 'Unknown', input: {'foo': 'bar'});
        expect(t.summary, '');
      });
    });
  });

  group('ChatMessage.fromJson', () {
    test('parses string content', () {
      final msg = ChatMessage.fromJson({
        'id': 'msg1',
        'sessionId': 's1',
        'role': 'user',
        'content': 'Hello',
        'timestamp': '2024-01-01T00:00:00.000Z',
      });
      expect(msg.id, 'msg1');
      expect(msg.sessionId, 's1');
      expect(msg.role, MessageRole.user);
      expect(msg.textContent, 'Hello');
      expect(msg.isStreaming, isFalse);
      expect(msg.isCompactSummary, isFalse);
    });

    test('parses structured content blocks', () {
      final msg = ChatMessage.fromJson({
        'id': 'msg2',
        'sessionId': 's1',
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'text': 'Let me think...'},
          {'type': 'text', 'text': 'Here is the answer'},
          {
            'type': 'tool_use',
            'id': 't1',
            'name': 'Read',
            'input': {'file_path': '/test.dart'},
          },
        ],
        'timestamp': '2024-01-01T00:00:00.000Z',
      });
      expect(msg.content, hasLength(3));
      expect(msg.content[0].type, ContentType.thinking);
      expect(msg.content[0].text, 'Let me think...');
      expect(msg.content[1].type, ContentType.text);
      expect(msg.content[2].type, ContentType.toolUse);
      expect(msg.content[2].toolCall!.name, 'Read');
    });

    test('skips empty thinking blocks', () {
      final msg = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'text': ''},
          {'type': 'text', 'text': 'Answer'},
        ],
        'timestamp': '2024-01-01T00:00:00.000Z',
      });
      expect(msg.content, hasLength(1));
      expect(msg.content[0].type, ContentType.text);
    });

    test('skips unknown block types silently', () {
      final msg = ChatMessage.fromJson({
        'role': 'assistant',
        'content': [
          {'type': 'unknown_block', 'data': 'stuff'},
          {'type': 'text', 'text': 'Visible'},
        ],
        'timestamp': '2024-01-01T00:00:00.000Z',
      });
      expect(msg.content, hasLength(1));
      expect(msg.content[0].text, 'Visible');
    });

    test('handles string entries in content list', () {
      final msg = ChatMessage.fromJson({
        'role': 'user',
        'content': ['Hello', 'World'],
        'timestamp': '2024-01-01T00:00:00.000Z',
      });
      expect(msg.content, hasLength(2));
      expect(msg.textContent, 'HelloWorld');
    });

    test('generates id when missing', () {
      final msg = ChatMessage.fromJson({
        'role': 'user',
        'content': 'Test',
        'timestamp': '2024-01-01T00:00:00.000Z',
      });
      expect(msg.id, isNotEmpty);
    });

    test('uses current time when timestamp missing', () {
      final before = DateTime.now();
      final msg = ChatMessage.fromJson({
        'role': 'user',
        'content': 'Test',
      });
      expect(msg.timestamp.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
    });

    test('parses paraId and isCompactSummary', () {
      final msg = ChatMessage.fromJson({
        'id': 'msg3',
        'paraId': 'abc123def456',
        'role': 'assistant',
        'content': 'Summary',
        'timestamp': '2024-01-01T00:00:00.000Z',
        'isCompactSummary': true,
      });
      expect(msg.paraId, 'abc123def456');
      expect(msg.isCompactSummary, isTrue);
    });
  });

  group('ChatMessage constructors', () {
    test('user factory creates user message', () {
      final msg = ChatMessage.user(sessionId: 's1', text: 'Hi');
      expect(msg.role, MessageRole.user);
      expect(msg.sessionId, 's1');
      expect(msg.textContent, 'Hi');
      expect(msg.isStreaming, isFalse);
    });

    test('assistantPlaceholder creates streaming placeholder', () {
      final msg = ChatMessage.assistantPlaceholder(sessionId: 's1');
      expect(msg.role, MessageRole.assistant);
      expect(msg.isStreaming, isTrue);
      expect(msg.content, isEmpty);
      expect(msg.id, startsWith('streaming-'));
    });

    test('fromMarkdown creates message with para ID', () {
      final msg = ChatMessage.fromMarkdown(
        sessionId: 's1',
        role: MessageRole.assistant,
        text: 'Response text',
        timestamp: DateTime(2024, 1, 1),
        paraId: 'xyz789',
      );
      expect(msg.paraId, 'xyz789');
      expect(msg.id, 'xyz789'); // Uses paraId as id
      expect(msg.textContent, 'Response text');
    });
  });

  group('ChatMessage accessors', () {
    test('textContent concatenates all text blocks', () {
      final msg = ChatMessage(
        id: '1',
        sessionId: 's1',
        role: MessageRole.assistant,
        content: [
          MessageContent.thinking('thought'),
          MessageContent.text('Hello '),
          MessageContent.toolUse(ToolCall(id: 't1', name: 'Read', input: {})),
          MessageContent.text('World'),
        ],
        timestamp: DateTime.now(),
      );
      expect(msg.textContent, 'Hello World');
    });

    test('toolCalls returns all tool calls', () {
      final msg = ChatMessage(
        id: '1',
        sessionId: 's1',
        role: MessageRole.assistant,
        content: [
          MessageContent.text('Before'),
          MessageContent.toolUse(ToolCall(id: 't1', name: 'Read', input: {})),
          MessageContent.text('Between'),
          MessageContent.toolUse(ToolCall(id: 't2', name: 'Bash', input: {})),
        ],
        timestamp: DateTime.now(),
      );
      expect(msg.toolCalls, hasLength(2));
      expect(msg.toolCalls[0].name, 'Read');
      expect(msg.toolCalls[1].name, 'Bash');
    });
  });

  group('ChatMessage.toJson', () {
    test('round-trips basic fields', () {
      final msg = ChatMessage(
        id: 'msg1',
        paraId: 'p1',
        sessionId: 's1',
role: MessageRole.user,
        content: [MessageContent.text('Hello')],
        timestamp: DateTime.parse('2024-01-01T00:00:00.000Z'),
      );
      final json = msg.toJson();
      expect(json['id'], 'msg1');
      expect(json['paraId'], 'p1');
      expect(json['sessionId'], 's1');
      expect(json['role'], 'user');
      expect(json['content'], 'Hello');
    });

    test('omits paraId when null', () {
      final msg = ChatMessage.user(sessionId: 's1', text: 'Hi');
      final json = msg.toJson();
      expect(json.containsKey('paraId'), isFalse);
    });
  });

  group('ChatMessage.copyWith', () {
    test('creates copy with modified fields', () {
      final original = ChatMessage.user(sessionId: 's1', text: 'Hi');
      final copy = original.copyWith(isStreaming: true, sessionId: 's2');
      expect(copy.isStreaming, isTrue);
      expect(copy.sessionId, 's2');
      expect(copy.textContent, 'Hi'); // unchanged
      expect(copy.role, MessageRole.user); // unchanged
    });
  });

  group('UserQuestion', () {
    test('fromJson parses question with options', () {
      final q = UserQuestion.fromJson({
        'question': 'Which framework?',
        'header': 'Framework',
        'options': [
          {'label': 'React', 'description': 'JavaScript library'},
          {'label': 'Flutter', 'description': 'Dart framework'},
        ],
        'multiSelect': true,
      });
      expect(q.question, 'Which framework?');
      expect(q.header, 'Framework');
      expect(q.options, hasLength(2));
      expect(q.options[0].label, 'React');
      expect(q.options[1].description, 'Dart framework');
      expect(q.multiSelect, isTrue);
    });

    test('fromJson with missing fields uses defaults', () {
      final q = UserQuestion.fromJson({});
      expect(q.question, '');
      expect(q.header, '');
      expect(q.options, isEmpty);
      expect(q.multiSelect, isFalse);
    });
  });
}
