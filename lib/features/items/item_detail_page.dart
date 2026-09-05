import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../domain/entities/item_record.dart';
import '../../shared/widgets/app_ui.dart';
import '../../shared/widgets/local_image_frame.dart';
import '../shell/app_scope.dart';
import 'item_editor_sheet.dart';

class ItemDetailPage extends StatefulWidget {
  const ItemDetailPage({super.key, required this.item});

  final ItemRecord item;

  @override
  State<ItemDetailPage> createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  late ItemRecord _item;

  @override
  void initState() {
    super.initState();
    _item = widget.item;
  }

  @override
  Widget build(BuildContext context) {
    final imageExists =
        _item.imagePath.trim().isNotEmpty && File(_item.imagePath).existsSync();
    final parameters = {
      '分类': _item.category,
      '房间': _item.room,
      '箱号': _item.box,
      '数量': _item.quantity.toString(),
      '品牌': _item.brand,
      '型号': _item.model,
      '颜色': _item.color,
      '材质': _item.material,
      '状态': _item.status.label,
      ..._item.visibleParameters,
    }..removeWhere((key, value) => value.trim().isEmpty);

    return Scaffold(
      appBar: AppBar(
        title: const Text('物品详情'),
        actions: [
          IconButton(
            onPressed: _editItem,
            icon: const Icon(Icons.edit_outlined),
            tooltip: '编辑',
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: AppContent(
          maxWidth: 760,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.xl,
            ),
            children: [
              AppPageHeader(
                eyebrow: _item.category.trim().isEmpty ? '物品' : _item.category,
                title: _item.name,
                subtitle: _item.description.trim().isEmpty
                    ? '已保存的物品记录'
                    : _item.description,
                trailing: AppStatusPill(
                  label: _item.status.label,
                  icon: Icons.bolt_outlined,
                  tone: _item.status == ItemStatus.cataloged
                      ? AppStatusTone.success
                      : AppStatusTone.neutral,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (imageExists)
                LocalImageFrame(
                  path: _item.imagePath,
                  height: 260,
                  width: double.infinity,
                  borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                  semanticLabel: '${_item.name}照片',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LocalImageViewerPage(
                        path: _item.imagePath,
                        title: _item.name,
                      ),
                    ),
                  ),
                ),
              if (imageExists) const SizedBox(height: AppSpacing.lg),
              AppSurface(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('信息', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: AppSpacing.sm),
                    for (final entry in parameters.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 72,
                              child: Text(
                                entry.key,
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                entry.value,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (_item.notes.trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                AppSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '备注',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        _item.notes,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editItem() async {
    final controller = AppScope.of(context);
    final saved = await showModalBottomSheet<ItemRecord>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ItemEditorSheet(
        initialItem: _item,
        title: '编辑物品',
        submitLabel: '保存修改',
      ),
    );

    if (saved == null) {
      return;
    }

    await controller.updateItem(saved);
    if (!mounted) {
      return;
    }
    setState(() {
      _item = saved;
    });
  }
}
