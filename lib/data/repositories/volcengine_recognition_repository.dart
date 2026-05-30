import 'dart:convert';
import 'dart:io';

import '../../domain/entities/app_settings.dart';
import '../../domain/entities/item_record.dart';
import '../../domain/entities/recognition_result.dart';
import '../../domain/repositories/recognition_repository.dart';

class OpenAiCompatibleRecognitionRepository implements RecognitionRepository {
  static const _xiaomiVisionModels = {'mimo-v2.5', 'mimo-v2-omni'};
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
5. 如果识别结果是书，category 必须填 "书籍"，name 必须优先使用封面可见的书名。
6. 如果是书籍，请将 parameters 改为书籍专用字段，并尽量只填写封面明确可见的信息：
{
  "书名": "封面主标题",
  "副标题": "",
  "作者": "",
  "出版社": "",
  "丛书/系列": "",
  "卷册信息": "",
  "版次": "",
  "语言": "",
  "装帧": "",
  "是否教材/教辅": "是/否",
  "适读对象": ""
}
7. 书籍场景下：
- brand、model、color、material 默认留空，除非封面明确值得保留。
- description 用一句话概括这本书，例如题材、用途或阅读对象。
- notes 只写低置信补充，例如“出版社可能识别不清”。
8. 只拍封面时，不要编造 ISBN、出版时间、印次、定价、开本、页数等通常需要封底或版权页才能确认的信息。
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
    final model = _effectiveRecognitionModel(settings);

