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
/// [sync_state] column tracks offline mutations:
///   - `synced`         — matches server (default)
///   - `pending_delete` — deleted locally, server delete queued
///   - `pending_edit`   — edited locally, server update queued
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
        entry_id         TEXT PRIMARY KEY,
        date             TEXT NOT NULL,
        content          TEXT NOT NULL DEFAULT '',
        title            TEXT,
        entry_type       TEXT DEFAULT 'text',
        audio_path       TEXT,
        image_path       TEXT,
        linked_file_path TEXT,
        duration_secs    INTEGER,
        created_at       TEXT NOT NULL,
        sync_state       TEXT DEFAULT 'synced'
      )
    ''');
    // Composite index covers all date-filtered queries.
    _db.execute(
      'CREATE INDEX IF NOT EXISTS idx_jc_created ON journal_entries(date, created_at)',
    );
    // Migration: add sync_state to databases created before this column existed.
    try {
      _db.execute(
        "ALTER TABLE journal_entries ADD COLUMN sync_state TEXT DEFAULT 'synced'",
      );
    } catch (_) {
      // Column already exists — ignore
    }
    // Safety net: NULL sync_state → treat as synced
    _db.execute(
      "UPDATE journal_entries SET sync_state = 'synced' WHERE sync_state IS NULL",
    );
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Return all visible entries for [date] (YYYY-MM-DD), oldest first.
  ///
  /// Excludes [pending_delete] entries — they are hidden from the UI while
  /// their server-side delete is queued. Includes [pending_edit] entries with
  /// the locally-modified content so edits are visible while offline.
  List<JournalEntry> getEntries(String date) {
    try {
      final rows = _db.select(
        "SELECT * FROM journal_entries "
        "WHERE date = ? AND COALESCE(sync_state, 'synced') != 'pending_delete' "
        "ORDER BY created_at ASC",
        [date],
      );
      return rows.map(_rowToEntry).toList();
    } catch (e) {
      debugPrint('[JournalLocalCache] getEntries error: $e');
      return [];
    }
  }

  /// Return all entries whose server delete is pending.
  List<String> getPendingDeletes() {
    try {
      final rows = _db.select(
        "SELECT entry_id FROM journal_entries WHERE sync_state = 'pending_delete'",
      );
      return rows.map((r) => r['entry_id'] as String).toList();
    } catch (e) {
      debugPrint('[JournalLocalCache] getPendingDeletes error: $e');
      return [];
    }
  }

  /// Return all entries whose server update is pending (locally-edited content).
  List<JournalEntry> getPendingEdits() {
    try {
      final rows = _db.select(
        "SELECT * FROM journal_entries WHERE sync_state = 'pending_edit'",
      );
      return rows.map(_rowToEntry).toList();
    } catch (e) {
      debugPrint('[JournalLocalCache] getPendingEdits error: $e');
      return [];
    }
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  /// Remove [synced] entries for [date] whose IDs are not in [serverIds].
  ///
  /// Called after a successful non-empty server fetch to prune entries that
  /// were deleted server-side but are still sitting in the local cache.
  /// Only removes [synced] entries — [pending_delete] and [pending_edit] are
  /// left alone since they represent unsynced local changes.
  void removeStaleEntries(String date, Set<String> serverIds) {
    if (serverIds.isEmpty) return;
    try {
      // Single DELETE … NOT IN is more efficient than a SELECT + per-row DELETE loop.
      final placeholders = List.filled(serverIds.length, '?').join(', ');
      _db.execute(
        "DELETE FROM journal_entries "
        "WHERE date = ? AND COALESCE(sync_state, 'synced') = 'synced' "
        "AND entry_id NOT IN ($placeholders)",
        [date, ...serverIds],
      );
      debugPrint('[JournalLocalCache] removeStaleEntries: pruned stale entries for $date');
    } catch (e) {
      debugPrint('[JournalLocalCache] removeStaleEntries error: $e');
    }
  }


  /// Batch-upsert [entries] from server into the cache.
  ///
  /// Uses SQLite UPSERT (ON CONFLICT … DO UPDATE) to preserve locally-pending
  /// mutations. Specifically:
  /// - [pending_delete] rows keep their sync_state — the server still has the
  ///   entry (delete not yet flushed), so we don't want to clear the flag.
  /// - [pending_edit] rows keep their content/title/sync_state — the server
  ///   still has the old version (edit not yet flushed).
  /// All other rows are updated normally and reset to `synced`.
  void putEntries(String date, List<JournalEntry> entries) {
    if (entries.isEmpty) return;
    // Nullable so the finally block can safely skip dispose() if prepare() itself throws.
    PreparedStatement? stmt;
    try {
      stmt = _db.prepare(
        'INSERT INTO journal_entries '
        '(entry_id, date, content, title, entry_type, audio_path, image_path, '
        ' linked_file_path, duration_secs, created_at, sync_state) '
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'synced') "
        'ON CONFLICT(entry_id) DO UPDATE SET '
        '  date             = excluded.date, '
        '  content          = CASE WHEN sync_state = \'pending_edit\' THEN content          ELSE excluded.content          END, '
        '  title            = CASE WHEN sync_state = \'pending_edit\' THEN title            ELSE excluded.title            END, '
        '  entry_type       = excluded.entry_type, '
        '  audio_path       = excluded.audio_path, '
        '  image_path       = excluded.image_path, '
        '  linked_file_path = excluded.linked_file_path, '
        '  duration_secs    = excluded.duration_secs, '
        '  created_at       = excluded.created_at, '
        "  sync_state       = CASE WHEN sync_state IN ('pending_delete', 'pending_edit') THEN sync_state ELSE 'synced' END",
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
          e.linkedFilePath,
          e.durationSeconds,
          e.createdAt.toUtc().toIso8601String(),
        ]);
      }
    } catch (e) {
      debugPrint('[JournalLocalCache] putEntries error: $e');
    } finally {
      stmt?.dispose();
    }
  }

  // ── Sync-state mutations ───────────────────────────────────────────────────

  /// Mark an entry as pending deletion.
  ///
  /// The entry will be hidden from [getEntries] until it is either flushed
  /// (then [removeEntry] clears it) or overridden by a server fetch.
  void markForDelete(String entryId) {
    try {
      _db.execute(
        "UPDATE journal_entries SET sync_state = 'pending_delete' WHERE entry_id = ?",
        [entryId],
      );
    } catch (e) {
      debugPrint('[JournalLocalCache] markForDelete error: $e');
    }
  }

  /// Mark an entry as having a locally-pending edit.
  ///
  /// Updates the cached [content] and [title] immediately so the user sees
  /// the change. The server will be updated on the next flush.
  void markForEdit(String entryId, {required String content, required String title}) {
    try {
      _db.execute(
        "UPDATE journal_entries SET content = ?, title = ?, sync_state = 'pending_edit' WHERE entry_id = ?",
        [content, title, entryId],
      );
    } catch (e) {
      debugPrint('[JournalLocalCache] markForEdit error: $e');
    }
  }

  /// Mark an entry as synced (clears any pending state).
  ///
  /// Optionally update [content] and [title] with the authoritative server
  /// values returned after a successful flush. If null, existing values are kept.
  void markSynced(String entryId, {String? content, String? title}) {
    try {
      // COALESCE(?, col) → use the provided value if non-null, else keep existing.
      _db.execute(
        "UPDATE journal_entries SET "
        "  content    = COALESCE(?, content), "
        "  title      = COALESCE(?, title), "
        "  sync_state = 'synced' "
        "WHERE entry_id = ?",
        [content, title, entryId],
      );
    } catch (e) {
      debugPrint('[JournalLocalCache] markSynced error: $e');
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
    final syncState = (row['sync_state'] as String?) ?? 'synced';
    return JournalEntry(
      id: row['entry_id'] as String,
      title: (row['title'] as String?) ?? '',
      content: (row['content'] as String?) ?? '',
      type: JournalEntry.parseType(typeStr),
      createdAt: JournalEntry.parseDateTime(row['created_at'] as String?),
      audioPath: row['audio_path'] as String?,
      imagePath: row['image_path'] as String?,
      linkedFilePath: row['linked_file_path'] as String?,
      durationSeconds: switch (durationSecs) {
        final int v => v,
        final double v => v.toInt(),
        _ => null,
      },
      hasPendingEdit: syncState == 'pending_edit',
    );
  }
}
