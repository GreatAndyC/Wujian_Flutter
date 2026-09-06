import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme/app_theme.dart';
import '../../domain/entities/item_record.dart';
import '../../shared/widgets/app_ui.dart';
import '../../shared/widgets/local_image_frame.dart';
import '../camera/camera_capture_page.dart';
import '../items/item_detail_page.dart';
import '../items/item_editor_sheet.dart';
import '../shell/app_scope.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const MethodChannel _nativeCameraChannel = MethodChannel(
    'com.wujian.app.icheck/file_saver',
  );
  static const EventChannel _nativeCameraEvents = EventChannel(
    'com.wujian.app.icheck/native_camera_events',
  );

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final stats = _HomeStats.fromItems(
          controller.items,
          controller.pendingQueue,
        );
        final readyPendingCount = controller.pendingQueue
            .where((item) => item.queueState == QueueRecognitionState.ready)
            .length;
        final failedPendingCount = controller.pendingQueue
            .where((item) => item.queueState == QueueRecognitionState.failed)
            .length;

        final isConfigured = controller.settings.isConfigured;
        return CustomScrollView(
          key: const ValueKey('home-page'),
          slivers: [
            SliverToBoxAdapter(
              child: AppContent(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppPageHeader(
                        eyebrow: '物见工作区',
                        title: '把家里的东西，变得好找。',
                        subtitle:
                            '${controller.activeProfile.name} · ${controller.items.length} 件已入库',
                        trailing: AppStatusPill(
                          label: isConfigured ? '识别已连接' : '待配置 API',
                          icon: isConfigured
                              ? Icons.cloud_done_outlined
                              : Icons.cloud_off_outlined,
                          tone: isConfigured
                              ? AppStatusTone.success
                              : AppStatusTone.warning,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      AppSurface(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        color: Theme.of(context).colorScheme.primary,
                        borderColor: Colors.transparent,
                        radius: AppTheme.radiusXl,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '拍下来，剩下的交给队列。',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onPrimary,
                                        ),
                                  ),
                                ),
                                Icon(
                                  Icons.auto_awesome,
                                  color: Theme.of(context).colorScheme.onPrimary
                                      .withValues(alpha: 0.8),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Text(
                              isConfigured
                                  ? '照片会先保存到本地，再异步识别；你可以继续拍，不会被网络卡住。'
                                  : '还没配置 API 也没关系，照片会安全留在待确认队列里。',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimary
                                        .withValues(alpha: 0.82),
                                  ),
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            LayoutBuilder(
                              builder: (context, constraints) {
                                final actions = [
                                  Expanded(
                                    child: FilledButton.icon(
                                      key: const ValueKey(
                                        'home-capture-button',
                                      ),
                                      onPressed: controller.isBusy
                                          ? null
                                          : () => _openCamera(context),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Theme.of(
                                          context,
                                        ).colorScheme.onPrimary,
                                        foregroundColor: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                      ),
                                      icon: const Icon(
                                        Icons.camera_alt_outlined,
                                      ),
                                      label: const Text('拍一张'),
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      key: const ValueKey('home-batch-button'),
                                      onPressed: controller.isBusy
                                          ? null
                                          : () => _startContinuousCapture(
                                              context,
                                            ),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Theme.of(
                                          context,
                                        ).colorScheme.onPrimary,
                                        side: BorderSide(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onPrimary
                                              .withValues(alpha: 0.42),
                                        ),
                                      ),
                                      icon: const Icon(
                                        Icons.collections_outlined,
                                      ),
                                      label: const Text('按箱连拍'),
                                    ),
                                  ),
                                ];
                                if (constraints.maxWidth < 440) {
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      actions[0],
                                      const SizedBox(height: AppSpacing.sm),
                                      actions[2],
                                    ],
                                  );
                                }
                                return Row(children: actions);
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final metrics = [
                            AppMetricCard(
                              label: '物品总数',
                              value: '${controller.items.length}',
                              icon: Icons.inventory_2_outlined,
                            ),
                            AppMetricCard(
                              label: '待确认',
                              value: '${controller.pendingQueue.length}',
                              icon: Icons.pending_actions_outlined,
                              tint: Theme.of(
                                context,
                              ).colorScheme.tertiaryContainer,
                            ),
                            AppMetricCard(
                              label: '分类数量',
                              value: '${stats.categories}',
                              icon: Icons.category_outlined,
                              tint: Theme.of(
                                context,
                              ).colorScheme.secondaryContainer,
                            ),
                          ];
                          return Row(
                            // This row lives inside a sliver, whose vertical
                            // constraints are unbounded. Stretching children
                            // here asks them to fill an infinite height and
                            // makes the release build render the page blank.
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (
                                var index = 0;
                                index < metrics.length;
                                index++
                              ) ...[
                                Expanded(child: metrics[index]),
                                if (index != metrics.length - 1)
                                  const SizedBox(width: AppSpacing.sm),
                              ],
                            ],
                          );
                        },
                      ),
                      if (controller.latestImage != null) ...[
                        const SizedBox(height: AppSpacing.md),
                        _LatestImageCard(image: controller.latestImage!),
                      ],
                      const SizedBox(height: AppSpacing.xl),
                      AppSectionHeader(
                        title: '待确认队列',
                        subtitle: controller.isProcessingQueue
                            ? '后台正在识别，你可以继续拍。'
                            : '确认后才会写入物品清单。',
                        action: Wrap(
                          spacing: AppSpacing.xs,
                          children: [
                            if (failedPendingCount > 0)
                              IconButton.outlined(
                                key: const ValueKey('home-retry-button'),
                                onPressed: controller.isBusy
                                    ? null
                                    : controller.retryAllFailedPendingItems,
                                tooltip: '重新识别失败项',
                                icon: const Icon(Icons.refresh),
                              ),
                            FilledButton.tonalIcon(
                              key: const ValueKey('home-confirm-all-button'),
                              onPressed:
                                  controller.isBusy || readyPendingCount == 0
                                  ? null
                                  : controller.confirmAllReadyPendingItems,
                              icon: const Icon(Icons.playlist_add_check),
                              label: Text('添加 $readyPendingCount 项'),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.xs,
                        runSpacing: AppSpacing.xs,
                        children: [
                          AppStatusPill(
                            label: '共 ${controller.pendingQueue.length} 项',
                            icon: Icons.layers_outlined,
                          ),
                          AppStatusPill(
                            label: '可添加 $readyPendingCount 项',
                            icon: Icons.check_circle_outline,
                            tone: AppStatusTone.success,
                          ),
                          if (failedPendingCount > 0)
                            AppStatusPill(
                              label: '失败 $failedPendingCount 项',
                              icon: Icons.error_outline,
                              tone: AppStatusTone.danger,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              sliver: controller.pendingQueue.isEmpty
                  ? const SliverToBoxAdapter(child: _EmptyPendingState())
                  : SliverList.builder(
                      itemCount: controller.pendingQueue.length,
                      itemBuilder: (context, index) {
                        final item = controller.pendingQueue[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: _PendingItemCard(item: item),
                        );
                      },
                    ),
            ),
            SliverToBoxAdapter(
              child: AppContent(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.sm,
                  ),
                  child: const AppSectionHeader(title: '最近入库'),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                0,
                AppSpacing.md,
                AppSpacing.xl,
              ),
              sliver: controller.items.isEmpty
                  ? const SliverToBoxAdapter(child: _EmptyState())
                  : SliverList.builder(
                      itemCount: controller.items.take(4).length,
                      itemBuilder: (context, index) {
                        final item = controller.items[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: _RecentItemCard(item: item),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openCamera(
    BuildContext context, {
    String? captureBox,
    bool singleCapture = true,
  }) async {
    final controller = AppScope.of(context);
    if (Platform.isAndroid) {
      final completedPaths = <String>{};
      final inFlightPaths = <String, Future<bool>>{};

      Future<bool> ingestPath(String path) {
        final normalized = path.trim();
        if (normalized.isEmpty || completedPaths.contains(normalized)) {
          return Future.value(true);
        }
        final existing = inFlightPaths[normalized];
        if (existing != null) {
          return existing;
        }
        late final Future<bool> operation;
        operation = controller
            .queueCapturedFile(File(normalized), box: captureBox)
            .then((succeeded) {
              if (succeeded) {
                completedPaths.add(normalized);
              }
              return succeeded;
            })
            .whenComplete(() {
              if (identical(inFlightPaths[normalized], operation)) {
                inFlightPaths.remove(normalized);
              }
            });
        inFlightPaths[normalized] = operation;
        return operation;
      }

      final subscription = _nativeCameraEvents.receiveBroadcastStream().listen((
        event,
      ) {
        final path = event?.toString() ?? '';
        if (path.trim().isEmpty) {
          return;
        }
        unawaited(ingestPath(path));
      });
      try {
        final rawPaths =
            await _nativeCameraChannel.invokeMethod<List<dynamic>>(
              'openNativeCamera',
              {'captureBox': captureBox, 'singleCapture': singleCapture},
            ) ??
            const [];
        for (final rawPath in rawPaths) {
          final path = rawPath?.toString() ?? '';
          if (path.trim().isEmpty) {
            continue;
          }
          final succeeded = await ingestPath(path);
          if (!succeeded) {
            await ingestPath(path);
          }
        }
      } finally {
        await subscription.cancel();
        if (inFlightPaths.isNotEmpty) {
          await Future.wait(inFlightPaths.values);
        }
      }
      return;
    }

    controller.setActiveCaptureBox(captureBox);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CameraCapturePage(captureBox: captureBox),
      ),
    );
    controller.setActiveCaptureBox(null);
  }

  Future<void> _startContinuousCapture(BuildContext context) async {
    final controller = AppScope.of(context);
    final existingBoxes = {
      ...controller.items.map((item) => item.box.trim()),
      ...controller.pendingQueue.map((item) => item.box.trim()),
    }.where((box) => box.isNotEmpty).toList()..sort();
    final captureBox = await showDialog<String>(
      context: context,
      builder: (_) => _CreateCaptureBoxDialog(existingBoxes: existingBoxes),
    );
    if (!context.mounted || captureBox == null) {
      return;
    }
    await _openCamera(context, captureBox: captureBox, singleCapture: false);
  }
}

class _CreateCaptureBoxDialog extends StatefulWidget {
  const _CreateCaptureBoxDialog({required this.existingBoxes});

  final List<String> existingBoxes;

  @override
  State<_CreateCaptureBoxDialog> createState() =>
      _CreateCaptureBoxDialogState();
}

class _CreateCaptureBoxDialogState extends State<_CreateCaptureBoxDialog> {
  late final TextEditingController _controller;
  String? _selectedExistingBox;
  bool _useExistingBox = false;

  @override
  void initState() {
    super.initState();
    _useExistingBox = widget.existingBoxes.isNotEmpty;
    _selectedExistingBox = widget.existingBoxes.isEmpty
        ? null
        : widget.existingBoxes.first;
    _controller = TextEditingController(
      text:
          '箱-${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().day.toString().padLeft(2, '0')}-${DateTime.now().hour.toString().padLeft(2, '0')}${DateTime.now().minute.toString().padLeft(2, '0')}',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('连续拍照箱子'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('开始连续拍照前，可以新建一个箱子，或直接加入现有箱子。'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: const Text('新建箱子'),
                selected: !_useExistingBox,
                onSelected: (_) => setState(() => _useExistingBox = false),
              ),
              ChoiceChip(
                label: const Text('加入现有箱子'),
                selected: _useExistingBox,
                onSelected: widget.existingBoxes.isEmpty
                    ? null
                    : (_) => setState(() => _useExistingBox = true),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_useExistingBox && widget.existingBoxes.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: _selectedExistingBox,
              decoration: const InputDecoration(
                labelText: '现有箱子',
                hintText: '选择一个已存在的箱子',
              ),
              items: widget.existingBoxes
                  .map(
                    (box) => DropdownMenuItem(
                      value: box,
                      child: Text(
                        box,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _selectedExistingBox = value),
            )
          else
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '箱号 / 包裹名',
                hintText: '例如：客厅-纸箱-01',
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
          if (widget.existingBoxes.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '当前还没有可加入的现有箱子。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('开始拍照')),
      ],
    );
  }

  void _submit() {
    final value = _useExistingBox
        ? (_selectedExistingBox ?? '').trim()
        : _controller.text.trim();
    if (value.isEmpty) {
      return;
    }
    Navigator.of(context).pop(value);
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
        height: 220,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LocalImageFrame(
              path: image.path,
              height: 220,
              borderRadius: BorderRadius.circular(0),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      LocalImageViewerPage(path: image.path, title: '最近一次拍摄'),
                ),
              ),
            ),
            IgnorePointer(
              child: DecoratedBox(
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
            ),
            const Positioned(
              left: 18,
              bottom: 18,
              child: IgnorePointer(
                child: Text(
                  '最近一次拍摄',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
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
    final canRetry =
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
                      if (item.box.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '箱子：${item.box}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '录入时间：${_formatCardTime(item.createdAt)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        '识别时间：${_recognitionTimeLabel(item)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Chip(label: Text(item.queueState.label)),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: 120,
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
                    style: FilledButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                    ),
                    child: Text(
                      canConfirm ? '编辑后添加' : '识别中',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                SizedBox(
                  width: 104,
                  child: FilledButton.tonal(
                    onPressed: !canConfirm
                        ? null
                        : () => controller.confirmPendingItem(
                            item.copyWith(
                              queueState: QueueRecognitionState.ready,
                              recognitionError: '',
                              updatedAt: DateTime.now(),
                            ),
                          ),
                    style: FilledButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 12,
                      ),
                    ),
                    child: const Text(
                      '直接添加',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                if (canRetry)
                  OutlinedButton.icon(
                    onPressed: () =>
                        controller.retryPendingRecognition(item.id),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重新识别'),
                    style: OutlinedButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
                OutlinedButton(
                  onPressed: () => controller.removePendingItem(item.id),
                  style: OutlinedButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 12),
                  ),
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

String _formatCardTime(DateTime value) {
  return '${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
}

String _recognitionTimeLabel(ItemRecord item) {
  return switch (item.queueState) {
    QueueRecognitionState.queued => '待识别',
    QueueRecognitionState.processing => '识别中',
    QueueRecognitionState.ready ||
    QueueRecognitionState.failed => _formatCardTime(item.updatedAt),
  };
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

    return LocalImageFrame(
      path: item.imagePath,
      width: 64,
      height: 64,
      borderRadius: BorderRadius.circular(18),
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
              ? LocalImageFrame(
                  path: item.imagePath,
                  width: 56,
                  height: 56,
                  borderRadius: BorderRadius.circular(14),
                )
              : CircleAvatar(
                  backgroundColor: AppTheme.mint,
                  child: Text(
                    item.name.isEmpty ? '?' : item.name.substring(0, 1),
                  ),
                ),
          title: Text(item.name),
          subtitle: Text(
            item.box.trim().isEmpty
                ? '${item.category} · ${item.status.label}'
                : '${item.category} · ${item.status.label} · ${item.box}',
          ),
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
