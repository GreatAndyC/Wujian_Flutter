import 'dart:io';

import 'package:flutter/material.dart';

import '../../domain/entities/item_record.dart';

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
      decoration: const BoxDecoration(
        color: Color(0xFFF5F1E8),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, bottomInset + 20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 48,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '保存前可以修正分类、房间、箱号和参数。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 18),
                _PreviewImage(path: widget.initialItem.imagePath),
                const SizedBox(height: 18),
                _Field(label: '名称', controller: _nameController),
                _Field(label: '分类', controller: _categoryController),
                Row(
                  children: [
                    Expanded(
                      child: _Field(label: '房间', controller: _roomController),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Field(label: '箱号', controller: _boxController),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _Field(
                        label: '数量',
                        controller: _quantityController,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<ItemStatus>(
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
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _Field(label: '品牌', controller: _brandController),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Field(label: '型号', controller: _modelController),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: _Field(label: '颜色', controller: _colorController),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _Field(
                        label: '材质',
                        controller: _materialController,
                      ),
                    ),
                  ],
                ),
                _Field(
                  label: '详情',
                  controller: _descriptionController,
                  maxLines: 3,
                ),
                _Field(label: '备注', controller: _notesController, maxLines: 3),
                const SizedBox(height: 16),
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
      child: Image.file(
        File(path),
        height: 150,
        width: double.infinity,
        fit: BoxFit.cover,
      ),
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
