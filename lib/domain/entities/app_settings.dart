import 'ai_provider_preset.dart';

class AppSettings {
  const AppSettings({
    required this.providerId,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    required this.customPrompt,
  });

  factory AppSettings.initial() {
    return const AppSettings(
      providerId: 'volcengine',
      baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
      apiKey: '',
      model: 'doubao-seed-2-0-mini-260428',
      customPrompt: '',
    );
  }

  final String providerId;
  final String baseUrl;
  final String apiKey;
  final String model;
  final String customPrompt;

  AiProviderPreset get providerPreset => AiProviderPreset.fromId(providerId);

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  String get normalizedBaseUrl {
    final value = baseUrl.trim();
    if (value.endsWith('/')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }

  AppSettings copyWith({
    String? providerId,
    String? baseUrl,
    String? apiKey,
    String? model,
    String? customPrompt,
  }) {
    return AppSettings(
      providerId: providerId ?? this.providerId,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      customPrompt: customPrompt ?? this.customPrompt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'providerId': providerId,
      'baseUrl': baseUrl,
      'model': model,
      'customPrompt': customPrompt,
    };
  }

  factory AppSettings.fromJson(
    Map<String, dynamic> json, {
    String apiKey = '',
  }) {
    return AppSettings(
      providerId:
          json['providerId'] as String? ?? AppSettings.initial().providerId,
      baseUrl: json['baseUrl'] as String? ?? AppSettings.initial().baseUrl,
      apiKey: apiKey,
      model: json['model'] as String? ?? AppSettings.initial().model,
      customPrompt: json['customPrompt'] as String? ?? '',
    );
  }
}
