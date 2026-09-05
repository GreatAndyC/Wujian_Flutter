import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../domain/entities/item_record.dart';
import '../../shared/widgets/app_ui.dart';
import '../../shared/widgets/local_image_frame.dart';

class ItemEditorSheet extends StatefulWidget {
  const ItemEditorSheet({
    super.key,
    required this.initialItem,
    this.title = '确认识别结果',
    this.submitLabel = '保存物品',
  });

  final ItemRecord initialItem;
  final String title;
  final String submitLabel;

  @override
  State<ItemEditorSheet> createState() => _ItemEditorSheetState();
}

class _ItemEditorSheetState extends State<ItemEditorSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _categoryController;
  late final TextEditingController _roomController;
  late final TextEditingController _boxController;
  late final TextEditingController _brandController;
  late final TextEditingController _modelController;
  late final TextEditingController _colorController;
  late final TextEditingController _materialController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _notesController;
  late final TextEditingController _quantityController;
  late ItemStatus _status;

  @override
  void initState() {
    super.initState();
    final item = widget.initialItem;
    _nameController = TextEditingController(text: item.name);
    _categoryController = TextEditingController(text: item.category);
    _roomController = TextEditingController(text: item.room);
    _boxController = TextEditingController(text: item.box);
    _brandController = TextEditingController(text: item.brand);
    _modelController = TextEditingController(text: item.model);
    _colorController = TextEditingController(text: item.color);
    _materialController = TextEditingController(text: item.material);
    _descriptionController = TextEditingController(text: item.description);
    _notesController = TextEditingController(text: item.notes);
    _quantityController = TextEditingController(text: item.quantity.toString());
    _status = item.status;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    _roomController.dispose();
    _boxController.dispose();
    _brandController.dispose();
    _modelController.dispose();
    _colorController.dispose();
    _materialController.dispose();
    _descriptionController.dispose();
    _notesController.dispose();
    _quantityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusXl),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            bottomInset + AppSpacing.lg,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 48,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '保存前可以修正分类、房间、箱号和参数。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.lg),
                _PreviewImage(path: widget.initialItem.imagePath),
                const SizedBox(height: 18),
                _Field(label: '名称', controller: _nameController),
                _Field(label: '分类', controller: _categoryController),
                _FieldPair(
                  first: _Field(label: '房间', controller: _roomController),
                  second: _Field(label: '箱号', controller: _boxController),
                ),
                _FieldPair(
                  first: _Field(
                    label: '数量',
                    controller: _quantityController,
                    keyboardType: TextInputType.number,
                  ),
                  second: DropdownButtonFormField<ItemStatus>(
                    initialValue: _status,
                    decoration: const InputDecoration(labelText: '状态'),
                    items: ItemStatus.values
                        .map(
                          (status) => DropdownMenuItem(
                            value: status,
                            child: Text(status.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _status = value);
                      }
                    },
                  ),
                ),
                _FieldPair(
                  first: _Field(label: '品牌', controller: _brandController),
                  second: _Field(label: '型号', controller: _modelController),
                ),
                _FieldPair(
                  first: _Field(label: '颜色', controller: _colorController),
                  second: _Field(label: '材质', controller: _materialController),
                ),
                _Field(
                  label: '详情',
                  controller: _descriptionController,
                  maxLines: 3,
                ),
                _Field(label: '备注', controller: _notesController, maxLines: 3),
                const SizedBox(height: AppSpacing.md),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _submit,
                    child: Text(widget.submitLabel),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _submit() {
    final quantity = int.tryParse(_quantityController.text.trim()) ?? 1;
    final item = widget.initialItem.copyWith(
      name: _nameController.text.trim().isEmpty
          ? '待确认物品'
          : _nameController.text.trim(),
      category: _categoryController.text.trim().isEmpty
          ? '待分类'
          : _categoryController.text.trim(),
      room: _roomController.text.trim(),
      box: _boxController.text.trim(),
      quantity: quantity,
      status: _status,
      brand: _brandController.text.trim(),
      model: _modelController.text.trim(),
      color: _colorController.text.trim(),
      material: _materialController.text.trim(),
      description: _descriptionController.text.trim(),
      notes: _notesController.text.trim(),
      updatedAt: DateTime.now(),
    );
    Navigator.of(context).pop(item);
  }
}

class _PreviewImage extends StatelessWidget {
  const _PreviewImage({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    if (path.trim().isEmpty || !File(path).existsSync()) {
      return const SizedBox.shrink();
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: LocalImageFrame(
        path: path,
        height: 150,
        width: double.infinity,
        borderRadius: BorderRadius.circular(20),
        semanticLabel: '待编辑物品照片',
      ),
    );
  }
}

class _FieldPair extends StatelessWidget {
  const _FieldPair({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 480) {
          return Column(children: [first, second]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: first),
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    this.keyboardType,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}
