import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/entities/item_record.dart';
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
      ..._item.parameters,
    }..removeWhere((key, value) => value.trim().isEmpty);

    return Scaffold(
      appBar: AppBar(
        title: Text(_item.name),
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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          children: [
            if (imageExists)
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image.file(
                  File(_item.imagePath),
                  height: 240,
                  fit: BoxFit.cover,
                ),
              ),
            const SizedBox(height: 20),
            Text(_item.name, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              _item.description,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: parameters.entries
                      .map(
                        (entry) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 72,
                                child: Text(
                                  entry.key,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
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
                      )
                      .toList(),
                ),
              ),
            ),
            if (_item.notes.trim().isNotEmpty) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    _item.notes,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ),
            ],
          ],
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
