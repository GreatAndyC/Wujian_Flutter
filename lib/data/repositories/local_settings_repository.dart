import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/app_settings_store.dart';
import '../../domain/repositories/settings_repository.dart';

class LocalSettingsRepository implements SettingsRepository {
  static const _settingsKey = 'app_settings_store';
  static const _apiKeysField = 'volcengine_api_keys';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  @override
  Future<AppSettingsStore> loadSettingsStore() async {
    final preferences = await SharedPreferences.getInstance();
    final rawStore = preferences.getString(_settingsKey);
    final rawApiKeys = await _secureStorage.read(key: _apiKeysField);
    final apiKeys = rawApiKeys == null || rawApiKeys.isEmpty
        ? <String, String>{}
        : Map<String, String>.from(
            jsonDecode(rawApiKeys) as Map<String, dynamic>,
          );

    if (rawStore == null || rawStore.isEmpty) {
      final store = AppSettingsStore.initial();
      final profile = store.activeProfile;
      if (apiKeys.containsKey(profile.id)) {
        return store.copyWith(
          profiles: [
            profile.copyWith(
              settings: profile.settings.copyWith(apiKey: apiKeys[profile.id]!),
            ),
          ],
        );
      }
      return store;
    }

    return AppSettingsStore.fromJson(
      jsonDecode(rawStore) as Map<String, dynamic>,
      apiKeys: apiKeys,
    );
  }

  @override
  Future<void> saveSettingsStore(AppSettingsStore store) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_settingsKey, jsonEncode(store.toJson()));
    final apiKeys = {
      for (final profile in store.profiles) profile.id: profile.settings.apiKey,
    };
    await _secureStorage.write(key: _apiKeysField, value: jsonEncode(apiKeys));
  }
}
