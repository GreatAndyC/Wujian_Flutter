import 'package:flutter/material.dart';

import '../../domain/entities/ai_provider_preset.dart';
import '../../domain/entities/app_settings.dart';
import '../../domain/entities/app_settings_profile.dart';
import '../../domain/entities/storage_usage_summary.dart';
import '../../domain/entities/token_usage_stats.dart';
import '../shell/app_controller.dart';
import '../shell/app_scope.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _profileNameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  late final TextEditingController _promptController;
  AppController? _controller;
  String? _boundProfileId;

  @override
  void initState() {
    super.initState();
    _profileNameController = TextEditingController();
    _baseUrlController = TextEditingController();
    _apiKeyController = TextEditingController();
    _modelController = TextEditingController();
    _promptController = TextEditingController();
  }

  @override
  void dispose() {
    _controller?.removeListener(_handleControllerChanged);
    _profileNameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextController = AppScope.of(context);
    if (!identical(_controller, nextController)) {
      _controller?.removeListener(_handleControllerChanged);
      _controller = nextController;
      _controller!.addListener(_handleControllerChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _bindProfile(nextController.activeProfile);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller ?? AppScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final modelItems = _modelItems(
          controller.activeProfile.settings.providerId,
        );
        final selectedModel = _selectedModelValue(
          items: modelItems,
          currentModel: _modelController.text,
        );
        return ListView(
          key: const ValueKey('settings-page'),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          children: [
            Text('设置', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '这里可以管理多个多模态识别配置，并查看 token 消耗和本地存储占用。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            _UsageSection(
              activeStats: controller.activeUsageStats,
              overallStats: controller.overallUsageStats,
              activeProfileName: controller.activeProfile.name,
            ),
            const SizedBox(height: 18),
            _StorageSection(
              usage: controller.storageUsage,
              isBusy: controller.isBusy,
              onOptimize: () => controller.optimizeStorage(),
            ),
            const SizedBox(height: 18),
            _DropdownField<String>(
              label: '当前配置',
              value: controller.activeProfile.id,
              items: controller.profiles
                  .map(
                    (profile) => DropdownMenuItem(
                      value: profile.id,
                      child: Text(profile.name),
                    ),
                  )
                  .toList(),
              onChanged: (value) async {
                if (value == null) {
                  return;
                }
                await controller.selectProfile(value);
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _createProfile,
                    child: const Text('新建配置'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: controller.profiles.length == 1
                        ? null
                        : () => controller.deleteProfile(
                            controller.activeProfile.id,
                          ),
                    child: const Text('删除当前配置'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _profileNameController,
              decoration: const InputDecoration(labelText: '配置名称'),
            ),
            const SizedBox(height: 12),
            _DropdownField<String>(
              label: '服务商预设',
              value: controller.activeProfile.settings.providerId,
              items: AiProviderPreset.values
                  .map(
                    (preset) => DropdownMenuItem(
                      value: preset.id,
                      child: Text(preset.label),
                    ),
                  )
                  .toList(),
              onChanged: (value) async {
                if (value == null) {
                  return;
                }
                await _applyProviderPreset(value);
              },
            ),
            const SizedBox(height: 12),
            _ProviderPresetCard(
              preset: AiProviderPreset.fromId(
                controller.activeProfile.settings.providerId,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: '填写兼容 OpenAI chat/completions 的基础地址',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: '填写对应服务商的密钥',
              ),
            ),
            const SizedBox(height: 12),
            _DropdownField<String>(
              label: '常用模型',
              value: selectedModel,
              items: modelItems,
              onChanged: (value) {
                if (value == null || value.isEmpty) {
                  return;
                }
                setState(() {
                  _modelController.text = value;
                });
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelController,
              decoration: const InputDecoration(
                labelText: '模型 ID',
                hintText:
                    '例如 gemini-2.5-flash / mimo-v2.5 / openai/gpt-4.1-mini',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _promptController,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '自定义提示词',
                hintText: '例如优先按房间、箱号、物品类别输出结构化信息。',
              ),
            ),
            const SizedBox(height: 8),
            const _CaptureFlowNote(),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: controller.isBusy ? null : () => _save(context),
                    child: const Text('保存当前配置'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: controller.isBusy
                        ? null
                        : () async {
                            await _save(context, showFeedback: false);
                            if (!context.mounted) {
                              return;
                            }
                            await controller.testConnection();
                          },
                    child: const Text('测试连接'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _handleControllerChanged() {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _bindProfile(controller.activeProfile);
      }
    });
  }

  void _bindProfile(AppSettingsProfile profile) {
    if (_boundProfileId == profile.id) {
      return;
    }
    _boundProfileId = profile.id;
    _profileNameController.value = TextEditingValue(
      text: profile.name,
      selection: TextSelection.collapsed(offset: profile.name.length),
    );
    _baseUrlController.value = TextEditingValue(
      text: profile.settings.baseUrl,
      selection: TextSelection.collapsed(
        offset: profile.settings.baseUrl.length,
      ),
    );
    _apiKeyController.value = TextEditingValue(
      text: profile.settings.apiKey,
      selection: TextSelection.collapsed(
        offset: profile.settings.apiKey.length,
      ),
    );
    _modelController.value = TextEditingValue(
      text: profile.settings.model,
      selection: TextSelection.collapsed(offset: profile.settings.model.length),
    );
    _promptController.value = TextEditingValue(
      text: profile.settings.customPrompt,
      selection: TextSelection.collapsed(
        offset: profile.settings.customPrompt.length,
      ),
    );
  }

  Future<void> _applyProviderPreset(String providerId) async {
    final preset = AiProviderPreset.fromId(providerId);
    setState(() {
      _baseUrlController.text = preset.baseUrl;
      _modelController.text = preset.defaultModel;
    });

    final controller = AppScope.of(context);
    final profile = controller.activeProfile;
    await controller.saveProfile(
      profileId: profile.id,
      profileName: _profileNameController.text.trim().isEmpty
          ? profile.name
          : _profileNameController.text.trim(),
      settings: AppSettings(
        providerId: providerId,
        baseUrl: preset.baseUrl,
        apiKey: _apiKeyController.text.trim(),
        model: preset.defaultModel,
        customPrompt: _promptController.text.trim(),
      ),
    );
  }

  List<DropdownMenuItem<String>> _modelItems(String providerId) {
    final preset = AiProviderPreset.fromId(providerId);
    final models = [
      ...preset.recommendedModels,
      if (_modelController.text.trim().isNotEmpty &&
          !preset.recommendedModels.contains(_modelController.text.trim()))
        _modelController.text.trim(),
    ];

    if (models.isEmpty) {
      return const [DropdownMenuItem(value: '', child: Text('当前预设没有内置模型候选'))];
    }

    return models
        .map((model) => DropdownMenuItem(value: model, child: Text(model)))
        .toList();
  }

  String? _selectedModelValue({
    required List<DropdownMenuItem<String>> items,
    required String currentModel,
  }) {
    final trimmedModel = currentModel.trim();
    if (trimmedModel.isEmpty) {
      return items.any((item) => item.value == '') ? '' : null;
    }
    return items.any((item) => item.value == trimmedModel)
        ? trimmedModel
        : null;
  }

  Future<void> _createProfile() async {
    final controller = AppScope.of(context);
    final nameController = TextEditingController(
      text: '配置 ${controller.profiles.length + 1}',
    );
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建配置'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: '配置名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(nameController.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    nameController.dispose();

    if (!mounted || result == null || result.isEmpty) {
      return;
    }

    final current = controller.settings;
    await controller.saveProfile(
      profileName: result,
      settings: current.copyWith(apiKey: current.apiKey),
    );
  }

  Future<void> _save(BuildContext context, {bool showFeedback = true}) async {
    final controller = AppScope.of(context);
    final settings = AppSettings(
      providerId: controller.activeProfile.settings.providerId,
      baseUrl: _baseUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
      customPrompt: _promptController.text.trim(),
    );
    await controller.saveProfile(
      profileId: controller.activeProfile.id,
      profileName: _profileNameController.text.trim(),
      settings: settings,
    );
    if (showFeedback && context.mounted) {
      FocusScope.of(context).unfocus();
    }
  }
}

class _DropdownField<T> extends StatelessWidget {
  const _DropdownField({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isExpanded: true,
          value: value,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _UsageSection extends StatelessWidget {
  const _UsageSection({
    required this.activeStats,
    required this.overallStats,
    required this.activeProfileName,
  });

  final TokenUsageStats activeStats;
  final TokenUsageStats overallStats;
  final String activeProfileName;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final useVerticalLayout = constraints.maxWidth < 760;
        final cards = [
          _UsageCard(
            title: activeProfileName,
            subtitle: '当前配置累计',
            stats: activeStats,
          ),
          _UsageCard(title: '全部配置', subtitle: '总累计', stats: overallStats),
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Token 统计', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (useVerticalLayout) ...[
              cards[0],
              const SizedBox(height: 12),
              cards[1],
            ] else
              Row(
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 12),
                  Expanded(child: cards[1]),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _ProviderPresetCard extends StatelessWidget {
  const _ProviderPresetCard({required this.preset});

  final AiProviderPreset preset;

  @override
  Widget build(BuildContext context) {
    final models = preset.recommendedModels.isEmpty
        ? '可填写任意兼容模型'
        : preset.recommendedModels.join(' / ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preset.label, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              preset.description,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text('推荐模型：$models'),
            if (preset.note.trim().isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(preset.note, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _StorageSection extends StatelessWidget {
  const _StorageSection({
    required this.usage,
    required this.isBusy,
    required this.onOptimize,
  });

  final StorageUsageSummary usage;
  final bool isBusy;
  final Future<void> Function() onOptimize;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本地存储', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              '拍照后会压缩保存，导出文件只保留最近几份。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            _MetricRow(label: '图片数量', value: '${usage.imageCount}'),
            _MetricRow(label: '图片占用', value: _formatBytes(usage.imageBytes)),
            _MetricRow(label: '导出文件', value: '${usage.exportCount}'),
            _MetricRow(label: '导出占用', value: _formatBytes(usage.exportBytes)),
            _MetricRow(label: '合计', value: _formatBytes(usage.totalBytes)),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: isBusy ? null : onOptimize,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('立即优化存储'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    final kb = bytes / 1024;
    if (kb < 1024) {
      return '${kb.toStringAsFixed(1)} KB';
    }
    final mb = kb / 1024;
    if (mb < 1024) {
      return '${mb.toStringAsFixed(1)} MB';
    }
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
  }
}

class _CaptureFlowNote extends StatelessWidget {
  const _CaptureFlowNote();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.task_alt_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '拍摄后自动进入后台识别',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '单张和连续拍摄都会先加入待确认队列，识别完成后再统一确认入库。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({
    required this.title,
    required this.subtitle,
    required this.stats,
  });

  final String title;
  final String subtitle;
  final TokenUsageStats stats;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 14),
            _MetricRow(label: '请求数', value: '${stats.requestCount}'),
            _MetricRow(label: 'Prompt', value: '${stats.promptTokens}'),
            _MetricRow(label: 'Completion', value: '${stats.completionTokens}'),
            _MetricRow(label: 'Total', value: '${stats.totalTokens}'),
          ],
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
