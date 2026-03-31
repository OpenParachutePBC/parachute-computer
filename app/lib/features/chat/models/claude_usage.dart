// Models for Claude usage tracking
//
// Represents usage limits from Claude's OAuth API.

/// A single usage limit bucket (5-hour, 7-day, etc.)
class UsageLimit {
  /// Percentage of the limit used (0-100)
  final double utilization;

  /// When this limit resets (ISO datetime string)
  final String? resetsAt;

  const UsageLimit({
    required this.utilization,
    this.resetsAt,
  });

  factory UsageLimit.fromJson(Map<String, dynamic> json) {
    return UsageLimit(
      utilization: (json['utilization'] as num?)?.toDouble() ?? 0,
      resetsAt: json['resets_at'] as String?,
    );
  }

  /// Parse the reset time to a DateTime
  DateTime? get resetsAtDateTime {
    if (resetsAt == null) return null;
    try {
      return DateTime.parse(resetsAt!);
    } catch (e) {
      return null;
    }
  }

  /// Get human-readable time until reset
  String get resetsIn {
    final resetTime = resetsAtDateTime;
    if (resetTime == null) return '';

    final now = DateTime.now().toUtc();
    final diff = resetTime.difference(now);

    if (diff.isNegative) return 'now';

    if (diff.inHours > 0) {
      return '${diff.inHours}h ${diff.inMinutes % 60}m';
    } else if (diff.inMinutes > 0) {
      return '${diff.inMinutes}m';
    } else {
      return '<1m';
    }
  }
}

class ExtraUsage {
  final bool isEnabled;
  final int monthlyLimit;
  final double usedCredits;
  final double utilization;

  const ExtraUsage({
    required this.isEnabled,
    required this.monthlyLimit,
    required this.usedCredits,
    required this.utilization,
  });

  factory ExtraUsage.fromJson(Map<String, dynamic> json) {
    return ExtraUsage(
      isEnabled: json['is_enabled'] as bool? ?? false,
      monthlyLimit: json['monthly_limit'] as int? ?? 0,
      usedCredits: (json['used_credits'] as num?)?.toDouble() ?? 0,
      utilization: (json['utilization'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Remaining credits
  double get remaining => monthlyLimit - usedCredits;
}

class ClaudeUsage {
  /// 5-hour rolling window usage
  final UsageLimit? fiveHour;

  /// 7-day rolling window usage
  final UsageLimit? sevenDay;

  /// 7-day Sonnet-specific usage
  final UsageLimit? sevenDaySonnet;

  /// 7-day Opus-specific usage
  final UsageLimit? sevenDayOpus;

  /// Extra usage credits (Max plan)
  final ExtraUsage? extraUsage;

  /// Subscription type (e.g., "pro", "max")
  final String? subscriptionType;

  /// Rate limit tier
  final String? rateLimitTier;

  /// Error message if fetch failed
  final String? error;

  const ClaudeUsage({
    this.fiveHour,
    this.sevenDay,
    this.sevenDaySonnet,
    this.sevenDayOpus,
    this.extraUsage,
    this.subscriptionType,
    this.rateLimitTier,
    this.error,
  });

  factory ClaudeUsage.fromJson(Map<String, dynamic> json) {
    return ClaudeUsage(
      fiveHour: json['five_hour'] != null
          ? UsageLimit.fromJson(json['five_hour'] as Map<String, dynamic>)
          : null,
      sevenDay: json['seven_day'] != null
          ? UsageLimit.fromJson(json['seven_day'] as Map<String, dynamic>)
          : null,
      sevenDaySonnet: json['seven_day_sonnet'] != null
          ? UsageLimit.fromJson(json['seven_day_sonnet'] as Map<String, dynamic>)
          : null,
      sevenDayOpus: json['seven_day_opus'] != null
          ? UsageLimit.fromJson(json['seven_day_opus'] as Map<String, dynamic>)
          : null,
      extraUsage: json['extra_usage'] != null
          ? ExtraUsage.fromJson(json['extra_usage'] as Map<String, dynamic>)
          : null,
      subscriptionType: json['subscription_type'] as String?,
      rateLimitTier: json['rate_limit_tier'] as String?,
      error: json['error'] as String?,
    );
  }

  /// Whether this usage data contains an error
  bool get hasError => error != null && error!.isNotEmpty;

  /// Whether usage data is available
  bool get hasData => fiveHour != null || sevenDay != null;

  /// Friendly subscription name
  String get subscriptionName {
    switch (subscriptionType) {
      case 'max':
        return 'Max';
      case 'pro':
        return 'Pro';
      default:
        return subscriptionType ?? 'Unknown';
    }
  }
}
