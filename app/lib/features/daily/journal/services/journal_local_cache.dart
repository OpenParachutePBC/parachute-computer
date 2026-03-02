import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import '../models/journal_entry.dart';

/// SQLite cache for journal entries — offline fallback when server unreachable.
///
/// Server (Kuzu graph) is the source of truth. This cache is populated on every
/// successful server fetch and read when the server is unavailable.
///
/// Uses [sqlite3] (synchronous) so reads are instant — no async overhead.
class JournalLocalCache {
  final Database _db;

  JournalLocalCache._(this._db);

  /// Open (or create) the cache database in the app documents directory.
  static Future<JournalLocalCache> open() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = p.join(dir.path, 'parachute_daily_cache.db');
      final db = sqlite3.open(path);
      final cache = JournalLocalCache._(db);
      cache._ensureSchema();
      debugPrint('[JournalLocalCache] opened: $path');
      return cache;
    } catch (e) {
      debugPrint('[JournalLocalCache] failed to open, using in-memory fallback: $e');
      final db = sqlite3.openInMemory();
      final cache = JournalLocalCache._(db);
      cache._ensureSchema();
      return cache;
    }
  }

  void _ensureSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS journal_entries (
        entry_id      TEXT PRIMARY KEY,
        date          TEXT NOT NULL,
        content       TEXT NOT NULL DEFAULT '',
        title         TEXT,
        entry_type    TEXT DEFAULT 'text',
        audio_path    TEXT,
        image_path    TEXT,
        duration_secs INTEGER,
        created_at    TEXT NOT NULL
      )
    ''');
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_jc_date ON journal_entries(date)',
    );
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_jc_created ON journal_entries(date, created_at)',
    );
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Return all cached entries for [date] (YYYY-MM-DD), newest first.
  List<JournalEntry> getEntries(String date) {
    try {
      final rows = _db.select(
        'SELECT * FROM journal_entries WHERE date = ? ORDER BY created_at DESC',
        [date],
      );
      return rows.map(_rowToEntry).toList();
    } catch (e) {
      debugPrint('[JournalLocalCache] getEntries error: $e');
      return [];
    }
  }

  bool hasEntries(String date) {
    try {
      final rows = _db.select(
        'SELECT 1 FROM journal_entries WHERE date = ? LIMIT 1',
        [date],
      );
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  /// Batch-upsert [entries] into the cache. Replaces existing rows by entry_id.
  void putEntries(String date, List<JournalEntry> entries) {
    if (entries.isEmpty) return;
    try {
      final stmt = _db.prepare(
        'INSERT OR REPLACE INTO journal_entries '
        '(entry_id, date, content, title, entry_type, audio_path, image_path, duration_secs, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      );
      for (final e in entries) {
        stmt.execute([
          e.id,
          date,
          e.content,
          e.title.isEmpty ? null : e.title,
          e.type.name,
          e.audioPath,
          e.imagePath,
          e.durationSeconds,
          e.createdAt.toUtc().toIso8601String(),
        ]);
      }
      stmt.dispose();
    } catch (e) {
      debugPrint('[JournalLocalCache] putEntries error: $e');
    }
  }

  // ── Remove ─────────────────────────────────────────────────────────────────

  void removeEntry(String entryId) {
    try {
      _db.execute('DELETE FROM journal_entries WHERE entry_id = ?', [entryId]);
    } catch (e) {
      debugPrint('[JournalLocalCache] removeEntry error: $e');
    }
  }

  void clearDate(String date) {
    try {
      _db.execute('DELETE FROM journal_entries WHERE date = ?', [date]);
    } catch (e) {
      debugPrint('[JournalLocalCache] clearDate error: $e');
    }
  }

  void clearAll() {
    try {
      _db.execute('DELETE FROM journal_entries');
    } catch (e) {
      debugPrint('[JournalLocalCache] clearAll error: $e');
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  void dispose() {
    try {
      _db.dispose();
    } catch (_) {}
  }

  // ── Conversion ─────────────────────────────────────────────────────────────

  JournalEntry _rowToEntry(Row row) {
    final typeStr = (row['entry_type'] as String?) ?? 'text';
    final durationSecs = row['duration_secs'];
    return JournalEntry(
      id: row['entry_id'] as String,
      title: (row['title'] as String?) ?? '',
      content: (row['content'] as String?) ?? '',
      type: JournalEntry.parseType(typeStr),
      createdAt: JournalEntry.parseDateTime(row['created_at'] as String?),
      audioPath: row['audio_path'] as String?,
      imagePath: row['image_path'] as String?,
      durationSeconds: switch (durationSecs) {
        final int v => v,
        final double v => v.toInt(),
        _ => null,
      },
    );
  }
}
