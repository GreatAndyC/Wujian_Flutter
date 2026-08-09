import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/repositories/local_catalog_repository.dart';
import 'package:icheck/data/services/media_storage_service.dart';
import 'package:icheck/data/services/storage_mutation_coordinator.dart';
import 'package:icheck/domain/entities/item_record.dart';
import 'package:icheck/domain/repositories/catalog_repository.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory otherRoot;
  late Directory temporary;
  final coordinator = StorageMutationCoordinator.shared;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp(
      'wujian-storage-coordinator-test-',
    );
    root = Directory('${sandbox.path}${Platform.pathSeparator}documents');
    otherRoot = Directory(
      '${sandbox.path}${Platform.pathSeparator}other-documents',
    );
    temporary = Directory('${sandbox.path}${Platform.pathSeparator}temporary');
    await root.create(recursive: true);
    await otherRoot.create(recursive: true);
    await temporary.create(recursive: true);
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('同一 canonical root 的普通 mutation 跨调用串行且保持入队顺序', () async {
    final nested = Directory('${root.path}${Platform.pathSeparator}nested');
    await nested.create();
    final alias = Directory('${nested.path}${Platform.pathSeparator}..');
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    var secondEntered = false;
    final events = <String>[];

    final first = coordinator.run(root, (_) async {
      events.add('first-start');
      firstEntered.complete();
      await releaseFirst.future;
      events.add('first-end');
    });
    await firstEntered.future;
    final second = coordinator.run(alias, (_) async {
      secondEntered = true;
      events.add('second');
    });

    await _drainEventQueue();
    expect(secondEntered, isFalse);

    releaseFirst.complete();
    await Future.wait<void>([first, second]);
    expect(events, <String>['first-start', 'first-end', 'second']);
  });

  test('同步 admission ticket 保持 provider 逆序完成时的调用顺序', () async {
    final firstRoot = Completer<Directory>();
    final events = <String>[];

    final first = coordinator.runWithRootProvider(
      () => firstRoot.future,
      (_) async => events.add('first'),
    );
    final second = coordinator.runWithRootProvider(
      () async => root,
      (_) async => events.add('second'),
    );

    await _drainEventQueue();
    expect(events, isEmpty);

    firstRoot.complete(root);
    await Future.wait<void>([first, second]);
    expect(events, <String>['first', 'second']);
  });

  test('不同 canonical root 可以并行执行', () async {
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    var secondCompleted = false;

    final first = coordinator.run(root, (_) async {
      firstEntered.complete();
      await releaseFirst.future;
    });
    await firstEntered.future;

    await coordinator.run(otherRoot, (_) async {
      secondCompleted = true;
    });
    expect(secondCompleted, isTrue);

    releaseFirst.complete();
    await first;
  });

  test('同 Zone 同根 exclusive 可重入普通调用且不死锁', () async {
    final nested = Directory('${root.path}${Platform.pathSeparator}nested');
    await nested.create();
    final alias = Directory('${nested.path}${Platform.pathSeparator}..');

    final result = await coordinator
        .run(
          root,
          (outerRoot) => coordinator.run(alias, (innerRoot) async {
            expect(innerRoot.path, outerRoot.path);
            return 42;
          }, rejectWhenExclusive: true),
          exclusive: true,
          failIfBusy: true,
        )
        .timeout(const Duration(seconds: 5));

    expect(result, 42);
  });

  test('failIfBusy 在已有运行者和排队者时立即失败', () async {
    final activeEntered = Completer<void>();
    final releaseActive = Completer<void>();
    var queuedEntered = false;

    final active = coordinator.run(root, (_) async {
      activeEntered.complete();
      await releaseActive.future;
    });
    await activeEntered.future;
    final queued = coordinator.run(root, (_) async {
      queuedEntered = true;
    });
    await _drainEventQueue();

    await expectLater(
      coordinator.run(root, (_) async {}, exclusive: true, failIfBusy: true),
      throwsA(isA<StorageMutationBusyException>()),
    );
    expect(queuedEntered, isFalse);

    releaseActive.complete();
    await Future.wait<void>([active, queued]);
    expect(queuedEntered, isTrue);
  });

  test('exclusive 排队占位后拒绝携带陈旧状态的普通 mutation', () async {
    final ordinaryEntered = Completer<void>();
    final releaseOrdinary = Completer<void>();
    final exclusiveEntered = Completer<void>();
    final releaseExclusive = Completer<void>();

    final ordinary = coordinator.run(root, (_) async {
      ordinaryEntered.complete();
      await releaseOrdinary.future;
    });
    await ordinaryEntered.future;
    final exclusive = coordinator.run(root, (_) async {
      exclusiveEntered.complete();
      await releaseExclusive.future;
    }, exclusive: true);
    await _drainEventQueue();

    await expectLater(
      coordinator.run(root, (_) async {}, rejectWhenExclusive: true),
      throwsA(isA<StorageMutationBusyException>()),
    );

    releaseOrdinary.complete();
    await exclusiveEntered.future;
    releaseExclusive.complete();
    await Future.wait<void>([ordinary, exclusive]);
  });

  test('action 抛错后释放 root，后续调用可继续', () async {
    await expectLater(
      coordinator.run<void>(root, (_) async => throw StateError('expected')),
      throwsStateError,
    );

    var completed = false;
    await coordinator.run(root, (_) async {
      completed = true;
    });
    expect(completed, isTrue);
  });

  test('busy 公开文本不包含 canonical root 或合成敏感标记', () async {
    const marker = 'SYNTHETIC-ROOT-MARKER-7f31';
    final markedRoot = Directory(
      '${root.path}${Platform.pathSeparator}$marker',
    );
    final exclusiveEntered = Completer<void>();
    final releaseExclusive = Completer<void>();
    final exclusive = coordinator.run(markedRoot, (_) async {
      exclusiveEntered.complete();
      await releaseExclusive.future;
    }, exclusive: true);
    await exclusiveEntered.future;

    final error = await _captureError(
      coordinator.run<void>(
        markedRoot,
        (_) async {},
        rejectWhenExclusive: true,
      ),
    );
    final text = error.toString();
    expect(error, isA<StorageMutationBusyException>());
    expect(text, isNot(contains(markedRoot.path)));
    expect(text, isNot(contains(marker)));

    releaseExclusive.complete();
    await exclusive;
  });

  test('provider 文件系统失败映射文本不包含路径或合成敏感标记', () async {
    const marker = 'SYNTHETIC-FS-MARKER-29ac';
    final syntheticPath = '${root.path}${Platform.pathSeparator}$marker';

    final error = await _captureError(
      coordinator.runWithRootProvider<void>(
        () async =>
            throw FileSystemException('provider failed $marker', syntheticPath),
        (_) async {},
      ),
    );
    final text = error.toString();
    expect(error, isA<FileSystemException>());
    expect(text, contains('应用数据目录不可用'));
    expect(text, isNot(contains(syntheticPath)));
    expect(text, isNot(contains(marker)));

    var subsequentCompleted = false;
    await coordinator.run(root, (_) async {
      subsequentCompleted = true;
    });
    expect(subsequentCompleted, isTrue);
  });

  test('catalog 与 media 实例使用共享外锁并在普通占用后排队', () async {
    final repository = LocalCatalogRepository(
      documentsDirectoryProvider: () async => root,
    );
    final media = MediaStorageService(
      documentsDirectoryProvider: () async => root,
      temporaryDirectoryProvider: () async => temporary,
    );
    final source = File('${temporary.path}${Platform.pathSeparator}source.jpg');
    await source.writeAsBytes(_jpeg());
    final heldEntered = Completer<void>();
    final releaseHeld = Completer<void>();
    var catalogCompleted = false;
    var mediaCompleted = false;

    final held = coordinator.run(root, (_) async {
      heldEntered.complete();
      await releaseHeld.future;
    });
    await heldEntered.future;
    final catalogMutation = repository
        .saveCatalog(CatalogSnapshot(items: [_item()], pendingItems: const []))
        .then((_) {
          catalogCompleted = true;
        });
    final mediaMutation = media
        .persistImage(source, deleteTemporarySource: false)
        .then((_) {
          mediaCompleted = true;
        });

    await _drainEventQueue();
    expect(catalogCompleted, isFalse);
    expect(mediaCompleted, isFalse);

    releaseHeld.complete();
    await Future.wait<void>([held, catalogMutation, mediaMutation]);
    expect(catalogCompleted, isTrue);
    expect(mediaCompleted, isTrue);
  });

  test('exclusive owner 内调用 catalog 与 media 可重入共享外锁', () async {
    final repository = LocalCatalogRepository(
      documentsDirectoryProvider: () async => root,
    );
    final media = MediaStorageService(
      documentsDirectoryProvider: () async => root,
      temporaryDirectoryProvider: () async => temporary,
    );
    final source = File('${temporary.path}${Platform.pathSeparator}source.jpg');
    await source.writeAsBytes(_jpeg());

    await coordinator
        .run(
          root,
          (_) async {
            await repository.saveCatalog(
              CatalogSnapshot(items: [_item()], pendingItems: const []),
            );
            await media.persistImage(source, deleteTemporarySource: false);
          },
          exclusive: true,
          failIfBusy: true,
        )
        .timeout(const Duration(seconds: 10));

    expect((await repository.loadCatalog()).items.single.id, 'coordinated');
    expect(
      Directory(
        '${root.path}${Platform.pathSeparator}images',
      ).listSync().whereType<File>(),
      hasLength(1),
    );
  });

  test('media storage transaction 内的 media 与 catalog mutation 可重入', () async {
    final repository = LocalCatalogRepository(
      documentsDirectoryProvider: () async => root,
    );
    final media = MediaStorageService(
      documentsDirectoryProvider: () async => root,
      temporaryDirectoryProvider: () async => temporary,
    );
    final source = File('${temporary.path}${Platform.pathSeparator}source.jpg');
    await source.writeAsBytes(_jpeg());

    await media
        .runStorageTransaction(() async {
          await media.persistImage(source, deleteTemporarySource: false);
          await repository.saveCatalog(
            CatalogSnapshot(items: [_item()], pendingItems: const []),
          );
        })
        .timeout(const Duration(seconds: 10));

    expect((await repository.loadCatalog()).items.single.id, 'coordinated');
    expect(
      Directory(
        '${root.path}${Platform.pathSeparator}images',
      ).listSync().whereType<File>(),
      hasLength(1),
    );
  });

  test('exclusive 期间外部 catalog 与 media mutation 立即返回 busy', () async {
    final repository = LocalCatalogRepository(
      documentsDirectoryProvider: () async => root,
    );
    final media = MediaStorageService(
      documentsDirectoryProvider: () async => root,
      temporaryDirectoryProvider: () async => temporary,
    );
    final exclusiveEntered = Completer<void>();
    final releaseExclusive = Completer<void>();

    final exclusive = coordinator.run(
      root,
      (_) async {
        exclusiveEntered.complete();
        await releaseExclusive.future;
      },
      exclusive: true,
      failIfBusy: true,
    );
    await exclusiveEntered.future;

    await expectLater(
      repository.saveCatalog(
        CatalogSnapshot(items: [_item()], pendingItems: const []),
      ),
      throwsA(isA<StorageMutationBusyException>()),
    );
    await expectLater(
      media.optimizeStorage(referencedImagePaths: const <String>[]),
      throwsA(isA<StorageMutationBusyException>()),
    );
    await expectLater(
      media.runStorageTransaction(() async {}),
      throwsA(isA<StorageMutationBusyException>()),
    );

    releaseExclusive.complete();
    await exclusive;
  });
}

Future<void> _drainEventQueue() async {
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

Future<Object> _captureError(Future<void> future) async {
  try {
    await future;
  } catch (error) {
    return error;
  }
  fail('Expected the operation to fail.');
}

ItemRecord _item() {
  final now = DateTime.parse('2026-08-10T00:00:00Z');
  return ItemRecord(
    id: 'coordinated',
    name: '协调测试物品',
    category: '测试',
    quantity: 1,
    status: ItemStatus.cataloged,
    imagePath: '',
    description: '',
    parameters: const <String, String>{},
    notes: '',
    room: '',
    box: '',
    brand: '',
    model: '',
    color: '',
    material: '',
    createdAt: now,
    updatedAt: now,
  );
}

List<int> _jpeg() {
  final image = img.Image(width: 32, height: 24);
  img.fill(image, color: img.ColorRgb8(30, 120, 180));
  return img.encodeJpg(image);
}
