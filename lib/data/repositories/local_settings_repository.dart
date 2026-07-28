import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/app_settings_store.dart';
import '../../domain/repositories/settings_repository.dart';

typedef SecureValueReader = Future<String?> Function(String key);
typedef SecureValueWriter = Future<void> Function(String key, String value);

class LocalSettingsRepository implements SettingsRepository {
  LocalSettingsRepository({
    SecureValueReader? secureValueReader,
    SecureValueWriter? secureValueWriter,
  }) : _secureValueReader =
           secureValueReader ??
           ((key) => const FlutterSecureStorage().read(key: key)),
       _secureValueWriter =
           secureValueWriter ??
           ((key, value) =>
               const FlutterSecureStorage().write(key: key, value: value));

  static const _settingsKey = 'app_settings_store';
  static const _apiKeysField = 'llm_api_keys';
  static const _legacyApiKeysField = 'volcengine_api_keys';

  final SecureValueReader _secureValueReader;
  final SecureValueWriter _secureValueWriter;

  @override
  Future<AppSettingsStore> loadSettingsStore() async {
    final preferences = await SharedPreferences.getInstance();
    final rawStore = preferences.getString(_settingsKey);
    final rawApiKeys = await _readStoredApiKeys();
    final apiKeys = _decodeApiKeys(rawApiKeys);

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

    try {
      return AppSettingsStore.fromJson(
        jsonDecode(rawStore) as Map<String, dynamic>,
        apiKeys: apiKeys,
      );
    } on FormatException {
      return AppSettingsStore.initial();
    } on TypeError {
      return AppSettingsStore.initial();
    }
  }

  @override
  Future<void> saveSettingsStore(AppSettingsStore store) async {
    final apiKeys = {
      for (final profile in store.profiles) profile.id: profile.settings.apiKey,
    };
    try {
      await _secureValueWriter(_apiKeysField, jsonEncode(apiKeys));
    } on PlatformException {
      throw Exception('系统安全存储不可用，API Key 未保存，请检查应用签名与钥匙串权限');
    } on MissingPluginException {
      throw Exception('系统安全存储插件不可用，API Key 未保存');
    }

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_settingsKey, jsonEncode(store.toJson()));
  }

  Future<String?> _readStoredApiKeys() async {
    try {
      return await _secureValueReader(_apiKeysField) ??
          await _secureValueReader(_legacyApiKeysField);
    } on PlatformException {
      // A missing entitlement must not leave the app permanently on its
      // launch screen. The settings UI can still be opened to repair it.
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Map<String, String> _decodeApiKeys(String? rawApiKeys) {
    if (rawApiKeys == null || rawApiKeys.isEmpty) {
      return {};
    }
    try {
      return Map<String, String>.from(
        jsonDecode(rawApiKeys) as Map<String, dynamic>,
      );
    } on FormatException {
      return {};
    } on TypeError {
      return {};
    }
  }
}
