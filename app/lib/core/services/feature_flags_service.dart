import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing feature toggles
///
/// Controls which advanced features are enabled:
/// - Omi device integration (off by default)
/// - AI Chat server (off by default)
/// - Future: Pebble, Apple Watch, Android Watch
class FeatureFlagsService {
  static final FeatureFlagsService _instance = FeatureFlagsService._internal();
  factory FeatureFlagsService() => _instance;
  FeatureFlagsService._internal();

  static const String _omiEnabledKey = 'feature_omi_enabled';
  static const String _aiChatEnabledKey = 'feature_ai_chat_enabled';
  static const String _aiServerUrlKey = 'feature_ai_server_url';

  // Default values
  static const bool _defaultOmiEnabled = false;
  static const bool _defaultAiChatEnabled =
      false; // Off by default - power users can enable in settings
  static const String _defaultAiServerUrl = 'http://localhost:3333';

  // Cache for quick access
  bool? _omiEnabled;
  bool? _aiChatEnabled;
  String? _aiServerUrl;

  /// Check if Omi device integration is enabled
  Future<bool> isOmiEnabled() async {
    if (_omiEnabled != null) return _omiEnabled!;

    final prefs = await SharedPreferences.getInstance();
    _omiEnabled = prefs.getBool(_omiEnabledKey) ?? _defaultOmiEnabled;
    debugPrint('[FeatureFlags] Omi enabled: $_omiEnabled');
    return _omiEnabled!;
  }

  /// Set Omi device integration enabled state
  Future<void> setOmiEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_omiEnabledKey, enabled);
    _omiEnabled = enabled;
    debugPrint('[FeatureFlags] Set Omi enabled: $enabled');
  }

  /// Check if AI Chat is enabled
  Future<bool> isAiChatEnabled() async {
    if (_aiChatEnabled != null) return _aiChatEnabled!;

    final prefs = await SharedPreferences.getInstance();
    _aiChatEnabled = prefs.getBool(_aiChatEnabledKey) ?? _defaultAiChatEnabled;
    debugPrint('[FeatureFlags] AI Chat enabled: $_aiChatEnabled');
    return _aiChatEnabled!;
  }

  /// Set AI Chat enabled state
  Future<void> setAiChatEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_aiChatEnabledKey, enabled);
    _aiChatEnabled = enabled;
    debugPrint('[FeatureFlags] Set AI Chat enabled: $enabled');
  }

  /// Get AI server URL
  Future<String> getAiServerUrl() async {
    if (_aiServerUrl != null) return _aiServerUrl!;

    final prefs = await SharedPreferences.getInstance();
    _aiServerUrl = prefs.getString(_aiServerUrlKey) ?? _defaultAiServerUrl;
    debugPrint('[FeatureFlags] AI server URL: $_aiServerUrl');
    return _aiServerUrl!;
  }

  /// Set AI server URL
  Future<void> setAiServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_aiServerUrlKey, url);
    _aiServerUrl = url;
    debugPrint('[FeatureFlags] Set AI server URL: $url');
  }

  /// Clear all cached values (call when settings change)
  void clearCache() {
    _omiEnabled = null;
    _aiChatEnabled = null;
    _aiServerUrl = null;
    debugPrint('[FeatureFlags] Cache cleared');
  }

  /// Reset all features to defaults
  Future<void> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_omiEnabledKey, _defaultOmiEnabled);
    await prefs.setBool(_aiChatEnabledKey, _defaultAiChatEnabled);
    await prefs.setString(_aiServerUrlKey, _defaultAiServerUrl);
    clearCache();
    debugPrint('[FeatureFlags] Reset to defaults');
  }
}
