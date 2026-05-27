import 'app_settings_profile.dart';

class AppSettingsStore {
  const AppSettingsStore({
    required this.activeProfileId,
    required this.profiles,
  });

  factory AppSettingsStore.initial() {
    final profile = AppSettingsProfile.initial();
    return AppSettingsStore(activeProfileId: profile.id, profiles: [profile]);
  }

  final String activeProfileId;
  final List<AppSettingsProfile> profiles;

  AppSettingsProfile get activeProfile {
    return profiles.firstWhere(
      (profile) => profile.id == activeProfileId,
      orElse: () => profiles.first,
    );
  }

  AppSettingsStore copyWith({
    String? activeProfileId,
    List<AppSettingsProfile>? profiles,
  }) {
    return AppSettingsStore(
      activeProfileId: activeProfileId ?? this.activeProfileId,
      profiles: profiles ?? this.profiles,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'activeProfileId': activeProfileId,
      'profiles': profiles.map((profile) => profile.toJson()).toList(),
    };
  }

  factory AppSettingsStore.fromJson(
    Map<String, dynamic> json, {
    Map<String, String> apiKeys = const {},
  }) {
    final rawProfiles = json['profiles'] as List<dynamic>? ?? const [];
    final profiles = rawProfiles.map((entry) {
      final json = entry as Map<String, dynamic>;
      return AppSettingsProfile.fromJson(
        json,
        apiKey: apiKeys[json['id']] ?? '',
      );
    }).toList();

    if (profiles.isEmpty) {
      return AppSettingsStore.initial();
    }

    final activeProfileId =
        json['activeProfileId'] as String? ?? profiles.first.id;
    return AppSettingsStore(
      activeProfileId: profiles.any((profile) => profile.id == activeProfileId)
          ? activeProfileId
          : profiles.first.id,
      profiles: profiles,
    );
  }
}
