class TokenUsageStats {
  const TokenUsageStats({
    required this.requestCount,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.lastUpdatedAt,
  });

  factory TokenUsageStats.empty() {
    return const TokenUsageStats(
      requestCount: 0,
      promptTokens: 0,
      completionTokens: 0,
      totalTokens: 0,
      lastUpdatedAt: '',
    );
  }

  final int requestCount;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final String lastUpdatedAt;

  TokenUsageStats add({
    required int promptTokens,
    required int completionTokens,
    required int totalTokens,
  }) {
    return TokenUsageStats(
      requestCount: requestCount + 1,
      promptTokens: this.promptTokens + promptTokens,
      completionTokens: this.completionTokens + completionTokens,
      totalTokens: this.totalTokens + totalTokens,
      lastUpdatedAt: DateTime.now().toIso8601String(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'requestCount': requestCount,
      'promptTokens': promptTokens,
      'completionTokens': completionTokens,
      'totalTokens': totalTokens,
      'lastUpdatedAt': lastUpdatedAt,
    };
  }

  factory TokenUsageStats.fromJson(Map<String, dynamic> json) {
    return TokenUsageStats(
      requestCount: (json['requestCount'] as num?)?.toInt() ?? 0,
      promptTokens: (json['promptTokens'] as num?)?.toInt() ?? 0,
      completionTokens: (json['completionTokens'] as num?)?.toInt() ?? 0,
      totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
      lastUpdatedAt: json['lastUpdatedAt'] as String? ?? '',
    );
  }
}
