import 'package:flutter_test/flutter_test.dart';
import 'package:parachute/features/chat/models/chat_session.dart';

void main() {
  group('ChatSession.fromJson', () {
    test('parses full JSON payload', () {
      final session = ChatSession.fromJson({
        'id': 'sess1',
        'agentPath': '/agents/research',
        'agentName': 'Research Agent',
        'agentType': 'research',
        'title': 'Test Session',
        'createdAt': '2024-06-15T10:00:00.000Z',
        'updatedAt': '2024-06-15T11:00:00.000Z',
        'messageCount': 42,
        'archived': false,
        'source': 'parachute',
        'continuedFrom': 'prev1',
        'originalId': 'orig1',
        'workingDirectory': '/projects/myapp',
        'trustLevel': 'vault',
        'mode': 'cocreate',
        'linkedBotPlatform': 'telegram',
        'linkedBotChatId': 'tg123',
        'linkedBotChatType': 'group',
        'projectId': 'proj1',
        'bridgeSessionId': 'bridge1',
        'metadata': {'pending_approval': true},
      });
      expect(session.id, 'sess1');
      expect(session.agentPath, '/agents/research');
      expect(session.agentName, 'Research Agent');
      expect(session.agentType, 'research');
      expect(session.title, 'Test Session');
      expect(session.createdAt, DateTime.parse('2024-06-15T10:00:00.000Z'));
      expect(session.updatedAt, DateTime.parse('2024-06-15T11:00:00.000Z'));
      expect(session.messageCount, 42);
      expect(session.archived, isFalse);
      expect(session.source, ChatSource.parachute);
      expect(session.continuedFrom, 'prev1');
      expect(session.originalId, 'orig1');
      expect(session.workingDirectory, '/projects/myapp');
      expect(session.trustLevel, 'vault');
      expect(session.mode, 'cocreate');
      expect(session.linkedBotPlatform, 'telegram');
      expect(session.linkedBotChatId, 'tg123');
      expect(session.linkedBotChatType, 'group');
      expect(session.projectId, 'proj1');
      expect(session.bridgeSessionId, 'bridge1');
      expect(session.isPendingApproval, isTrue);
    });

    test('handles missing optional fields gracefully', () {
      final session = ChatSession.fromJson({
        'id': 'sess2',
        'createdAt': '2024-06-15T10:00:00.000Z',
      });
      expect(session.id, 'sess2');
      expect(session.agentPath, isNull);
      expect(session.agentName, isNull);
      expect(session.title, isNull);
      expect(session.updatedAt, isNull);
      expect(session.messageCount, 0);
      expect(session.archived, isFalse);
      expect(session.source, ChatSource.parachute);
      expect(session.continuedFrom, isNull);
      expect(session.workingDirectory, isNull);
      expect(session.trustLevel, isNull);
      expect(session.mode, isNull);
      expect(session.metadata, isNull);
      expect(session.isPendingApproval, isFalse);
    });

    test('uses lastAccessed as updatedAt fallback', () {
      final session = ChatSession.fromJson({
        'id': 'sess3',
        'createdAt': '2024-06-15T10:00:00.000Z',
        'lastAccessed': '2024-06-15T12:00:00.000Z',
      });
      expect(session.updatedAt, DateTime.parse('2024-06-15T12:00:00.000Z'));
    });

    test('prefers updatedAt over lastAccessed', () {
      final session = ChatSession.fromJson({
        'id': 'sess4',
        'createdAt': '2024-06-15T10:00:00.000Z',
        'updatedAt': '2024-06-15T11:00:00.000Z',
        'lastAccessed': '2024-06-15T12:00:00.000Z',
      });
      expect(session.updatedAt, DateTime.parse('2024-06-15T11:00:00.000Z'));
    });

    test('accepts snake_case trust_level and linked_bot fields', () {
      final session = ChatSession.fromJson({
        'id': 'sess5',
        'createdAt': '2024-06-15T10:00:00.000Z',
        'trust_level': 'sandboxed',
        'linked_bot_platform': 'discord',
        'linked_bot_chat_id': 'dc456',
        'linked_bot_chat_type': 'dm',
      });
      expect(session.trustLevel, 'sandboxed');
      expect(session.linkedBotPlatform, 'discord');
      expect(session.linkedBotChatId, 'dc456');
      expect(session.linkedBotChatType, 'dm');
    });

    test('generates id and timestamp when missing', () {
      final before = DateTime.now();
      final session = ChatSession.fromJson({});
      expect(session.id, '');
      expect(session.createdAt.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
    });
  });

  group('ChatSource', () {
    test('fromString parses all known sources', () {
      expect(ChatSourceExtension.fromString('parachute'), ChatSource.parachute);
      expect(ChatSourceExtension.fromString('chatgpt'), ChatSource.chatgpt);
      expect(ChatSourceExtension.fromString('claude'), ChatSource.claude);
      expect(ChatSourceExtension.fromString('telegram'), ChatSource.telegram);
      expect(ChatSourceExtension.fromString('discord'), ChatSource.discord);
      expect(ChatSourceExtension.fromString('other'), ChatSource.other);
    });

    test('fromString defaults to parachute for null/unknown', () {
      expect(ChatSourceExtension.fromString(null), ChatSource.parachute);
      expect(ChatSourceExtension.fromString('unknown_source'), ChatSource.parachute);
    });

    test('displayName returns human-friendly names', () {
      expect(ChatSource.parachute.displayName, 'Parachute');
      expect(ChatSource.chatgpt.displayName, 'ChatGPT');
      expect(ChatSource.claude.displayName, 'Claude');
      expect(ChatSource.telegram.displayName, 'Telegram');
      expect(ChatSource.discord.displayName, 'Discord');
      expect(ChatSource.other.displayName, 'Imported');
    });

    test('isBotSession identifies bot sources', () {
      expect(ChatSource.telegram.isBotSession, isTrue);
      expect(ChatSource.discord.isBotSession, isTrue);
      expect(ChatSource.parachute.isBotSession, isFalse);
      expect(ChatSource.chatgpt.isBotSession, isFalse);
    });
  });

  group('ChatSession computed properties', () {
    test('displayTitle falls back through title → agentName → default', () {
      final withTitle = ChatSession(
        id: '1', createdAt: DateTime.now(), title: 'My Chat',
      );
      expect(withTitle.displayTitle, 'My Chat');

      final withAgent = ChatSession(
        id: '2', createdAt: DateTime.now(), agentName: 'Research Bot',
      );
      expect(withAgent.displayTitle, 'Chat with Research Bot');

      final bare = ChatSession(id: '3', createdAt: DateTime.now());
      expect(bare.displayTitle, 'New Chat');
    });

    test('displayTitle skips empty strings', () {
      final emptyTitle = ChatSession(
        id: '1', createdAt: DateTime.now(), title: '', agentName: 'Bot',
      );
      expect(emptyTitle.displayTitle, 'Chat with Bot');
    });

    test('agentDisplayName capitalizes agent type words', () {
      final session = ChatSession(
        id: '1', createdAt: DateTime.now(), agentType: 'research-assistant',
      );
      expect(session.agentDisplayName, 'Research Assistant');
    });

    test('agentDisplayName prefers agentName over agentType', () {
      final session = ChatSession(
        id: '1',
        createdAt: DateTime.now(),
        agentName: 'My Agent',
        agentType: 'research',
      );
      expect(session.agentDisplayName, 'My Agent');
    });

    test('isImported checks source', () {
      expect(
        ChatSession(id: '1', createdAt: DateTime.now(), source: ChatSource.chatgpt).isImported,
        isTrue,
      );
      expect(
        ChatSession(id: '1', createdAt: DateTime.now()).isImported,
        isFalse,
      );
    });

    test('isContinuation checks continuedFrom', () {
      expect(
        ChatSession(id: '1', createdAt: DateTime.now(), continuedFrom: 'prev').isContinuation,
        isTrue,
      );
      expect(
        ChatSession(id: '1', createdAt: DateTime.now()).isContinuation,
        isFalse,
      );
    });

    test('hasExternalWorkingDirectory and workingDirectoryName', () {
      final withWd = ChatSession(
        id: '1', createdAt: DateTime.now(), workingDirectory: '/projects/myapp',
      );
      expect(withWd.hasExternalWorkingDirectory, isTrue);
      expect(withWd.workingDirectoryName, 'myapp');

      final without = ChatSession(id: '2', createdAt: DateTime.now());
      expect(without.hasExternalWorkingDirectory, isFalse);
      expect(without.workingDirectoryName, isNull);
    });

    test('hasCustomAgent checks all agent fields', () {
      expect(
        ChatSession(id: '1', createdAt: DateTime.now(), agentType: 'research').hasCustomAgent,
        isTrue,
      );
      expect(
        ChatSession(id: '1', createdAt: DateTime.now(), agentPath: '/a').hasCustomAgent,
        isTrue,
      );
      expect(
        ChatSession(id: '1', createdAt: DateTime.now(), agentName: 'Bot').hasCustomAgent,
        isTrue,
      );
      expect(
        ChatSession(id: '1', createdAt: DateTime.now()).hasCustomAgent,
        isFalse,
      );
    });

    test('metadata-derived properties', () {
      final session = ChatSession(
        id: '1',
        createdAt: DateTime.now(),
        metadata: {
          'pending_approval': true,
          'pending_initialization': true,
          'pairing_request_id': 'pair1',
          'first_message': 'Hello bot',
          'bot_settings': {
            'response_mode': 'mention_only',
            'mention_pattern': '@bot',
          },
        },
      );
      expect(session.isPendingApproval, isTrue);
      expect(session.isPendingInitialization, isTrue);
      expect(session.pairingRequestId, 'pair1');
      expect(session.firstMessage, 'Hello bot');
      expect(session.responseMode, 'mention_only');
      expect(session.mentionPattern, '@bot');
    });
  });

  group('ChatSession.toJson', () {
    test('round-trips required and optional fields', () {
      final session = ChatSession(
        id: 'sess1',
        agentName: 'Bot',
        title: 'Chat',
        createdAt: DateTime.parse('2024-01-01T00:00:00.000Z'),
        updatedAt: DateTime.parse('2024-01-01T01:00:00.000Z'),
        messageCount: 10,
        archived: true,
        source: ChatSource.claude,
        continuedFrom: 'prev',
        trustLevel: 'full',
        mode: 'converse',
      );
      final json = session.toJson();
      expect(json['id'], 'sess1');
      expect(json['agentName'], 'Bot');
      expect(json['title'], 'Chat');
      expect(json['messageCount'], 10);
      expect(json['archived'], isTrue);
      expect(json['source'], 'claude');
      expect(json['continuedFrom'], 'prev');
      expect(json['trustLevel'], 'full');
      expect(json['mode'], 'converse');
    });

    test('omits null optional fields', () {
      final session = ChatSession(
        id: 'sess2',
        createdAt: DateTime.parse('2024-01-01T00:00:00.000Z'),
      );
      final json = session.toJson();
      expect(json.containsKey('continuedFrom'), isFalse);
      expect(json.containsKey('originalId'), isFalse);
      expect(json.containsKey('workingDirectory'), isFalse);
      expect(json.containsKey('trustLevel'), isFalse);
      expect(json.containsKey('mode'), isFalse);
      expect(json.containsKey('metadata'), isFalse);
    });
  });

  group('ChatSession.copyWith', () {
    test('creates copy with modified fields', () {
      final original = ChatSession(
        id: 'sess1',
        title: 'Original',
        createdAt: DateTime.parse('2024-01-01T00:00:00.000Z'),
        archived: false,
      );
      final copy = original.copyWith(title: 'Updated', archived: true);
      expect(copy.id, 'sess1'); // unchanged
      expect(copy.title, 'Updated');
      expect(copy.archived, isTrue);
    });
  });
}
