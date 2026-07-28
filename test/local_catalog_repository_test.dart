import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/repositories/local_catalog_repository.dart';
import 'package:icheck/domain/entities/item_record.dart';
import 'package:icheck/domain/repositories/catalog_repository.dart';

void main() {
  late Directory root;
  late LocalCatalogRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wujian-catalog-test-');
    repository = LocalCatalogRepository(
      documentsDirectoryProvider: () async => root,
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('首次启动迁移旧双 JSON 文件并归档旧文件', () async {
    final item = _item(id: 'legacy-item', name: '旧物品');
    final pending = _item(
      id: 'legacy-pending',
      name: '待识别',
      queueState: QueueRecognitionState.queued,
    );
    await File(
      '${root.path}/items.json',
    ).writeAsString(jsonEncode([item.toJson()]));
    await File(
      '${root.path}/pending_items.json',
    ).writeAsString(jsonEncode([pending.toJson()]));

    final loaded = await repository.loadCatalog();

    expect(loaded.items.single.id, 'legacy-item');
    expect(loaded.pendingItems.single.id, 'legacy-pending');
    expect(await File('${root.path}/catalog.json').exists(), isTrue);
    expect(await File('${root.path}/catalog.json.backup').exists(), isTrue);
    expect(await File('${root.path}/items.json.migrated').exists(), isTrue);
    expect(
      await File('${root.path}/pending_items.json.migrated').exists(),
      isTrue,
    );
  });

  test('主文件损坏时从已校验备份恢复最新目录', () async {
    final snapshot = CatalogSnapshot(
      items: [_item(id: 'saved-item', name: '已保存物品')],
      pendingItems: const [],
    );
    await repository.saveCatalog(snapshot);
    await File('${root.path}/catalog.json').writeAsString('{broken json');

    final recovered = await LocalCatalogRepository(
      documentsDirectoryProvider: () async => root,
    ).loadCatalog();

    expect(recovered.items.single.id, 'saved-item');
    expect(
      Directory(root.path).listSync().whereType<File>().any(
        (file) => file.path.contains('.corrupt-'),
      ),
      isTrue,
    );
  });

  test('结构不完整的主文件不会被误当成空目录并覆盖备份', () async {
    final snapshot = CatalogSnapshot(
      items: [_item(id: 'protected-item', name: '受保护物品')],
      pendingItems: const [],
    );
    await repository.saveCatalog(snapshot);
    await File('${root.path}/catalog.json').writeAsString('{}');

    final recovered = await LocalCatalogRepository(
      documentsDirectoryProvider: () async => root,
    ).loadCatalog();

    expect(recovered.items.single.id, 'protected-item');
  });

  test('更高版本目录会停止加载而不是被旧版覆盖', () async {
    final catalog = File('${root.path}/catalog.json');
    await catalog.writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'items': const [],
        'pendingItems': const [],
      }),
    );

    await expectLater(repository.loadCatalog(), throwsUnsupportedError);

    final preserved = jsonDecode(await catalog.readAsString());
    expect(preserved['schemaVersion'], 2);
  });

  test('并发保存会串行执行且最后一次写入完整可读', () async {
    final saves = [
      for (var index = 0; index < 5; index++)
        repository.saveCatalog(
          CatalogSnapshot(
            items: [_item(id: 'item-$index', name: '物品$index')],
            pendingItems: const [],
          ),
        ),
    ];

    await Future.wait(saves);
    final loaded = await repository.loadCatalog();

    expect(loaded.items.single.id, 'item-4');
  });
}

ItemRecord _item({
  required String id,
  required String name,
  QueueRecognitionState queueState = QueueRecognitionState.ready,
}) {
  final now = DateTime.parse('2026-07-28T12:00:00Z');
  return ItemRecord(
    id: id,
    name: name,
    category: '杂物',
    quantity: 1,
    status: ItemStatus.pending,
    imagePath: '/tmp/$id.jpg',
    description: '',
    parameters: const {},
    notes: '',
    room: '',
    box: '',
    brand: '',
    model: '',
    color: '',
    material: '',
    createdAt: now,
    updatedAt: now,
    queueState: queueState,
    recognitionError: '',
  );
}
