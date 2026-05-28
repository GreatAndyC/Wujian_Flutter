import 'dart:convert';
import 'dart:io';

import '../../domain/entities/app_settings.dart';
import '../../domain/entities/item_record.dart';
import '../../domain/entities/recognition_result.dart';
import '../../domain/repositories/recognition_repository.dart';

class OpenAiCompatibleRecognitionRepository implements RecognitionRepository {
  static const _defaultPrompt = '''
你是家庭物品整理助手。请根据图片识别一个主要物品，并严格只返回 JSON，不要包含 markdown。

字段要求：
{
  "name": "物品名称",
  "category": "分类",
  "quantity": 1,
  "description": "一句简洁说明",
  "room": "推荐房间",
  "box": "推荐箱号，没有就留空",
  "brand": "品牌，没有就留空",
  "model": "型号，没有就留空",
  "color": "颜色，没有就留空",
  "material": "材质，没有就留空",
  "notes": "补充说明，没有就留空",
  "status": "pending",
  "parameters": {
    "尺寸": "",
    "用途": "",
    "成色": ""
  }
}

要求：
1. category 用中文短词，例如：厨房、清洁、数码、家具、衣物、书籍、杂物。
2. quantity 必须是整数。
3. status 只能是 pending、cataloged、boxed、moved 之一。
4. 无法确认时，宁可保守，避免编造。
''';

  @override
  Future<RecognitionResult> recognizeItem({
    required AppSettings settings,
    required List<int> imageBytes,
    required String mimeType,
  }) async {
    if (!settings.isConfigured) {
      return _mockResult();
    }

    final client = HttpClient();
    final endpoint = Uri.parse(
      '${settings.normalizedBaseUrl}/chat/completions',
    );
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    _applyHeaders(request, settings);

    final prompt = settings.customPrompt.trim().isEmpty
        ? _defaultPrompt
        : '${settings.customPrompt.trim()}\n\n$_defaultPrompt';

    request.write(
      jsonEncode({
        'model': settings.model,
        'temperature': 0.2,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': prompt},
              {
                'type': 'image_url',
                'image_url': {
                  'url': 'data:$mimeType;base64,${base64Encode(imageBytes)}',
                  'detail': 'high',
                },
              },
            ],
          },
        ],
      }),
    );

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    client.close();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('识别请求失败: ${response.statusCode} $responseBody');
    }

    final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>? ?? const [];
    if (choices.isEmpty) {
      throw const FormatException('识别响应为空');
    }

    final usage = decoded['usage'] as Map<String, dynamic>? ?? const {};
    final message =
        choices.first['message'] as Map<String, dynamic>? ?? const {};
    final content = message['content'];
    final text = switch (content) {
      String value => value,
      List<dynamic> value =>
        value
            .map(
              (entry) => entry is Map<String, dynamic> ? entry['text'] : null,
            )
            .whereType<String>()
            .join('\n'),
      _ => '',
    };

    if (text.trim().isEmpty) {
      throw const FormatException('识别响应缺少内容');
    }

    return _parseResult(text, usage);
  }

  @override
  Future<void> testConnection(AppSettings settings) async {
    if (!settings.isConfigured) {
      throw const FormatException('请先填写 Base URL、API Key 和模型 ID');
    }

    final client = HttpClient();
    final endpoint = Uri.parse(
      '${settings.normalizedBaseUrl}/chat/completions',
    );
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    _applyHeaders(request, settings);
    request.write(
      jsonEncode({
        'model': settings.model,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '只回复 OK'},
            ],
          },
        ],
        'max_tokens': 16,
      }),
    );

    final response = await request.close();
    final responseBody = await response.transform(utf8.decoder).join();
    client.close();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('连接失败: ${response.statusCode} $responseBody');
    }
  }

  RecognitionResult _parseResult(String rawText, Map<String, dynamic> usage) {
    final normalized = rawText
        .replaceAll('```json', '')
        .replaceAll('```', '')
        .trim();
    final decoded = jsonDecode(normalized) as Map<String, dynamic>;
    final parameters = Map<String, String>.from(
      (decoded['parameters'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      ),
    )..removeWhere((key, value) => value.trim().isEmpty);

    return RecognitionResult(
      name: decoded['name'] as String? ?? '待确认物品',
      category: decoded['category'] as String? ?? '待分类',
      quantity: (decoded['quantity'] as num?)?.toInt() ?? 1,
      description: decoded['description'] as String? ?? '等待确认识别内容',
      parameters: parameters,
      room: decoded['room'] as String? ?? '',
      box: decoded['box'] as String? ?? '',
      brand: decoded['brand'] as String? ?? '',
      model: decoded['model'] as String? ?? '',
      color: decoded['color'] as String? ?? '',
      material: decoded['material'] as String? ?? '',
      notes: decoded['notes'] as String? ?? '',
      status: ItemStatus.values.firstWhere(
        (value) => value.name == decoded['status'],
        orElse: () => ItemStatus.pending,
      ),
      rawResponse: normalized,
      promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      completionTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
      totalTokens: (usage['total_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  RecognitionResult _mockResult() {
    return const RecognitionResult(
      name: '待确认物品',
      category: '待分类',
      quantity: 1,
      description: '尚未配置多模态识别 API，当前以待确认记录入库。',
      parameters: {'识别模式': '本地占位'},
      room: '',
      box: '',
      brand: '',
      model: '',
      color: '',
      material: '',
      notes: '前往设置页填写 API 信息后，可启用图片识别。',
      status: ItemStatus.pending,
      rawResponse: '',
      promptTokens: 0,
      completionTokens: 0,
      totalTokens: 0,
    );
  }

  void _applyHeaders(HttpClientRequest request, AppSettings settings) {
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${settings.apiKey}',
    );

    if (settings.providerId == 'openrouter') {
      request.headers.set('X-Title', '物见');
    }
  }
}
