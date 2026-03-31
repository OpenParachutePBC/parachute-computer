import 'package:flutter/material.dart';
import 'package:parachute/core/theme/design_tokens.dart';

/// Reusable tag input widget with chips and autocomplete.
///
/// Shows existing tags as removable chips, plus a text field for adding new
/// tags. Optionally fetches tag suggestions for autocomplete.
class TagInput extends StatefulWidget {
  /// Current tags (controlled from parent).
  final List<String> tags;

  /// Called when a tag is added or removed. Returns the new full list.
  final void Function(List<String> tags) onChanged;

  /// Optional: available tags for autocomplete suggestions.
  final List<String> suggestions;

  /// Hint text for the input field.
  final String hintText;

  const TagInput({
    super.key,
    required this.tags,
    required this.onChanged,
    this.suggestions = const [],
    this.hintText = 'Add a tag...',
  });

  @override
  State<TagInput> createState() => _TagInputState();
}

class _TagInputState extends State<TagInput> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _addTag(String raw) {
    if (raw.isEmpty) return;
    final tag = raw.toLowerCase().replaceAll(' ', '-');
    // Validate: alphanumeric + hyphens, max 48 chars
    if (!RegExp(r'^[a-z0-9](?:[a-z0-9\-]{0,46}[a-z0-9])?$').hasMatch(tag)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tags must be lowercase letters, numbers, and hyphens'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (widget.tags.contains(tag)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Tag "$tag" already added'),
          duration: const Duration(seconds: 1),
        ),
      );
      _controller.clear();
      return;
    }
    final updated = [...widget.tags, tag];
    widget.onChanged(updated);
    _controller.clear();
  }

  void _removeTag(String tag) {
    final updated = widget.tags.where((t) => t != tag).toList();
    widget.onChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Filter suggestions to those not already selected and matching input
    final input = _controller.text.toLowerCase();
    final filtered = widget.suggestions
        .where((s) => !widget.tags.contains(s))
        .where((s) => input.isEmpty || s.contains(input))
        .take(8)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Tag chips
        if (widget.tags.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in widget.tags)
                Chip(
                  label: Text(tag),
                  onDeleted: () => _removeTag(tag),
                  backgroundColor: isDark
                      ? BrandColors.charcoal.withValues(alpha: 0.5)
                      : BrandColors.stone.withValues(alpha: 0.3),
                  labelStyle: theme.textTheme.bodySmall?.copyWith(
                    color: isDark ? BrandColors.softWhite : BrandColors.ink,
                  ),
                  deleteIconColor:
                      isDark ? BrandColors.softWhite : BrandColors.ink,
                ),
            ],
          ),
        if (widget.tags.isNotEmpty) const SizedBox(height: 12),
        // Input row
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isDark ? BrandColors.softWhite : BrandColors.ink,
                ),
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  hintStyle: TextStyle(color: BrandColors.driftwood),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color:
                          isDark ? BrandColors.charcoal : BrandColors.stone,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color:
                          isDark ? BrandColors.charcoal : BrandColors.stone,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                      color: BrandColors.turquoise,
                      width: 2,
                    ),
                  ),
                ),
                onSubmitted: (value) => _addTag(value.trim()),
                onChanged: (_) => setState(() {}), // rebuild for suggestions
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 40,
              child: ElevatedButton(
                onPressed: () => _addTag(_controller.text.trim()),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  backgroundColor: BrandColors.turquoise,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Add'),
              ),
            ),
          ],
        ),
        // Autocomplete suggestions
        if (filtered.isNotEmpty && _controller.text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: filtered.map((s) {
                return ActionChip(
                  label: Text(s, style: theme.textTheme.labelSmall),
                  onPressed: () => _addTag(s),
                  backgroundColor: isDark
                      ? BrandColors.charcoal.withValues(alpha: 0.3)
                      : BrandColors.stone.withValues(alpha: 0.15),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}
