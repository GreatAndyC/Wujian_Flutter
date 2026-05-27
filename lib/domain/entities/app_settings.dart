class AppSettings {
  const AppSettings({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.customPrompt,
  });

  factory AppSettings.initial() {
    return const AppSettings(
      baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
      apiKey: '',
      model: 'doubao-seed-2-0-mini-260428',
      customPrompt: '',
    );
  }

  final String baseUrl;
  final String apiKey;
  final String model;
  final String customPrompt;

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  AppSettings copyWith({
    String? baseUrl,
    String? apiKey,
    String? model,
    String? customPrompt,
  }) {
    return AppSettings(
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      customPrompt: customPrompt ?? this.customPrompt,
    );
  }

  Map<String, dynamic> toJson() {
    return {'baseUrl': baseUrl, 'model': model, 'customPrompt': customPrompt};
  }

  factory AppSettings.fromJson(
    Map<String, dynamic> json, {
    String apiKey = '',
  }) {
    return AppSettings(
      baseUrl: json['baseUrl'] as String? ?? AppSettings.initial().baseUrl,
      apiKey: apiKey,
      model: json['model'] as String? ?? AppSettings.initial().model,
      customPrompt: json['customPrompt'] as String? ?? '',
    );
  }
}
