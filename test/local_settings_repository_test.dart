import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/repositories/local_settings_repository.dart';
import 'package:icheck/domain/entities/app_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('安全存储读取失败时仍能完成启动并使用空 API Key', () async {
    final repository = LocalSettingsRepository(
      secureValueReader: (_) async {
        throw PlatformException(code: '-34018');
      },
      secureValueWriter: (_, _) async {},
    );

    final store = await repository.loadSettingsStore();

    expect(store.activeProfile.settings.apiKey, isEmpty);
  });

  test('安全存储写入失败时不把无密钥配置误报为已保存', () async {
    final repository = LocalSettingsRepository(
      secureValueReader: (_) async => null,
      secureValueWriter: (_, _) async {
        throw PlatformException(code: '-34018');
      },
    );

    await expectLater(
      repository.saveSettingsStore(AppSettingsStore.initial()),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains('API Key 未保存'),
        ),
      ),
    );
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('app_settings_store'), isNull);
  });

  test('损坏的设置 JSON 不会阻断启动', () async {
    SharedPreferences.setMockInitialValues({
      'app_settings_store': '{broken json',
    });
    final repository = LocalSettingsRepository(
      secureValueReader: (_) async => null,
      secureValueWriter: (_, _) async {},
    );

    final store = await repository.loadSettingsStore();

    expect(store.profiles, hasLength(1));
    expect(store.activeProfileId, 'default');
  });
}
