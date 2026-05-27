import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/token_usage_stats.dart';
import '../../domain/repositories/token_usage_repository.dart';

class LocalTokenUsageRepository implements TokenUsageRepository {
  static const _usageStatsKey = 'token_usage_stats';

  @override
  Future<Map<String, TokenUsageStats>> loadUsageStats() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_usageStatsKey);
    if (raw == null || raw.isEmpty) {
      return {};
    }

    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (key, value) => MapEntry(
        key,
        TokenUsageStats.fromJson(value as Map<String, dynamic>),
      ),
    );
  }

  @override
  Future<void> saveUsageStats(
    Map<String, TokenUsageStats> statsByProfileId,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _usageStatsKey,
      jsonEncode(
        statsByProfileId.map((key, value) => MapEntry(key, value.toJson())),
      ),
    );
  }
}
