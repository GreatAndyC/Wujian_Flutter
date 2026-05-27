import 'app_settings.dart';

class AppSettingsProfile {
  const AppSettingsProfile({
    required this.id,
    required this.name,
    required this.settings,
  });

  factory AppSettingsProfile.initial() {
    return AppSettingsProfile(
      id: 'default',
      name: '默认配置',
      settings: AppSettings.initial(),
    );
  }

  final String id;
  final String name;
  final AppSettings settings;

  AppSettingsProfile copyWith({
    String? id,
    String? name,
    AppSettings? settings,
  }) {
    return AppSettingsProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      settings: settings ?? this.settings,
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'name': name, 'settings': settings.toJson()};
  }

  factory AppSettingsProfile.fromJson(
    Map<String, dynamic> json, {
    String apiKey = '',
  }) {
    return AppSettingsProfile(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? '未命名配置',
      settings: AppSettings.fromJson(
        json['settings'] as Map<String, dynamic>? ?? const {},
        apiKey: apiKey,
      ),
    );
  }
}
