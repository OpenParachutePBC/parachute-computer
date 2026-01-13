import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../../../core/services/logging_service.dart';

/// Type of para ID, used for categorizing IDs in the registry.
enum ParaIdType {
  entry,    // Journal entries (for compatibility)
  message,  // Chat messages
  asset,    // Media files
  session,  // Chat sessions
}

/// Registry entry for a para ID (stored in ids.jsonl).
class ParaIdEntry {
  final String id;
  final ParaIdType type;
  final DateTime created;
  final String? path;

  ParaIdEntry({
    required this.id,
    required this.type,
    required this.created,
    this.path,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'created': created.toIso8601String(),
    if (path != null) 'path': path,
  };

  factory ParaIdEntry.fromJson(Map<String, dynamic> json) => ParaIdEntry(
    id: json['id'] as String,
    type: ParaIdType.values.firstWhere(
      (t) => t.name == json['type'],
      orElse: () => ParaIdType.message,
    ),
    created: DateTime.parse(json['created'] as String),
    path: json['path'] as String?,
  );

  String toJsonLine() => jsonEncode(toJson());
}

/// Service for generating and tracking unique para IDs.
///
/// Para IDs are alphanumeric identifiers used to uniquely identify content.
/// Format: `para:{module}:{uuid}` where module is 'daily', 'chat', etc.
///
/// Examples:
/// - Chat messages: `### para:chat:abc123def456 User | timestamp`
/// - Chat sessions: `session_id: chat:abc123def456`
/// - Assets: `assets/2025-12/para_chat_abc123def456_audio.wav`
///
/// New IDs are 12 characters (36^12 = 4.7 quintillion combinations).
/// Legacy 6-character IDs are still supported for backwards compatibility.
///
/// Registry stored in module folder as `ids.jsonl` (JSONL format, append-only).
class ParaIdService {
  static const String _registryFileName = 'ids.jsonl';

  /// New IDs are 12 characters for more headroom
  static const int _newIdLength = 12;

  /// Legacy IDs were 6 characters
  static const int _legacyIdLength = 6;

  /// Valid ID lengths (for parsing)
  static const List<int> _validLengths = [_legacyIdLength, _newIdLength];

  static const String _charset = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// Valid module prefixes
  static const List<String> validModules = ['daily', 'chat'];

  final String _modulePath;
  final String _module;
  final Set<String> _existingIds = {};
  final Map<String, ParaIdEntry> _registry = {};
  final Random _random = Random.secure();
  final _log = logger.createLogger('ParaIdService');

  bool _initialized = false;
  File? _registryFile;

  /// Create a ParaIdService for a specific module.
  ///
  /// [modulePath] - Path to the module folder (e.g., ~/Parachute/Chat)
  /// [module] - Module name for ID prefix (e.g., 'daily', 'chat')
  ParaIdService({
    required String modulePath,
    required String module,
  }) : _modulePath = modulePath,
       _module = module.toLowerCase();

  /// The module this service generates IDs for
  String get module => _module;

  /// Whether the service has been initialized
  bool get isInitialized => _initialized;

  /// Number of tracked IDs
  int get idCount => _existingIds.length;

  /// Path to the registry file
  String get registryFilePath => '$_modulePath/$_registryFileName';

