import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../domain/entities/export_grouping.dart';
import '../../domain/entities/item_record.dart';
import '../items/item_detail_page.dart';
import '../shell/app_scope.dart';

class ItemsPage extends StatefulWidget {
  const ItemsPage({super.key});

  @override
  State<ItemsPage> createState() => _ItemsPageState();
}

class _ItemsPageState extends State<ItemsPage> {
  String _query = '';
  String _selectedCategory = '全部';

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
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
                        '视图',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: controller.isBusy
                          ? null
                          : () => _showExportSheet(context, filtered),
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('导出 PDF'),
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
                              onSelected: (_) =>
                                  setState(() => _selectedCategory = category),
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
                      child: _ItemCard(item: item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _showExportSheet(
    BuildContext context,
    List<ItemRecord> items,
  ) async {
    final controller = AppScope.of(context);
    final grouping = await showModalBottomSheet<ExportGrouping>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('按分类导出'),
              subtitle: const Text('适合按厨房、数码、家具等类别整理'),
              leading: const Icon(Icons.category_outlined),
              onTap: () => Navigator.of(context).pop(ExportGrouping.category),
            ),
            ListTile(
              title: const Text('按箱子导出'),
              subtitle: const Text('适合搬家时按箱号做装箱清单'),
              leading: const Icon(Icons.inventory_2_outlined),
              onTap: () => Navigator.of(context).pop(ExportGrouping.box),
            ),
          ],
        ),
      ),
    );

    if (grouping == null || !context.mounted) {
      return;
    }
    await controller.exportItemsReport(items: items, grouping: grouping);
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item});

  final ItemRecord item;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => ItemDetailPage(item: item)));
        },
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
                        _DataPill(
                          icon: Icons.tag_outlined,
                          label: item.status.label,
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
    if (item.imagePath.isEmpty) {
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

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Image.file(
        File(item.imagePath),
        width: 78,
        height: 78,
        fit: BoxFit.cover,
      ),
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
