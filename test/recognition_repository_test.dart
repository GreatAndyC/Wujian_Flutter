import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/repositories/volcengine_recognition_repository.dart';
import 'package:icheck/domain/entities/app_settings.dart';

void main() {
  test('允许本机 HTTP 服务并正确解析兼容响应', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'name': '马克杯',
                  'category': '厨房',
                  'quantity': 1,
                  'description': '白色马克杯',
                  'status': 'pending',
                  'parameters': {'容量': '350ml'},
                }),
              },
            },
          ],
          'usage': {
            'prompt_tokens': 10,
            'completion_tokens': 5,
            'total_tokens': 15,
          },
        }),
      );
      await request.response.close();
    });

    final result = await OpenAiCompatibleRecognitionRepository().recognizeItem(
      settings: _settings('http://127.0.0.1:${server.port}'),
      imageBytes: const [1, 2, 3],
      mimeType: 'image/jpeg',
    );

    expect(result.name, '马克杯');
    expect(result.parameters['容量'], '350ml');
    expect(result.totalTokens, 15);
  });

  test('拒绝向远程明文 HTTP 地址发送 API Key 和照片', () async {
    final repository = OpenAiCompatibleRecognitionRepository();

    await expectLater(
      repository.testConnection(_settings('http://example.com/api')),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('HTTPS'),
        ),
      ),
    );
  });

  test('响应超过超时时间后结束请求而不是永久阻塞队列', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      await request.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      try {
        request.response.write('{}');
        await request.response.close();
      } on HttpException {
        // The client is expected to close the timed-out request.
      }
    });
    final repository = OpenAiCompatibleRecognitionRepository(
      connectionTimeout: const Duration(milliseconds: 100),
      responseTimeout: const Duration(milliseconds: 50),
    );

    await expectLater(
      repository.testConnection(_settings('http://127.0.0.1:${server.port}')),
      throwsA(isA<TimeoutException>()),
    );
  });
}

AppSettings _settings(String baseUrl) {
  return AppSettings(
    providerId: 'custom',
    baseUrl: baseUrl,
    apiKey: 'test-key',
    model: 'test-model',
    customPrompt: '',
  );
}
