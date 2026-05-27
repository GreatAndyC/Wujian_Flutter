import '../entities/app_settings_store.dart';

abstract interface class SettingsRepository {
  Future<AppSettingsStore> loadSettingsStore();

  Future<void> saveSettingsStore(AppSettingsStore store);
}