    request.write(
      jsonEncode({
        'model': model,
        'temperature': 0.2,
        'max_completion_tokens': 1024,
        'messages': [
          if (_isXiaomiProvider(settings))
            {
              'role': 'system',
              'content':
                  '你是MiMo（中文名称也是MiMo），是小米公司研发的AI智能助手。今天的日期请以系统时间为准，你的知识截止日期是2024年12月。',
            },
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
    final text = _extractMessageText(
      message: message,
      choice: choices.first,
      root: decoded,
    );

    if (text.trim().isEmpty) {
      throw FormatException(
        '识别响应缺少内容：${_compactResponseSnippet(responseBody)}',
      );
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
        if (_isXiaomiProvider(settings))
          'max_completion_tokens': 16
        else
          'max_tokens': 16,
        'messages': [
          if (_isXiaomiProvider(settings))
            {
              'role': 'system',
              'content':
                  '你是MiMo（中文名称也是MiMo），是小米公司研发的AI智能助手。只回复 OK。',
            },
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '只回复 OK'},
            ],
          },
        ],
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
    final category = (decoded['category'] as String? ?? '待分类').trim();
    final parameters = Map<String, String>.from(
      (decoded['parameters'] as Map? ?? const {}).map(
        (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
      ),
    )..removeWhere((key, value) => value.trim().isEmpty);
    final normalizedParameters = _normalizeParametersForCategory(
      category: category,
      parameters: parameters,
    );
    final normalizedName = _normalizeNameForCategory(
      category: category,
      rawName: decoded['name'] as String?,
      parameters: normalizedParameters,
    );

    return RecognitionResult(
      name: normalizedName,
      category: category.isEmpty ? '待分类' : category,
      quantity: (decoded['quantity'] as num?)?.toInt() ?? 1,
      description: decoded['description'] as String? ?? '等待确认识别内容',
      parameters: normalizedParameters,
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

    if (_isXiaomiProvider(settings)) {
      request.headers.set('api-key', settings.apiKey);
    }

    if (settings.providerId == 'openrouter') {
      request.headers.set('X-Title', '物见');
    }
  }

  bool _isXiaomiProvider(AppSettings settings) {
    return settings.providerId == 'xiaomi-payg' ||
        settings.providerId == 'xiaomi-token-plan';
  }

  String _effectiveRecognitionModel(AppSettings settings) {
    final model = settings.model.trim();
    if (!_isXiaomiProvider(settings)) {
      return model;
    }
    if (_xiaomiVisionModels.contains(model)) {
      return model;
    }
    // Xiaomi image understanding currently requires a vision-capable model.
    return 'mimo-v2.5';
  }

  String _extractMessageText({
    required Map<String, dynamic> message,
    required dynamic choice,
    required Map<String, dynamic> root,
  }) {
    final content = message['content'];
    final textFromContent = _extractTextFromUnknown(content);
    if (textFromContent.trim().isNotEmpty) {
      return textFromContent;
    }

    final directMessageFields = [
      message['text'],
      message['output_text'],
      message['reasoning_content'],
      message['refusal'],
    ];
    for (final field in directMessageFields) {
      final text = _extractTextFromUnknown(field);
      if (text.trim().isNotEmpty) {
        return text;
      }
    }

    if (choice is Map<String, dynamic>) {
      final text = _extractTextFromUnknown(choice['text']);
      if (text.trim().isNotEmpty) {
        return text;
      }
    }

    final rootLevelCandidates = [
      root['output_text'],
      root['response'],
      root['text'],
    ];
    for (final candidate in rootLevelCandidates) {
      final text = _extractTextFromUnknown(candidate);
      if (text.trim().isNotEmpty) {
        return text;
      }
    }

    return '';
  }

  String _extractTextFromUnknown(dynamic value) {
    if (value == null) {
      return '';
    }
    if (value is String) {
      return value;
    }
    if (value is List) {
      return value
          .map((entry) {
            if (entry is String) {
              return entry;
            }
            if (entry is Map<String, dynamic>) {
              final candidates = [
                entry['text'],
                entry['output_text'],
                entry['content'],
                entry['reasoning_content'],
                entry['refusal'],
              ];
              for (final candidate in candidates) {
                final text = _extractTextFromUnknown(candidate);
                if (text.trim().isNotEmpty) {
                  return text;
                }
              }
            }
            return '';
          })
          .where((entry) => entry.trim().isNotEmpty)
          .join('\n');
    }
    if (value is Map<String, dynamic>) {
      final candidates = [
        value['text'],
        value['output_text'],
        value['content'],
        value['reasoning_content'],
        value['refusal'],
      ];
      for (final candidate in candidates) {
        final text = _extractTextFromUnknown(candidate);
        if (text.trim().isNotEmpty) {
          return text;
        }
      }
    }
    return '';
  }

  String _compactResponseSnippet(String responseBody) {
    final compact = responseBody.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 240) {
      return compact;
    }
    return '${compact.substring(0, 240)}...';
  }

  Map<String, String> _normalizeParametersForCategory({
    required String category,
    required Map<String, String> parameters,
  }) {
    if (!_isBookCategory(category)) {
      return parameters;
    }

    final normalized = <String, String>{};
    const orderedBookKeys = [
      '书名',
      '副标题',
      '作者',
      '出版社',
      '丛书/系列',
      '卷册信息',
      '版次',
      '语言',
      '装帧',
      '是否教材/教辅',
      '适读对象',
    ];
    for (final key in orderedBookKeys) {
      final value = parameters[key]?.trim();
      if (value != null && value.isNotEmpty) {
        normalized[key] = value;
      }
    }
    for (final entry in parameters.entries) {
      if (!normalized.containsKey(entry.key) && entry.value.trim().isNotEmpty) {
        normalized[entry.key] = entry.value.trim();
      }
    }
    return normalized;
  }

  String _normalizeNameForCategory({
    required String category,
    required String? rawName,
    required Map<String, String> parameters,
  }) {
    final trimmedName = rawName?.trim() ?? '';
    if (_isBookCategory(category)) {
      final title = parameters['书名']?.trim() ?? '';
      if (title.isNotEmpty) {
        return title;
      }
    }
    return trimmedName.isEmpty ? '待确认物品' : trimmedName;
  }

  bool _isBookCategory(String category) {
    return category.contains('书');
  }
}
