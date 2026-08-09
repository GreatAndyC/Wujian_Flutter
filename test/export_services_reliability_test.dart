import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/services/excel_export_service.dart';
import 'package:icheck/data/services/markdown_export_service.dart';
import 'package:icheck/data/services/media_storage_service.dart';
import 'package:icheck/domain/entities/export_grouping.dart';
import 'package:icheck/domain/entities/item_record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory documents;
  late Directory temporary;
  late MediaStorageService mediaStorage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wujian-export-test-');
    documents = Directory('${root.path}/documents');
    temporary = Directory('${root.path}/temporary');
    await documents.create(recursive: true);
    await temporary.create(recursive: true);
    mediaStorage = MediaStorageService(
      documentsDirectoryProvider: () async => documents,
      temporaryDirectoryProvider: () async => temporary,
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('真实 Markdown 导出不会被未来时间戳旧文件立即清理', () async {
    final exports = await mediaStorage.exportsDirectory();
    final futureModifiedAt = DateTime.now().add(const Duration(days: 30));
    final seeded = <File>[];
    for (var index = 0; index < 6; index++) {
      final file = File('${exports.path}/future-$index.md');
      await file.writeAsString('future export $index');
      await file.setLastModified(
        futureModifiedAt.add(Duration(seconds: index)),
      );
      seeded.add(file);
    }

    final before = await mediaStorage.computeUsage();
    final exported = await MarkdownExportService(
      mediaStorage,
    ).exportItems(items: [_item()], grouping: ExportGrouping.category);
    final after = await mediaStorage.computeUsage();

    expect(await exported.exists(), isTrue);
    expect(after.exportCount, 6);
    expect(seeded.where((file) => file.existsSync()), hasLength(5));
    expect(after.exportBytes, greaterThan(0));
    // ignore: avoid_print
    print(
      '[storage-metrics] protected-export '
      'beforeCount=${before.exportCount} '
      'beforeBytes=${before.exportBytes} '
      'afterCount=${after.exportCount} '
      'afterBytes=${after.exportBytes} '
      'returnedFileExists=${await exported.exists()}',
    );
  });

  test('固定时钟下并发 Markdown 和 Excel 导出仍使用唯一路径并有界保留', () async {
    final fixedStorage = MediaStorageService(
      documentsDirectoryProvider: () async => documents,
      temporaryDirectoryProvider: () async => temporary,
      timestampProvider: () => DateTime.parse('2026-08-09T12:00:00Z'),
    );
    final markdown = MarkdownExportService(fixedStorage);
    final excel = ExcelExportService(fixedStorage);
    final exported = await Future.wait([
      for (var index = 0; index < 4; index++)
        markdown.exportItems(
          items: [_item(id: 'markdown-$index')],
          grouping: ExportGrouping.category,
        ),
      for (var index = 0; index < 4; index++)
        excel.exportItems(
          items: [_item(id: 'excel-$index')],
          grouping: ExportGrouping.box,
        ),
    ]);

    final usage = await fixedStorage.computeUsage();
    final retained = Directory(
      '${temporary.path}/exports',
    ).listSync().whereType<File>().toList();
    expect(exported.map((file) => file.path).toSet(), hasLength(8));
    expect(usage.exportCount, 6);
    expect(retained, hasLength(6));
    expect(
      retained.map((file) => file.path),
      everyElement(isIn(exported.map((file) => file.path))),
    );
    expect(retained.any((file) => file.path.contains('.tmp-')), isFalse);
    expect(usage.exportBytes, greaterThan(0));
    // ignore: avoid_print
    print(
      '[storage-metrics] bounded-real-exports '
      'created=${exported.length} '
      'uniquePaths=${exported.map((file) => file.path).toSet().length} '
      'retained=${usage.exportCount} '
      'retainedBytes=${usage.exportBytes}',
    );
  });

  test('导出文件名拒绝路径穿越且不会在临时目录外落盘', () async {
    expect(
      () => mediaStorage.writeExportBytes(
        baseName: '../escape',
        extension: 'md',
        bytes: const [1, 2, 3],
      ),
      throwsArgumentError,
    );
    expect(await File('${temporary.path}/escape.md').exists(), isFalse);
    expect((await mediaStorage.computeUsage()).exportCount, 0);
  });
}

ItemRecord _item({String id = 'export-item'}) {
  final now = DateTime.parse('2026-08-09T12:00:00Z');
  return ItemRecord(
    id: id,
    name: '测试物品',
    category: '测试分类',
    quantity: 1,
    status: ItemStatus.cataloged,
    imagePath: '',
    description: '用于验证导出临时文件生命周期',
    parameters: const {'来源': '自动化夹具'},
    notes: '',
    room: '测试房间',
    box: '测试箱',
    brand: '',
    model: '',
    color: '',
    material: '',
    createdAt: now,
    updatedAt: now,
    queueState: QueueRecognitionState.ready,
    recognitionError: '',
  );
}
