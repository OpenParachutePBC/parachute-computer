import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Draft data for the compose screen.
class ComposeDraft {
  final String title;
  final String content;

  const ComposeDraft({required this.title, required this.content});

  bool get isEmpty => title.isEmpty && content.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// Manages draft persistence for the Daily compose experience.
///
/// Saves the current compose text (title + content) to SharedPreferences
/// with a 500ms debounce. Draft is restored on app restart and cleared
/// when the entry is successfully submitted.
///
/// Uses the same `title|||content` format as [EntryEditModal].
class ComposeDraftNotifier extends Notifier<ComposeDraft> {
  static const _key = 'daily_compose_draft';
  static const _separator = '|||';
  Timer? _debounceTimer;

  @override
  ComposeDraft build() {
    ref.onDispose(() => _debounceTimer?.cancel());
    _loadDraft();
    return const ComposeDraft(title: '', content: '');
  }

  /// Save draft with debounce (500ms).
  void saveDraft(String title, String content) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _persistDraft(title, content);
    });
    // Update state immediately for UI responsiveness
    state = ComposeDraft(title: title, content: content);
  }

  /// Save draft immediately (for lifecycle events like app pause).
  Future<void> flushDraft(String title, String content) async {
    _debounceTimer?.cancel();
    await _persistDraft(title, content);
  }

  /// Clear draft after successful submission.
  Future<void> clearDraft() async {
    _debounceTimer?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
      state = const ComposeDraft(title: '', content: '');
      debugPrint('[ComposeDraft] Draft cleared');
    } catch (e) {
      debugPrint('[ComposeDraft] Error clearing draft: $e');
    }
  }

  Future<void> _persistDraft(String title, String content) async {
    if (title.isEmpty && content.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = '$title$_separator$content';
      await prefs.setString(_key, value);
      state = ComposeDraft(title: title, content: content);
      debugPrint('[ComposeDraft] Draft saved (${content.length} chars)');
    } catch (e) {
      debugPrint('[ComposeDraft] Error saving draft: $e');
    }
  }

  Future<void> _loadDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_key);
      if (value == null) return;

      final sepIndex = value.indexOf(_separator);
      if (sepIndex < 0) return;

      final title = value.substring(0, sepIndex);
      final content = value.substring(sepIndex + _separator.length);

      if (title.isNotEmpty || content.isNotEmpty) {
        state = ComposeDraft(title: title, content: content);
        debugPrint('[ComposeDraft] Draft restored (${content.length} chars)');
      }
    } catch (e) {
      debugPrint('[ComposeDraft] Error loading draft: $e');
    }
  }
}

/// Provider for compose draft persistence.
final composeDraftProvider =
    NotifierProvider<ComposeDraftNotifier, ComposeDraft>(
  ComposeDraftNotifier.new,
);
