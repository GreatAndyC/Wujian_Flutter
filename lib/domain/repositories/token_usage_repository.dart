import '../entities/token_usage_stats.dart';

abstract interface class TokenUsageRepository {
  Future<Map<String, TokenUsageStats>> loadUsageStats();

  Future<void> saveUsageStats(Map<String, TokenUsageStats> statsByProfileId);
}
