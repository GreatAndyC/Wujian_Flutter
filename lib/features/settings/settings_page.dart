import 'package:flutter/material.dart';

import '../../domain/entities/app_settings.dart';
import '../../domain/entities/app_settings_profile.dart';
import '../shell/app_scope.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  TextEditingController? _profileNameController;
  TextEditingController? _baseUrlController;
  TextEditingController? _apiKeyController;
  TextEditingController? _modelController;
  TextEditingController? _promptController;
  String? _boundProfileId;
  bool _autoSave = true;

  @override
  void dispose() {
    _profileNameController?.dispose();
    _baseUrlController?.dispose();
    _apiKeyController?.dispose();
    _modelController?.dispose();
    _promptController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    _bindProfile(controller.activeProfile);

    return ListView(
      key: const ValueKey('settings-page'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      children: [
        Text('设置', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '可以保存多套火山方舟配置，并在拍照前快速切换当前使用的模型。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(
          key: ValueKey(controller.activeProfile.id),
          initialValue: controller.activeProfile.id,
          decoration: const InputDecoration(labelText: '当前配置'),
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
            setState(() {
              _boundProfileId = null;
            });
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
                    : () =>
                          controller.deleteProfile(controller.activeProfile.id),
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
        TextField(
          controller: _baseUrlController,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://ark.cn-beijing.volces.com/api/v3',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _apiKeyController,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'API Key',
            hintText: 'ARK_API_KEY',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _modelController,
          decoration: const InputDecoration(
            labelText: '模型 ID',
            hintText: 'doubao-seed-2-0-mini-260428',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _promptController,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: '自定义提示词',
            hintText: '例如优先按房间、箱号、物品品类输出结构化信息。',
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _autoSave,
          onChanged: (value) => setState(() => _autoSave = value),
          title: const Text('单张拍摄后立即进入确认'),
          subtitle: const Text('关闭后，单张拍摄结果也会先进入待确认队列。'),
        ),
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
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前默认值', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(
                  '默认模型已经切到 doubao-seed-2-0-mini-260428。\n连续拍照始终进入待确认队列，适合先批量采集、后统一校对。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _bindProfile(AppSettingsProfile profile) {
    if (_boundProfileId == profile.id) {
      return;
    }
    _boundProfileId = profile.id;
    _profileNameController?.dispose();
    _baseUrlController?.dispose();
    _apiKeyController?.dispose();
    _modelController?.dispose();
    _promptController?.dispose();
    _profileNameController = TextEditingController(text: profile.name);
    _baseUrlController = TextEditingController(text: profile.settings.baseUrl);
    _apiKeyController = TextEditingController(text: profile.settings.apiKey);
    _modelController = TextEditingController(text: profile.settings.model);
    _promptController = TextEditingController(
      text: profile.settings.customPrompt,
    );
    _autoSave = profile.settings.autoSave;
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
    setState(() {
      _boundProfileId = null;
    });
  }

  Future<void> _save(BuildContext context, {bool showFeedback = true}) async {
    final controller = AppScope.of(context);
    final settings = AppSettings(
      baseUrl: _baseUrlController!.text.trim(),
      apiKey: _apiKeyController!.text.trim(),
      model: _modelController!.text.trim(),
      customPrompt: _promptController!.text.trim(),
      autoSave: _autoSave,
    );
    await controller.saveProfile(
      profileId: controller.activeProfile.id,
      profileName: _profileNameController!.text.trim(),
      settings: settings,
    );
    if (showFeedback && context.mounted) {
      FocusScope.of(context).unfocus();
    }
  }
}
