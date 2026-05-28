import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../domain/entities/export_format.dart';
import '../../domain/entities/export_grouping.dart';
import '../../domain/entities/item_record.dart';
import '../../shared/widgets/local_image_frame.dart';
import '../items/item_detail_page.dart';
import '../shell/app_controller.dart';
import '../shell/app_scope.dart';

class ItemsPage extends StatefulWidget {
  const ItemsPage({super.key});

  @override
  State<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends State<ItemsPage> {
  String _query = '';
  String _selectedCategory = '全部';
  final Set<String> _selectedIds = {};

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final categories = <String>{
          '全部',
          ...controller.items.map((item) => item.category),
        };
        final filtered = controller.items.where((item) {
          final matchesCategory =
              _selectedCategory == '全部' || item.category == _selectedCategory;
          final query = _query.trim().toLowerCase();
          final matchesQuery =
              query.isEmpty ||
              item.name.toLowerCase().contains(query) ||
              item.category.toLowerCase().contains(query) ||
              item.room.toLowerCase().contains(query) ||
              item.box.toLowerCase().contains(query);
          return matchesCategory && matchesQuery;
        }).toList();
        _selectedIds.removeWhere(
          (id) => !controller.items.any((item) => item.id == id),
        );
        final isSelecting = _selectedIds.isNotEmpty;

        return CustomScrollView(
          key: const ValueKey('items-page'),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            isSelecting ? '已选择 ${_selectedIds.length} 件' : '视图',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                        if (isSelecting) ...[
                          IconButton(
                            onPressed: () => setState(_selectedIds.clear),
                            icon: const Icon(Icons.close),
                            tooltip: '取消选择',
                          ),
                          IconButton.filledTonal(
                            onPressed: controller.isBusy
                                ? null
                                : () => _deleteSelected(context),
                            icon: const Icon(Icons.delete_outline),
                            tooltip: '删除所选',
                          ),
                        ] else
                          FilledButton.icon(
                            onPressed: controller.isBusy
                                ? null
                                : () => _showExportSheet(context, filtered),
                            icon: const Icon(Icons.ios_share_outlined),
                            label: const Text('导出'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '按分类、名称、房间快速查看已经确认入库的物品，并导出当前结果。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 18),
                    TextField(
                      onChanged: (value) => setState(() => _query = value),
                      decoration: const InputDecoration(
                        hintText: '搜索名称、分类、房间或箱号',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 40,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: categories
                            .map(
                              (category) => Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: FilterChip(
                                  label: Text(category),
                                  selected: category == _selectedCategory,
                                  onSelected: (_) => setState(
                                    () => _selectedCategory = category,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              sliver: filtered.isEmpty
                  ? const SliverToBoxAdapter(child: _EmptyView())
                  : SliverList.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ItemCard(
                            item: item,
                            isSelected: _selectedIds.contains(item.id),
                            isSelecting: isSelecting,
                            onSelectionChanged: (selected) =>
                                _setSelected(item.id, selected),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showExportSheet(
    BuildContext context,
    List<ItemRecord> items,
  ) async {
    final controller = AppScope.of(context);
    final sharePositionOrigin = _sharePositionOrigin(context);
    final choice = await showModalBottomSheet<_ExportChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final bottomInset = MediaQuery.of(context).viewPadding.bottom;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset + 12),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '导出当前结果',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '先按格式查看，再选择按分类或按箱子导出，并决定是分享还是保存到本地。',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                for (final format in ExportFormat.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _ExportFormatSection(
                      format: format,
                      subtitle: _subtitleForFormat(format),
                      buildChoices: () sync* {
                        for (final grouping in ExportGrouping.values) {
                          for (final destination in ExportDestination.values) {
                            yield _ExportActionTile(
                              icon: destination == ExportDestination.share
                                  ? Icons.ios_share_outlined
                                  : Icons.save_alt_outlined,
                              title:
                                  '${grouping.label} · ${_labelForDestination(destination)}',
                              subtitle: _subtitleFor(grouping),
                              onTap: () => Navigator.of(context).pop(
                                _ExportChoice(
                                  format: format,
                                  grouping: grouping,
                                  destination: destination,
                                ),
                              ),
                            );
                          }
                        }
                      }(),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (choice == null || !context.mounted) {
      return;
    }
    await controller.exportItems(
      items: items,
      grouping: choice.grouping,
      format: choice.format,
      destination: choice.destination,
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  void _setSelected(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectedIds.add(id);
      } else {
        _selectedIds.remove(id);
      }
    });
  }

  Future<void> _deleteSelected(BuildContext context) async {
    final ids = {..._selectedIds};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除所选物品'),
        content: Text('确定删除 ${ids.length} 件物品吗？此操作不会保留在视图列表中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    await AppScope.of(context).deleteItemsById(ids);
    if (mounted) {
      setState(_selectedIds.clear);
    }
  }

  String _subtitleFor(ExportGrouping grouping) {
    return switch (grouping) {
      ExportGrouping.category => '适合按物品分类整理',
      ExportGrouping.box => '适合按搬家箱号整理',
    };
  }

  String _subtitleForFormat(ExportFormat format) {
    return switch (format) {
      ExportFormat.pdf => '适合打印、转发和直接查看版式',
      ExportFormat.excel => '适合继续整理、筛选和做盘点表',
      ExportFormat.markdown => '适合导入知识库或继续文本编辑',
    };
  }

  String _labelForDestination(ExportDestination destination) {
    return switch (destination) {
      ExportDestination.share => '分享',
      ExportDestination.save => '保存到本地',
    };
  }

  Rect? _sharePositionOrigin(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return null;
    }
    final origin = box.localToGlobal(Offset.zero);
    return origin & box.size;
  }
}

class _ExportChoice {
  const _ExportChoice({
    required this.format,
    required this.grouping,
    required this.destination,
  });

  final ExportFormat format;
  final ExportGrouping grouping;
  final ExportDestination destination;
}

class _ExportFormatSection extends StatelessWidget {
  const _ExportFormatSection({
    required this.format,
    required this.subtitle,
    required this.buildChoices,
  });

  final ExportFormat format;
  final String subtitle;
  final Iterable<_ExportActionTile> buildChoices;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_iconForFormat(format)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        format.label,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            for (final choice in buildChoices) choice,
          ],
        ),
      ),
    );
  }

  IconData _iconForFormat(ExportFormat format) {
    return switch (format) {
      ExportFormat.pdf => Icons.picture_as_pdf_outlined,
      ExportFormat.excel => Icons.table_chart_outlined,
      ExportFormat.markdown => Icons.notes_outlined,
    };
  }
}

class _ExportActionTile extends StatelessWidget {
  const _ExportActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({
    required this.item,
    required this.isSelected,
    required this.isSelecting,
    required this.onSelectionChanged,
  });

  final ItemRecord item;
  final bool isSelected;
  final bool isSelecting;
  final ValueChanged<bool> onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: () {
          if (isSelecting) {
            onSelectionChanged(!isSelected);
            return;
          }
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => ItemDetailPage(item: item)));
        },
        onLongPress: () => onSelectionChanged(true),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ItemThumbnail(item: item),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        PopupMenuButton<ItemStatus>(
                          tooltip: '快速编辑状态',
                          onSelected: (status) => controller.updateItem(
                            item.copyWith(
                              status: status,
                              updatedAt: DateTime.now(),
                            ),
                          ),
                          itemBuilder: (context) => [
                            for (final status in ItemStatus.values)
                              PopupMenuItem<ItemStatus>(
                                value: status,
                                child: Text(status.label),
                              ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(99),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.bolt_outlined, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  item.status.label,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(width: 2),
                                const Icon(Icons.expand_more, size: 16),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Chip(label: Text(item.category)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _DataPill(
                          icon: Icons.home_work_outlined,
                          label: item.room.ifEmpty('未分配房间'),
                        ),
                        _DataPill(
                          icon: Icons.inventory_outlined,
                          label: item.box.ifEmpty('未分配箱号'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      item.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              if (isSelecting) ...[
                const SizedBox(width: 8),
                Checkbox(
                  value: isSelected,
                  onChanged: (value) => onSelectionChanged(value ?? false),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemThumbnail extends StatelessWidget {
  const _ItemThumbnail({required this.item});

  final ItemRecord item;

  @override
  Widget build(BuildContext context) {
    final imageExists =
        item.imagePath.trim().isNotEmpty && File(item.imagePath).existsSync();

    if (!imageExists) {
      return Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          color: AppTheme.mint,
          borderRadius: BorderRadius.circular(20),
        ),
        alignment: Alignment.center,
        child: Text(
          item.name.isEmpty ? '?' : item.name.substring(0, 1),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      );
    }

    return LocalImageFrame(
      path: item.imagePath,
      width: 78,
      height: 78,
      borderRadius: BorderRadius.circular(20),
    );
  }
}

class _DataPill extends StatelessWidget {
  const _DataPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 16), const SizedBox(width: 6), Text(label)],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('没有匹配结果', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              '先去主页拍照并确认入库，或者调整筛选条件。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}
