import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../domain/entities/item_record.dart';
import '../camera/camera_capture_page.dart';
import '../items/item_detail_page.dart';
import '../items/item_editor_sheet.dart';
import '../shell/app_scope.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final stats = _HomeStats.fromItems(
      controller.items,
      controller.pendingQueue,
    );

    return CustomScrollView(
      key: const ValueKey('home-page'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(32),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF14342D), Color(0xFF255748)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Text(
                          '物见 · ${controller.activeProfile.name}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        '先拍下来，\n后台自动识别。',
                        style: Theme.of(
                          context,
                        ).textTheme.displaySmall?.copyWith(color: Colors.white),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        controller.settings.isConfigured
                            ? '连续拍照时，照片会立即进入队列，后台继续识别，不阻塞下一张。'
                            : '还没配置 API。你仍然可以拍照，结果会先进队列，之后手动补充。',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.white.withValues(alpha: 0.86),
                        ),
                      ),
                      const SizedBox(height: 26),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: controller.isBusy
                                  ? null
                                  : () => _openCamera(context),
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: AppTheme.ink,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                              ),
                              icon: const Icon(Icons.camera_alt),
                              label: const Text('拍一张'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: controller.isBusy
                                  ? null
                                  : () => _openCamera(context),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.36),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                              ),
                              icon: const Icon(Icons.photo_camera_back),
                              label: const Text('连续拍照'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (context, constraints) {
                    const spacing = 12.0;
                    final width = constraints.maxWidth;
                    final columns = width >= 720
                        ? 3
                        : width >= 460
                        ? 2
                        : 1;
                    final itemWidth =
                        (width - spacing * (columns - 1)) / columns;

                    final cards = [
                      _MetricCard(
                        label: '物品总数',
                        value: '${controller.items.length}',
                      ),
                      _MetricCard(
                        label: '待确认队列',
                        value: '${controller.pendingQueue.length}',
                      ),
                      _MetricCard(label: '分类数量', value: '${stats.categories}'),
                    ];

                    return Wrap(
                      spacing: spacing,
                      runSpacing: spacing,
                      children: cards
                          .map(
                            (card) => SizedBox(width: itemWidth, child: card),
                          )
                          .toList(),
                    );
                  },
                ),
                const SizedBox(height: 18),
                if (controller.latestImage != null)
                  _LatestImageCard(image: controller.latestImage!),
                const SizedBox(height: 18),
                Text('待确认队列', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  controller.isProcessingQueue
                      ? '后台正在识别队列中的照片，你可以继续拍。'
                      : '点开可确认的条目后再入库。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          sliver: controller.pendingQueue.isEmpty
              ? const SliverToBoxAdapter(child: _EmptyPendingState())
              : SliverList.builder(
                  itemCount: controller.pendingQueue.length,
                  itemBuilder: (context, index) {
                    final item = controller.pendingQueue[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _PendingItemCard(item: item),
                    );
                  },
                ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text('最近入库', style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          sliver: controller.items.isEmpty
              ? const SliverToBoxAdapter(child: _EmptyState())
              : SliverList.builder(
                  itemCount: controller.items.take(4).length,
                  itemBuilder: (context, index) {
                    final item = controller.items[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _RecentItemCard(item: item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _openCamera(BuildContext context) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const CameraCapturePage()));
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        child: SizedBox(
          height: 86,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      value,
                      style: Theme.of(context).textTheme.headlineSmall,
                      maxLines: 1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LatestImageCard extends StatelessWidget {
  const _LatestImageCard({required this.image});

  final File image;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 180,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(image, fit: BoxFit.cover),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.black.withValues(alpha: 0.04),
                    Colors.black.withValues(alpha: 0.55),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            const Positioned(
              left: 18,
              bottom: 18,
              child: Text(
                '最近一次拍摄',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingItemCard extends StatelessWidget {
  const _PendingItemCard({required this.item});

  final ItemRecord item;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final canConfirm =
        item.queueState == QueueRecognitionState.ready ||
        item.queueState == QueueRecognitionState.failed;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PendingThumbnail(item: item),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.recognitionError.trim().isNotEmpty
                            ? item.recognitionError
                            : item.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Chip(label: Text(item.queueState.label)),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: !canConfirm
                        ? null
                        : () async {
                            final saved =
                                await showModalBottomSheet<ItemRecord>(
                                  context: context,
                                  isScrollControlled: true,
                                  backgroundColor: Colors.transparent,
                                  builder: (_) => ItemEditorSheet(
                                    initialItem: item,
                                    title: '确认队列项目',
                                    submitLabel: '确认入库',
                                  ),
                                );
                            if (saved != null) {
                              await controller.confirmPendingItem(
                                saved.copyWith(
                                  queueState: QueueRecognitionState.ready,
                                  recognitionError: '',
                                ),
                              );
                            }
                          },
                    child: Text(canConfirm ? '确认' : '识别中'),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () => controller.removePendingItem(item.id),
                  child: const Text('移除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingThumbnail extends StatelessWidget {
  const _PendingThumbnail({required this.item});

  final ItemRecord item;

  @override
  Widget build(BuildContext context) {
    if (item.imagePath.trim().isEmpty || !File(item.imagePath).existsSync()) {
      return Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: AppTheme.mint,
          borderRadius: BorderRadius.circular(18),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.image_outlined),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Image.file(
        File(item.imagePath),
        width: 64,
        height: 64,
        fit: BoxFit.cover,
      ),
    );
  }
}

class _RecentItemCard extends StatelessWidget {
  const _RecentItemCard({required this.item});

  final ItemRecord item;

  @override
  Widget build(BuildContext context) {
    final imageExists =
        item.imagePath.trim().isNotEmpty && File(item.imagePath).existsSync();

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: () {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => ItemDetailPage(item: item)));
        },
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 8,
          ),
          leading: imageExists
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.file(
                    File(item.imagePath),
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                  ),
                )
              : CircleAvatar(
                  backgroundColor: AppTheme.mint,
                  child: Text(
                    item.name.isEmpty ? '?' : item.name.substring(0, 1),
                  ),
                ),
          title: Text(item.name),
          subtitle: Text('${item.category} · ${item.status.label}'),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}

class _EmptyPendingState extends StatelessWidget {
  const _EmptyPendingState();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('队列是空的', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Text(
              '可以先拍一张，或者用连续拍照一次采集一批物品。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('还没有正式入库的物品', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Text(
              '待确认完成后，物品会出现在这里。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeStats {
  const _HomeStats({required this.categories});

  final int categories;

  factory _HomeStats.fromItems(
    List<ItemRecord> items,
    List<ItemRecord> pendingQueue,
  ) {
    return _HomeStats(
      categories: {
        ...items.map((item) => item.category),
        ...pendingQueue.map((item) => item.category),
      }.length,
    );
  }
}