  /// Initialize the service by loading existing IDs from disk
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      final dir = Directory(_modulePath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      _registryFile = File(registryFilePath);

      // Load registry (ids.jsonl)
      await _loadRegistry();

      _log.info('Loaded ${_existingIds.length} para IDs for module $_module');

      _initialized = true;
    } catch (e, st) {
      _log.error('Failed to initialize ParaIdService', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Load ids.jsonl registry
  Future<void> _loadRegistry() async {
    if (!await _registryFile!.exists()) {
      await _registryFile!.create();
      return;
    }

    try {
      final contents = await _registryFile!.readAsString();
      final lines = contents
          .split('\n')
          .where((line) => line.trim().isNotEmpty);

      for (final line in lines) {
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          final entry = ParaIdEntry.fromJson(json);
          _existingIds.add(entry.id.toLowerCase());
          _registry[entry.id.toLowerCase()] = entry;
        } catch (e) {
          _log.warn('Invalid registry line', error: e, data: {'line': line});
        }
      }
    } catch (e) {
      _log.warn('Failed to load ids.jsonl', error: e);
    }
  }

  /// Generate a new unique para ID with module prefix
  ///
  /// Returns format: `{module}:{uuid}` (e.g., `chat:abc123def456`)
  /// The full para reference is `para:{module}:{uuid}`
  Future<String> generate({
    ParaIdType type = ParaIdType.message,
    String? path,
  }) async {
    _ensureInitialized();

    String uuid;
    int attempts = 0;
    const maxAttempts = 100;

    do {
      uuid = _generateRandomId();
      attempts++;
      if (attempts > maxAttempts) {
        throw StateError('Failed to generate unique ID after $maxAttempts attempts');
      }
    } while (_existingIds.contains(uuid));

    // Create registry entry (stores just the uuid part)
    final entry = ParaIdEntry(
      id: uuid,
      type: type,
      created: DateTime.now(),
      path: path,
    );

    // Add to memory
    _existingIds.add(uuid);
    _registry[uuid] = entry;

    // Persist to JSONL registry (append-only)
    try {
      await _registryFile!.writeAsString('${entry.toJsonLine()}\n', mode: FileMode.append);
      _log.debug('Generated new para ID', data: {'id': '$_module:$uuid', 'type': type.name});
    } catch (e, st) {
      // Rollback memory if file write fails
      _existingIds.remove(uuid);
      _registry.remove(uuid);
      _log.error('Failed to persist para ID', error: e, stackTrace: st);
      rethrow;
    }

    return '$_module:$uuid';
  }

  /// Check if an ID exists (accepts either `uuid` or `module:uuid` format)
  bool exists(String id) {
    _ensureInitialized();
    final uuid = _extractUuid(id);
    return _existingIds.contains(uuid.toLowerCase());
  }

  /// Get registry entry for an ID
  ParaIdEntry? getEntry(String id) {
    _ensureInitialized();
    final uuid = _extractUuid(id);
    return _registry[uuid.toLowerCase()];
  }

  /// Get all entries of a specific type
  List<ParaIdEntry> getEntriesByType(ParaIdType type) {
    _ensureInitialized();
    return _registry.values.where((e) => e.type == type).toList();
  }

  /// Register an existing ID (used when parsing existing files)
  Future<bool> register(
    String id, {
    ParaIdType type = ParaIdType.message,
    String? path,
  }) async {
    _ensureInitialized();

    final uuid = _extractUuid(id).toLowerCase();
    if (_existingIds.contains(uuid)) {
      return false;
    }

    final entry = ParaIdEntry(
      id: uuid,
      type: type,
      created: DateTime.now(),
      path: path,
    );

    _existingIds.add(uuid);
    _registry[uuid] = entry;

    try {
      await _registryFile!.writeAsString('${entry.toJsonLine()}\n', mode: FileMode.append);
      _log.debug('Registered existing para ID', data: {'id': '$_module:$uuid', 'type': type.name});
      return true;
    } catch (e, st) {
      _existingIds.remove(uuid);
      _registry.remove(uuid);
      _log.error('Failed to register para ID', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Extract the uuid portion from an ID (handles both `uuid` and `module:uuid`)
  String _extractUuid(String id) {
    if (id.contains(':')) {
      final parts = id.split(':');
      return parts.last;
    }
    return id;
  }

  /// Validate a para ID format (accepts both legacy and new formats)
  static bool isValidFormat(String id) {
    // Check for module:uuid format
    if (id.contains(':')) {
      final parts = id.split(':');
      if (parts.length != 2) return false;
      final module = parts[0];
      final uuid = parts[1];
      if (!validModules.contains(module.toLowerCase())) return false;
      return _isValidUuid(uuid);
    }
    // Legacy format (just uuid)
    return _isValidUuid(id);
  }

  static bool _isValidUuid(String uuid) {
    if (!_validLengths.contains(uuid.length)) return false;
    return uuid.toLowerCase().split('').every((char) => _charset.contains(char));
  }

  /// Parse a para ID from an H3 line (chat messages)
  ///
  /// Expected formats:
  /// - New: `### para:chat:abc123def456 User | timestamp`
  /// - Legacy: `### para:abc123def456 User | timestamp`
  static String? parseFromH3(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('### para:')) return null;

    final afterPrefix = trimmed.substring(9); // Skip "### para:"
    return _parseParaId(afterPrefix);
  }

  /// Parse para ID from text after "para:" prefix
  static String? _parseParaId(String text) {
    // Check for module prefix first (e.g., "chat:abc123...")
    for (final module in validModules) {
      if (text.toLowerCase().startsWith('$module:')) {
        final afterModule = text.substring(module.length + 1);
        // Try to extract uuid
        for (final length in [_newIdLength, _legacyIdLength]) {
          if (afterModule.length >= length) {
            final potentialUuid = afterModule.substring(0, length);
            if (_isValidUuid(potentialUuid)) {
              if (afterModule.length == length ||
                  afterModule[length] == ' ' ||
                  afterModule[length] == '\t') {
                return '$module:${potentialUuid.toLowerCase()}';
              }
            }
          }
        }
      }
    }

    // Try legacy format (just uuid, no module)
    for (final length in [_newIdLength, _legacyIdLength]) {
      if (text.length >= length) {
        final potentialId = text.substring(0, length);
        if (_isValidUuid(potentialId)) {
          if (text.length == length ||
              text[length] == ' ' ||
              text[length] == '\t') {
            return potentialId.toLowerCase();
          }
        }
      }
    }

    return null;
  }

  /// Parse role and timestamp from an H3 chat message line
  static (String role, String timestamp)? parseMessageHeader(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('### ')) return null;

    String afterHeader = trimmed.substring(4); // Skip "### "

    // Check if it has a para ID
    if (afterHeader.startsWith('para:')) {
      afterHeader = afterHeader.substring(5); // Skip "para:"

      // Check for module prefix
      for (final module in validModules) {
        if (afterHeader.toLowerCase().startsWith('$module:')) {
          afterHeader = afterHeader.substring(module.length + 1);
          break;
        }
      }

      // Skip the UUID
      for (final length in [_newIdLength, _legacyIdLength]) {
        if (afterHeader.length >= length) {
          final potentialId = afterHeader.substring(0, length);
          if (_isValidUuid(potentialId)) {
            afterHeader = afterHeader.substring(length).trimLeft();
            break;
          }
        }
      }
    }

    // Now parse "Role | timestamp"
    final pipeIndex = afterHeader.indexOf(' | ');
    if (pipeIndex == -1) return null;

    final role = afterHeader.substring(0, pipeIndex).trim();
    final timestamp = afterHeader.substring(pipeIndex + 3).trim();

    return (role, timestamp);
  }

  /// Format an H3 line with para ID (for chat messages)
  static String formatH3(String id, String role, String timestamp) {
    return '### para:$id $role | $timestamp';
  }

  /// Format an H3 line without para ID (legacy format)
  static String formatH3Legacy(String role, String timestamp) {
    return '### $role | $timestamp';
  }

  String _generateRandomId() {
    return List.generate(
      _newIdLength,
      (_) => _charset[_random.nextInt(_charset.length)],
    ).join();
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('ParaIdService not initialized. Call initialize() first.');
    }
  }
}
