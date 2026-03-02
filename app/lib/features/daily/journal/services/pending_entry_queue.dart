import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/journal_entry.dart';
import 'daily_api_service.dart';

/// A SharedPreferences-backed queue of journal entries written while offline.
///
/// Entries persist across app restarts and are flushed to the server when
/// connectivity is available. Each entry is shown in the UI with `isPending: true`
/// until it successfully uploads.
class PendingEntryQueue extends ChangeNotifier {
  static const _prefsKey = 'daily_pending_entries';

  final SharedPreferences _prefs;
  List<_PendingItem> _items = [];

  PendingEntryQueue._(this._prefs) {
    _load();
  }

  static Future<PendingEntryQueue> create() async {
    final prefs = await SharedPreferences.getInstance();
    return PendingEntryQueue._(prefs);
  }

  /// All pending entries as JournalEntry objects (with isPending: true)
  List<JournalEntry> get entries => _items
      .map((item) => JournalEntry.pending(
            localId: item.localId,
            content: item.content,
            type: JournalEntry.parseType(item.type),
            title: item.title,
            audioPath: item.audioPath,
            imagePath: item.imagePath,
            durationSeconds: item.durationSeconds,
            createdAt: item.queuedAt,
          ))
      .toList();

  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;

  /// Add an entry to the queue and return it as a JournalEntry for immediate display.
  Future<JournalEntry> enqueue({
    required String localId,
    required String content,
    String type = 'text',
    String? title,
    String? audioPath,
    String? imagePath,
    int? durationSeconds,
  }) async {
    final item = _PendingItem(
      localId: localId,
      content: content,
      type: type,
      title: title,
      audioPath: audioPath,
      imagePath: imagePath,
      durationSeconds: durationSeconds,
      queuedAt: DateTime.now(),
    );
    _items.add(item);
    await _save();
    notifyListeners();

    return JournalEntry.pending(
      localId: localId,
      content: content,
      type: JournalEntry.parseType(type),
      title: title,
      audioPath: audioPath,
      imagePath: imagePath,
      durationSeconds: durationSeconds,
      createdAt: item.queuedAt,
    );
  }

  bool _isFlushing = false;

  /// Attempt to upload all queued entries in order.
  ///
  /// Successfully uploaded entries are removed from the queue.
  /// Failed entries remain in the queue for the next flush.
  /// Re-entrant calls are no-ops — safe to call from concurrent providers.
  Future<void> flush(DailyApiService api) async {
    if (_isFlushing || _items.isEmpty) return;
    _isFlushing = true;
    try {
      await _flush(api);
    } finally {
      _isFlushing = false;
    }
  }

  Future<void> _flush(DailyApiService api) async {

    final remaining = <_PendingItem>[];
    for (final item in List<_PendingItem>.from(_items)) {
      try {
        final result = await api.createEntry(
          content: item.content,
          metadata: {
            if (item.type != 'text') 'type': item.type,
            if (item.title != null && item.title!.isNotEmpty) 'title': item.title!,
            if (item.audioPath != null) 'audio_path': item.audioPath!,
            if (item.imagePath != null) 'image_path': item.imagePath!,
            if (item.durationSeconds != null) 'duration_seconds': item.durationSeconds!,
          },
        );
        if (result == null) {
          // Upload failed; keep in queue
          remaining.add(item);
        } else {
          debugPrint('[PendingEntryQueue] Flushed ${item.localId} → ${result.id}');
        }
      } catch (e) {
        debugPrint('[PendingEntryQueue] Flush error for ${item.localId}: $e');
        remaining.add(item);
      }
    }

    _items = remaining;
    await _save();
    notifyListeners();
  }

  void _load() {
    final raw = _prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _items = list
          .map((j) => _PendingItem.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[PendingEntryQueue] Failed to load queue: $e');
      _items = [];
    }
  }

  Future<void> _save() async {
    await _prefs.setString(_prefsKey, jsonEncode(_items.map((i) => i.toJson()).toList()));
  }
}

class _PendingItem {
  final String localId;
  final String content;
  final String type;
  final String? title;
  final String? audioPath;
  final String? imagePath;
  final int? durationSeconds;
  final DateTime queuedAt;

  const _PendingItem({
    required this.localId,
    required this.content,
    required this.type,
    required this.queuedAt,
    this.title,
    this.audioPath,
    this.imagePath,
    this.durationSeconds,
  });

  Map<String, dynamic> toJson() => {
    'localId': localId,
    'content': content,
    'type': type,
    if (title != null) 'title': title,
    if (audioPath != null) 'audioPath': audioPath,
    if (imagePath != null) 'imagePath': imagePath,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
    'queuedAt': queuedAt.toIso8601String(),
  };

  factory _PendingItem.fromJson(Map<String, dynamic> json) => _PendingItem(
    localId: json['localId'] as String,
    content: json['content'] as String,
    type: json['type'] as String? ?? 'text',
    title: json['title'] as String?,
    audioPath: json['audioPath'] as String?,
    imagePath: json['imagePath'] as String?,
    durationSeconds: json['durationSeconds'] as int?,
    queuedAt: DateTime.tryParse(json['queuedAt'] as String? ?? '') ?? DateTime.now(),
  );
}
