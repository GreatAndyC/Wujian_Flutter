import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/services/backup_file_system.dart';
import 'package:icheck/data/services/backup_restore_service.dart';
import 'package:icheck/data/services/media_storage_service.dart';
import 'package:icheck/data/services/storage_mutation_coordinator.dart';
import 'package:icheck/domain/entities/backup_restore.dart';
import 'package:icheck/domain/entities/item_record.dart';
import 'package:icheck/domain/repositories/catalog_repository.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory sandbox;
  late Directory sourceRoot;
  late Directory targetRoot;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('wujian-backup-test-');
    sourceRoot = Directory(_join(sandbox.path, 'source-documents'));
    targetRoot = Directory(_join(sandbox.path, 'target-documents'));
    await sourceRoot.create(recursive: true);
    await targetRoot.create(recursive: true);
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('创建、校验与替换恢复闭环按真实字节去重并移除源绝对路径', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final packageEntries = await _readZipEntries(fixture.result.file);
    final manifest =
        jsonDecode(utf8.decode(packageEntries['manifest.json']!))
            as Map<String, dynamic>;
    final catalogText = utf8.decode(packageEntries['data/catalog.json']!);
    final mediaManifest =
        (manifest['media'] as List<dynamic>).single as Map<String, dynamic>;
    final logicalMediaPath = mediaManifest['path'] as String;
    final actualDigest = sha256.convert(fixture.mediaBytes).toString();

    expect(fixture.result.inspection.formatVersion, 1);
    expect(fixture.result.inspection.itemCount, 1);
    expect(fixture.result.inspection.pendingItemCount, 1);
    expect(fixture.result.inspection.mediaCount, 1);
    expect(fixture.result.inspection.mediaBytes, fixture.mediaBytes.length);
    expect(mediaManifest['byteLength'], fixture.mediaBytes.length);
    expect(mediaManifest['sha256'], actualDigest);
    expect(logicalMediaPath, 'media/$actualDigest.jpg');
    expect(
      packageEntries.keys,
      unorderedEquals(<String>[
        'manifest.json',
        'data/catalog.json',
        logicalMediaPath,
      ]),
    );
    expect(catalogText, isNot(contains(sourceRoot.path)));
    expect(jsonEncode(manifest), isNot(contains(sourceRoot.path)));
    expect(
      packageEntries.keys.any((path) => path.contains(sourceRoot.path)),
      isFalse,
    );

    final targetRepository = _MemoryCatalogRepository(
      const CatalogSnapshot.empty(),
    );
    final targetService = _service(targetRoot, targetRepository);
    final inspection = await targetService.validateBackup(fixture.result.file);
    final restored = await targetService.restoreBackup(
      fixture.result.file,
      mode: BackupRestoreMode.replace,
    );

    expect(inspection.mediaCount, 1);
    expect(restored.createdMediaCount, 1);
    expect(restored.snapshot.items, hasLength(1));
    expect(restored.snapshot.pendingItems, hasLength(1));
    final restoredPaths = <String>{
      restored.snapshot.items.single.imagePath,
      restored.snapshot.pendingItems.single.imagePath,
    };
    expect(restoredPaths, hasLength(1));
    final restoredMedia = File(restoredPaths.single);
    final canonicalTargetRoot = await targetRoot.resolveSymbolicLinks();
    expect(restoredMedia.parent.path, _join(canonicalTargetRoot, 'images'));
    expect(await restoredMedia.readAsBytes(), fixture.mediaBytes);
    expect(await restoredMedia.length(), fixture.mediaBytes.length);
    expect(
      sha256.convert(await restoredMedia.readAsBytes()).toString(),
      actualDigest,
    );
  });

  test('两个不同源文件具有相同字节时导出只生成一份媒体条目', () async {
    final images = Directory(_join(sourceRoot.path, 'images'));
    await images.create(recursive: true);
    final identicalBytes = _jpeg(red: 65, green: 135, blue: 205);
    final firstSource = File(_join(images.path, 'first-source.jpg'));
    final secondSource = File(_join(images.path, 'second-source.jpg'));
    await firstSource.writeAsBytes(identicalBytes, flush: true);
    await secondSource.writeAsBytes(identicalBytes, flush: true);
    final repository = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(
            id: 'first-byte-equal',
            name: '相同字节源一',
            imagePath: firstSource.path,
          ),
          _item(
            id: 'second-byte-equal',
            name: '相同字节源二',
            imagePath: secondSource.path,
          ),
        ],
        pendingItems: const [],
      ),
    );

    final result = await _service(
      sourceRoot,
      repository,
    ).createBackup(baseName: 'equal-content');
    final entries = await _readZipEntries(result.file);
    final catalog =
        jsonDecode(utf8.decode(entries['data/catalog.json']!))
            as Map<String, dynamic>;
    final catalogItems = catalog['items'] as List<dynamic>;
    final logicalPaths = catalogItems
        .map((entry) => (entry as Map<String, dynamic>)['imagePath'] as String)
        .toSet();

    expect(result.inspection.itemCount, 2);
    expect(result.inspection.mediaCount, 1);
    expect(result.inspection.mediaBytes, identicalBytes.length);
    expect(
      entries.keys.where((path) => path.startsWith('media/')),
      hasLength(1),
    );
    expect(logicalPaths, hasLength(1));
    expect(await firstSource.readAsBytes(), identicalBytes);
    expect(await secondSource.readAsBytes(), identicalBytes);
  });

  test('导出从 documents root 解析 catalog 相对媒体路径并重写为包内逻辑路径', () async {
    final images = Directory(_join(sourceRoot.path, 'images'));
    await images.create(recursive: true);
    final legacyBytes = _jpeg(red: 70, green: 130, blue: 190);
    final legacyMedia = File(_join(images.path, 'legacy.jpg'));
    await legacyMedia.writeAsBytes(legacyBytes, flush: true);
    final repository = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(
            id: 'relative-export-item',
            name: '相对路径旧目录',
            imagePath: 'images/legacy.jpg',
          ),
        ],
        pendingItems: const [],
      ),
    );

    final result = await _service(
      sourceRoot,
      repository,
    ).createBackup(baseName: 'relative-catalog-path');
    final entries = await _readZipEntries(result.file);
    final catalog =
        jsonDecode(utf8.decode(entries['data/catalog.json']!))
            as Map<String, dynamic>;
    final exportedItem =
        (catalog['items'] as List<dynamic>).single as Map<String, dynamic>;
    final digest = sha256.convert(legacyBytes).toString();
    final logicalPath = 'media/$digest.jpg';

    expect(result.inspection.mediaCount, 1);
    expect(result.inspection.mediaBytes, legacyBytes.length);
    expect(exportedItem['imagePath'], logicalPath);
    expect(entries[logicalPath], legacyBytes);
    expect(await legacyMedia.readAsBytes(), legacyBytes);
  });

  test('位于目标 images 且伪装图片扩展的输入包与非媒体 sidecar 在 replace 后保留', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final images = Directory(_join(targetRoot.path, 'images'));
    await images.create(recursive: true);
    final disguisedPackage = File(
      _join(images.path, 'incoming-local-backup.jpg'),
    );
    final packageBytes = await fixture.result.file.readAsBytes();
    await disguisedPackage.writeAsBytes(packageBytes, flush: true);
    final sidecar = File(_join(images.path, 'incoming-local-backup.sidecar'));
    final sidecarBytes = utf8.encode('synthetic-sidecar-metadata');
    await sidecar.writeAsBytes(sidecarBytes, flush: true);
    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());

    final restored = await _service(
      targetRoot,
      repository,
    ).restoreBackup(disguisedPackage, mode: BackupRestoreMode.replace);

    expect(restored.snapshot.items, hasLength(1));
    expect(restored.snapshot.pendingItems, hasLength(1));
    expect(await disguisedPackage.exists(), isTrue);
    expect(await disguisedPackage.readAsBytes(), packageBytes);
    expect(
      sha256.convert(await disguisedPackage.readAsBytes()).toString(),
      sha256.convert(packageBytes).toString(),
    );
    expect(await sidecar.exists(), isTrue);
    expect(await sidecar.readAsBytes(), sidecarBytes);
    final restoredMedia = File(restored.snapshot.items.single.imagePath);
    expect(await restoredMedia.readAsBytes(), fixture.mediaBytes);
  });

  test('合并模式连续导入同一包保持目录、待确认项和媒体字节幂等', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final targetRepository = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [_item(id: 'existing', name: '原有物品')],
        pendingItems: const [],
      ),
    );
    final targetService = _service(targetRoot, targetRepository);

    final first = await targetService.restoreBackup(
      fixture.result.file,
      mode: BackupRestoreMode.merge,
    );
    final firstSignature = _snapshotSignature(targetRepository.snapshot);
    final firstMetrics = await _imageMetrics(targetRoot);
    final second = await targetService.restoreBackup(
      fixture.result.file,
      mode: BackupRestoreMode.merge,
    );
    final secondMetrics = await _imageMetrics(targetRoot);

    expect(first.snapshot.items, hasLength(2));
    expect(first.snapshot.pendingItems, hasLength(1));
    expect(first.createdMediaCount, 1);
    expect(second.createdMediaCount, 0);
    expect(second.snapshot.items, hasLength(2));
    expect(second.snapshot.pendingItems, hasLength(1));
    expect(_snapshotSignature(targetRepository.snapshot), firstSignature);
    expect(secondMetrics.fileCount, firstMetrics.fileCount);
    expect(secondMetrics.totalBytes, firstMetrics.totalBytes);
    expect(secondMetrics.fileCount, 1);
    expect(secondMetrics.totalBytes, fixture.mediaBytes.length);
  });

  test('merge 保留 current catalog 的相对媒体引用及其目标文件', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final images = Directory(_join(targetRoot.path, 'images'));
    await images.create(recursive: true);
    final legacyBytes = _jpeg(red: 155, green: 95, blue: 35);
    final legacyMedia = File(_join(images.path, 'legacy.jpg'));
    await legacyMedia.writeAsBytes(legacyBytes, flush: true);
    final repository = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(
            id: 'relative-current-item',
            name: '保留相对媒体',
            imagePath: 'images/legacy.jpg',
          ),
        ],
        pendingItems: const [],
      ),
    );

    final restored = await _service(
      targetRoot,
      repository,
    ).restoreBackup(fixture.result.file, mode: BackupRestoreMode.merge);

    final preserved = restored.snapshot.items.singleWhere(
      (item) => item.id == 'relative-current-item',
    );
    expect(preserved.imagePath, 'images/legacy.jpg');
    expect(await legacyMedia.exists(), isTrue);
    expect(await legacyMedia.readAsBytes(), legacyBytes);
    expect(restored.snapshot.items, hasLength(2));
    expect(restored.snapshot.pendingItems, hasLength(1));
    expect((await _imageMetrics(targetRoot)).fileCount, 2);
  });

  test('媒体内容损坏在恢复写入前被 SHA-256 校验拒绝且目标字节不变', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final corrupted = File(_join(sandbox.path, 'corrupted-media.zip'));
    await _rewritePackage(fixture.result.file, corrupted, (entries) {
      final mediaPath = entries.keys.singleWhere(
        (path) => path.startsWith('media/'),
      );
      final bytes = List<int>.from(entries[mediaPath]!);
      bytes[bytes.length ~/ 2] ^= 0x01;
      entries[mediaPath] = bytes;
    });

    final preserved = await _preservedTarget(targetRoot);
    final service = _service(targetRoot, preserved.repository);
    await _expectCode(
      service.restoreBackup(corrupted),
      BackupRestoreErrorCode.hashMismatch,
    );

    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    expect(await _imageTree(targetRoot), preserved.imageTree);
  });

  test('媒体文件缺失在恢复写入前被引用完整性校验拒绝', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final missing = File(_join(sandbox.path, 'missing-media.zip'));
    await _rewritePackage(fixture.result.file, missing, (entries) {
      final mediaPath = entries.keys.singleWhere(
        (path) => path.startsWith('media/'),
      );
      entries.remove(mediaPath);
    });

    final preserved = await _preservedTarget(targetRoot);
    await _expectCode(
      _service(targetRoot, preserved.repository).restoreBackup(missing),
      BackupRestoreErrorCode.missingMedia,
    );

    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    expect(await _imageTree(targetRoot), preserved.imageTree);
  });

  test('尺寸与 SHA 正确但无法解码的媒体仍被拒绝', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final invalid = File(_join(sandbox.path, 'invalid-media.zip'));
    await _rewritePackage(fixture.result.file, invalid, (entries) {
      final manifest =
          jsonDecode(utf8.decode(entries['manifest.json']!))
              as Map<String, dynamic>;
      final catalog =
          jsonDecode(utf8.decode(entries['data/catalog.json']!))
              as Map<String, dynamic>;
      final media =
          (manifest['media'] as List<dynamic>).single as Map<String, dynamic>;
      final previousPath = media['path'] as String;
      final payload = List<int>.generate(128, (index) => index & 0xff);
      final digest = sha256.convert(payload).toString();
      final nextPath = 'media/$digest.jpg';
      for (final collectionName in <String>['items', 'pendingItems']) {
        for (final rawItem in catalog[collectionName] as List<dynamic>) {
          (rawItem as Map<String, dynamic>)['imagePath'] = nextPath;
        }
      }
      final catalogBytes = utf8.encode(jsonEncode(catalog));
      final catalogManifest = manifest['catalog'] as Map<String, dynamic>;
      catalogManifest['byteLength'] = catalogBytes.length;
      catalogManifest['sha256'] = sha256.convert(catalogBytes).toString();
      media['path'] = nextPath;
      media['byteLength'] = payload.length;
      media['sha256'] = digest;
      entries.remove(previousPath);
      entries[nextPath] = payload;
      entries['data/catalog.json'] = catalogBytes;
      entries['manifest.json'] = utf8.encode(jsonEncode(manifest));
    });

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(invalid),
      BackupRestoreErrorCode.invalidMedia,
    );
    expect((await _imageMetrics(targetRoot)).fileCount, 0);
  });

  test('更高备份格式版本被明确拒绝而不进入恢复事务', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final futureVersion = File(_join(sandbox.path, 'future-version.zip'));
    await _rewritePackage(fixture.result.file, futureVersion, (entries) {
      final manifest =
          jsonDecode(utf8.decode(entries['manifest.json']!))
              as Map<String, dynamic>;
      manifest['formatVersion'] = 2;
      entries['manifest.json'] = utf8.encode(jsonEncode(manifest));
    });

    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    await _expectCode(
      _service(targetRoot, repository).restoreBackup(futureVersion),
      BackupRestoreErrorCode.unsupportedVersion,
    );
    expect(repository.saveCalls, 0);
    expect((await _imageMetrics(targetRoot)).fileCount, 0);
  });

  test('v1 manifest 创建时间缺少 UTC 时区时按 schema 无效拒绝', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final invalidTime = File(_join(sandbox.path, 'manifest-local-time.zip'));
    await _rewritePackage(fixture.result.file, invalidTime, (entries) {
      final manifest =
          jsonDecode(utf8.decode(entries['manifest.json']!))
              as Map<String, dynamic>;
      manifest['createdAt'] = '2026-08-09T12:00:00';
      entries['manifest.json'] = utf8.encode(jsonEncode(manifest));
    });

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(invalidTime),
      BackupRestoreErrorCode.invalidSchema,
    );
  });

  test('manifest 媒体尺寸篡改在恢复写入前被拒绝且目标字节不变', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final tampered = File(_join(sandbox.path, 'tampered-size.zip'));
    await _rewritePackage(fixture.result.file, tampered, (entries) {
      final manifest =
          jsonDecode(utf8.decode(entries['manifest.json']!))
              as Map<String, dynamic>;
      final media =
          (manifest['media'] as List<dynamic>).single as Map<String, dynamic>;
      media['byteLength'] = (media['byteLength'] as int) + 1;
      entries['manifest.json'] = utf8.encode(jsonEncode(manifest));
    });

    final preserved = await _preservedTarget(targetRoot);
    final service = _service(targetRoot, preserved.repository);
    await _expectCode(
      service.restoreBackup(tampered),
      BackupRestoreErrorCode.sizeMismatch,
    );

    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    expect(await _imageTree(targetRoot), preserved.imageTree);
  });

  test('manifest 业务数据哈希篡改在恢复写入前被拒绝且目标字节不变', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final tampered = File(_join(sandbox.path, 'tampered-hash.zip'));
    await _rewritePackage(fixture.result.file, tampered, (entries) {
      final manifest =
          jsonDecode(utf8.decode(entries['manifest.json']!))
              as Map<String, dynamic>;
      final catalog = manifest['catalog'] as Map<String, dynamic>;
      catalog['sha256'] = List<String>.filled(64, '0').join();
      entries['manifest.json'] = utf8.encode(jsonEncode(manifest));
    });

    final preserved = await _preservedTarget(targetRoot);
    final service = _service(targetRoot, preserved.repository);
    await _expectCode(
      service.restoreBackup(tampered),
      BackupRestoreErrorCode.hashMismatch,
    );

    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    expect(await _imageTree(targetRoot), preserved.imageTree);
  });

  test('旧版双 JSON 与 images 备份可校验并迁移恢复', () async {
    final legacyMedia = _jpeg(red: 70, green: 130, blue: 190);
    final legacyPackage = File(_join(sandbox.path, 'legacy-backup.zip'));
    final item = _item(
      id: 'legacy-item',
      name: '旧版物品',
      imagePath: 'old/location/shared.jpg',
    );
    final pending = _item(
      id: 'legacy-pending',
      name: '旧版待确认',
      imagePath: r'C:\legacy\shared.jpg',
      queueState: QueueRecognitionState.queued,
    );
    await _writeArchive(legacyPackage, [
      _ArchiveEntry('items.json', utf8.encode(jsonEncode([item.toJson()]))),
      _ArchiveEntry(
        'pending_items.json',
        utf8.encode(jsonEncode([pending.toJson()])),
      ),
      _ArchiveEntry('images/shared.jpg', legacyMedia),
    ]);
    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final service = _service(targetRoot, repository);

    final inspection = await service.validateBackup(legacyPackage);
    final restored = await service.restoreBackup(legacyPackage);

    expect(inspection.formatVersion, 0);
    expect(inspection.legacyMigrated, isTrue);
    expect(inspection.itemCount, 1);
    expect(inspection.pendingItemCount, 1);
    expect(inspection.mediaCount, 1);
    expect(inspection.mediaBytes, legacyMedia.length);
    expect(restored.inspection.legacyMigrated, isTrue);
    expect(restored.createdMediaCount, 1);
    expect(restored.snapshot.items.single.id, 'legacy-item');
    expect(restored.snapshot.pendingItems.single.id, 'legacy-pending');
    expect(
      restored.snapshot.items.single.imagePath,
      restored.snapshot.pendingItems.single.imagePath,
    );
    expect(
      await File(restored.snapshot.items.single.imagePath).readAsBytes(),
      legacyMedia,
    );
  });

  test('缺少时间字段的旧版包连续 merge 使用稳定回退时间且语义幂等', () async {
    final legacyPackage = File(
      _join(sandbox.path, 'legacy-missing-timestamps.zip'),
    );
    final legacyObject =
        _item(id: 'legacy-stable-time', name: '缺少旧版时间').toJson()
          ..remove('createdAt')
          ..remove('updatedAt');
    await _writeArchive(legacyPackage, [
      _ArchiveEntry('items.json', utf8.encode(jsonEncode([legacyObject]))),
    ]);
    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final service = _service(targetRoot, repository);

    final first = await service.restoreBackup(
      legacyPackage,
      mode: BackupRestoreMode.merge,
    );
    final firstSignature = _snapshotSignature(first.snapshot);
    final second = await service.restoreBackup(
      legacyPackage,
      mode: BackupRestoreMode.merge,
    );

    expect(first.snapshot.items.single.createdAt, DateTime.utc(1970));
    expect(first.snapshot.items.single.updatedAt, DateTime.utc(1970));
    expect(_snapshotSignature(second.snapshot), firstSignature);
    expect(second.createdMediaCount, 0);
  });

  test('路径穿越条目在任何解压写入前被拒绝', () async {
    final package = File(_join(sandbox.path, 'traversal.zip'));
    await _writeArchive(package, [
      _ArchiveEntry('../escape.json', utf8.encode('{}')),
    ]);

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(package),
      BackupRestoreErrorCode.unsafePath,
    );
    expect(await File(_join(targetRoot.path, 'escape.json')).exists(), isFalse);
    expect(await File(_join(sandbox.path, 'escape.json')).exists(), isFalse);
  });

  test('ZIP 中声明为 Unix 软链接的条目被拒绝', () async {
    final package = File(_join(sandbox.path, 'symlink-entry.zip'));
    await _writeArchive(package, [
      _ArchiveEntry('images/link.jpg', utf8.encode('target.jpg')),
    ]);
    await _markFirstEntryAsUnixSymlink(package);

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(package),
      BackupRestoreErrorCode.symbolicLink,
    );
  });

  test('原始 ZIP 中同名的两个中心目录条目被确定性拒绝', () async {
    final package = File(_join(sandbox.path, 'duplicate-entry.zip'));
    await _writeArchive(package, [
      _ArchiveEntry('items.json', utf8.encode('[]')),
      _ArchiveEntry('items.json', utf8.encode('[]')),
    ]);

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(package),
      BackupRestoreErrorCode.duplicateEntry,
    );
  });

  test('EOCD 伪报条目数少于实际中央目录条目时拒绝整个归档', () async {
    final package = File(_join(sandbox.path, 'underreported-eocd.zip'));
    await _writeArchive(package, [
      _ArchiveEntry('items.json', utf8.encode('[]')),
      _ArchiveEntry('pending_items.json', utf8.encode('[]')),
    ]);
    final bytes = List<int>.from(await package.readAsBytes());
    final eocdOffset = _requireStandardEocd(bytes);
    _setUint16(bytes, eocdOffset + 8, 1);
    _setUint16(bytes, eocdOffset + 10, 1);
    await package.writeAsBytes(bytes, flush: true);

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(package),
      BackupRestoreErrorCode.invalidArchive,
    );
  });

  for (final commentCase in <String>['ordinary', 'embedded-eocd']) {
    test(
      'EOCD comment ${commentCase == 'ordinary' ? '非空' : '内含伪签名'}时拒绝归档',
      () async {
        final package = File(
          _join(sandbox.path, 'eocd-comment-$commentCase.zip'),
        );
        await _writeArchive(package, [
          _ArchiveEntry('items.json', utf8.encode('[]')),
        ]);
        final originalBytes = List<int>.from(await package.readAsBytes());
        final originalEocd = originalBytes.sublist(
          _requireStandardEocd(originalBytes),
        );
        final comment = commentCase == 'ordinary'
            ? utf8.encode('synthetic-audit-comment')
            : originalEocd;
        await _appendZipComment(package, comment);

        await _expectCode(
          _service(
            targetRoot,
            _MemoryCatalogRepository(const CatalogSnapshot.empty()),
          ).validateBackup(package),
          BackupRestoreErrorCode.invalidArchive,
        );
      },
    );
  }

  test('即使完整修正 ZIP offsets，SFX 或隐藏前缀仍按未声明数据拒绝', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final prefixed = File(_join(sandbox.path, 'corrected-sfx-prefix.zip'));

    await _insertUndeclaredZipBytes(
      fixture.result.file,
      prefixed,
      insertionOffset: 0,
      insertedBytes: utf8.encode('synthetic-sfx-prefix'),
    );

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(prefixed),
      BackupRestoreErrorCode.invalidArchive,
    );
  });

  test('修正后续 offsets 后两个 local range 间的未声明 gap 仍被拒绝', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final originalBytes = await fixture.result.file.readAsBytes();
    final localOffsets = _standardZipLocalOffsets(originalBytes)..sort();
    expect(localOffsets.length, greaterThanOrEqualTo(2));
    final gapped = File(_join(sandbox.path, 'corrected-local-gap.zip'));

    await _insertUndeclaredZipBytes(
      fixture.result.file,
      gapped,
      insertionOffset: localOffsets[1],
      insertedBytes: const [0xde, 0xad, 0xbe, 0xef],
    );

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(gapped),
      BackupRestoreErrorCode.invalidArchive,
    );
  });

  final unsafeArchivePaths = <String>[
    'data/媒体.json',
    '${List<String>.filled(256, 'a').join()}.bin',
    'data/CON.txt',
  ];
  for (var index = 0; index < unsafeArchivePaths.length; index++) {
    test('拒绝 Unicode、超长或保留名归档路径 #$index', () async {
      final package = File(_join(sandbox.path, 'unsafe-path-$index.zip'));
      await _writeArchive(package, [
        _ArchiveEntry(unsafeArchivePaths[index], const [1]),
      ]);

      await _expectCode(
        _service(
          targetRoot,
          _MemoryCatalogRepository(const CatalogSnapshot.empty()),
        ).validateBackup(package),
        BackupRestoreErrorCode.unsafePath,
      );
    });
  }

  test('条目数量上限在 schema 解析前生效', () async {
    final package = File(_join(sandbox.path, 'entry-limit.zip'));
    await _writeArchive(package, [
      _ArchiveEntry('one.bin', const [1]),
      _ArchiveEntry('two.bin', const [2]),
    ]);
    final service = _service(
      targetRoot,
      _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      limits: const BackupRestoreLimits(maxEntries: 1),
    );

    await _expectCode(
      service.validateBackup(package),
      BackupRestoreErrorCode.entryLimitExceeded,
    );
  });

  test('展开总字节上限在 schema 解析前生效', () async {
    final package = File(_join(sandbox.path, 'expanded-limit.zip'));
    await _writeArchive(package, [
      _ArchiveEntry('payload.bin', List<int>.filled(64, 1)),
    ]);
    final service = _service(
      targetRoot,
      _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      limits: const BackupRestoreLimits(
        maxSingleEntryBytes: 128,
        maxExpandedBytes: 32,
      ),
    );

    await _expectCode(
      service.validateBackup(package),
      BackupRestoreErrorCode.expandedSizeExceeded,
    );
  });

  test('高压缩比条目在 schema 解析前生效', () async {
    final package = File(_join(sandbox.path, 'compression-ratio.zip'));
    await _writeArchive(package, [
      _ArchiveEntry('payload.bin', List<int>.filled(8192, 0)),
    ], compress: true);
    final service = _service(
      targetRoot,
      _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      limits: const BackupRestoreLimits(maxCompressionRatio: 2),
    );

    await _expectCode(
      service.validateBackup(package),
      BackupRestoreErrorCode.compressionRatioExceeded,
    );
  });

  test('低于压缩比上限的 DEFLATE 仍按 invalidArchive 拒绝且 STORE 包正常校验', () async {
    final storeFixture = await _createBackupFixture(sourceRoot);
    final service = _service(
      targetRoot,
      _MemoryCatalogRepository(const CatalogSnapshot.empty()),
    );
    final storeInspection = await service.validateBackup(
      storeFixture.result.file,
    );
    expect(storeInspection.formatVersion, 1);
    expect(storeInspection.mediaCount, 1);

    final deflatePackage = File(_join(sandbox.path, 'deflate-low-ratio.zip'));
    await _writeArchive(deflatePackage, [
      _ArchiveEntry('items.json', utf8.encode('[]')),
    ], compress: true);

    await _expectCode(
      service.validateBackup(deflatePackage),
      BackupRestoreErrorCode.invalidArchive,
    );
  });

  final imageLimitCases = <String, BackupRestoreLimits>{
    'maxImageDimension': const BackupRestoreLimits(
      maxImageDimension: 100,
      maxImagePixels: 1024 * 1024,
    ),
    'maxImagePixels': const BackupRestoreLimits(
      maxImageDimension: 512,
      maxImagePixels: 4096,
    ),
  };
  for (final limitCase in imageLimitCases.entries) {
    test('STORE 包内低压缩大尺寸图片触发 ${limitCase.key} 门禁', () async {
      final fixture = await _createBackupFixture(
        sourceRoot,
        mediaBytes: _jpeg(
          red: 25,
          green: 95,
          blue: 165,
          width: 128,
          height: 64,
        ),
      );
      final service = _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
        limits: limitCase.value,
      );

      await _expectCode(
        service.validateBackup(fixture.result.file),
        BackupRestoreErrorCode.invalidMedia,
      );
    });
  }

  for (final point in <BackupRestoreFaultPoint>[
    BackupRestoreFaultPoint.afterMediaPublish,
    BackupRestoreFaultPoint.beforeCatalogCommit,
  ]) {
    test('${point.name} 写入中断会回滚新媒体并保留旧目录与旧媒体', () async {
      final fixture = await _createBackupFixture(sourceRoot);
      final preserved = await _preservedTarget(targetRoot);
      final service = _service(
        targetRoot,
        preserved.repository,
        faultInjector: (actualPoint) {
          if (actualPoint == point) {
            throw const FileSystemException('合成写入中断');
          }
        },
      );

      await _expectCode(
        service.restoreBackup(fixture.result.file),
        BackupRestoreErrorCode.writeFailed,
      );

      expect(
        _snapshotSignature(preserved.repository.snapshot),
        preserved.snapshotSignature,
      );
      expect(await _imageTree(targetRoot), preserved.imageTree);
    });
  }

  test('目录首次提交失败后第二次保存旧快照可完成回滚', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final preserved = await _preservedTarget(targetRoot);
    preserved.repository.failNextSaves = 1;
    final service = _service(targetRoot, preserved.repository);

    await _expectCode(
      service.restoreBackup(fixture.result.file),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(preserved.repository.saveCalls, 2);
    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    expect(await _imageTree(targetRoot), preserved.imageTree);
  });

  test('repository 先持久化 NEW 再抛错时可回写 OLD 并删除新媒体与 journal', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final preserved = await _preservedTarget(targetRoot);
    preserved.repository.persistThenFailNextSave = true;

    await _expectCode(
      _service(
        targetRoot,
        preserved.repository,
      ).restoreBackup(fixture.result.file),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(preserved.repository.saveCalls, 2);
    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    expect(await _imageTree(targetRoot), preserved.imageTree);
    expect(
      await File(
        _join(targetRoot.path, '.wujian-restore-journal.json'),
      ).exists(),
      isFalse,
    );
  });

  test('repository 持久化 NEW 后抛错且 OLD 回写失败时保留 journal 与 NEW 媒体', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final preserved = await _preservedTarget(targetRoot);
    preserved.repository.persistThenFailNextSave = true;
    preserved.repository.failNextSavesAfterPersistFailure = 1;

    await _expectCode(
      _service(
        targetRoot,
        preserved.repository,
      ).restoreBackup(fixture.result.file),
      BackupRestoreErrorCode.rollbackFailed,
    );

    expect(preserved.repository.saveCalls, 2);
    expect(preserved.repository.snapshot.items.map((item) => item.id), [
      'catalog-item',
    ]);
    expect(preserved.repository.snapshot.pendingItems.map((item) => item.id), [
      'pending-item',
    ]);
    final expectedNewName = 'backup-${sha256.convert(fixture.mediaBytes)}.jpg';
    final imageTree = await _imageTree(targetRoot);
    expect(imageTree, contains('preserved-old.jpg'));
    expect(
      imageTree[expectedNewName],
      sha256.convert(fixture.mediaBytes).toString(),
    );
    expect(
      await File(
        _join(targetRoot.path, '.wujian-restore-journal.json'),
      ).exists(),
      isTrue,
    );
    expect(
      imageTree.keys.where((name) => name.startsWith('.restore-')),
      isEmpty,
    );
  });

  test('BackupFileSystem 部分写后抛错时清理 partial 并保持 OLD 完整', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final preserved = await _preservedTarget(targetRoot);
    final fileSystem = _PartialWriteThenThrowBackupFileSystem();

    await _expectCode(
      _service(
        targetRoot,
        preserved.repository,
        fileSystem: fileSystem,
      ).restoreBackup(fixture.result.file),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(fileSystem.partialWriteAttempted, isTrue);
    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    expect(await _imageTree(targetRoot), preserved.imageTree);
    expect(
      await File(
        _join(targetRoot.path, '.wujian-restore-journal.json'),
      ).exists(),
      isFalse,
    );
    final images = Directory(_join(targetRoot.path, 'images'));
    final residue = await images
        .list(followLinks: false)
        .where(
          (entity) => entity.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('.restore-'),
        )
        .toList();
    expect(residue, isEmpty);
  });

  test('BackupFileSystem 静默写入同长坏字节时校验失败且保持 OLD 完整', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final preserved = await _preservedTarget(targetRoot);
    final fileSystem = _SilentCorruptCopyBackupFileSystem();

    await _expectCode(
      _service(
        targetRoot,
        preserved.repository,
        fileSystem: fileSystem,
      ).restoreBackup(fixture.result.file),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(fileSystem.corruptCopyAttempted, isTrue);
    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    expect(await _imageTree(targetRoot), preserved.imageTree);
    expect(
      await File(
        _join(targetRoot.path, '.wujian-restore-journal.json'),
      ).exists(),
      isFalse,
    );
  });

  test('没有 journal 时 validate 不删除 catalog 正在引用的 restore 临时名文件', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final canonicalRoot = Directory(await targetRoot.resolveSymbolicLinks());
    final images = Directory(_join(canonicalRoot.path, 'images'));
    await images.create(recursive: true);
    final protectedBytes = _jpeg(red: 55, green: 125, blue: 195);
    final protectedTemporary = File(
      _join(images.path, '.restore-1700000000002-0.tmp'),
    );
    await protectedTemporary.writeAsBytes(protectedBytes, flush: true);
    final repository = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(
            id: 'active-restore-name',
            name: '合法引用临时名',
            imagePath: protectedTemporary.path,
          ),
        ],
        pendingItems: const [],
      ),
    );
    final beforeCatalog = _snapshotSignature(repository.snapshot);

    final inspection = await _service(
      targetRoot,
      repository,
    ).validateBackup(fixture.result.file);

    expect(inspection.mediaCount, 1);
    expect(await protectedTemporary.readAsBytes(), protectedBytes);
    expect(_snapshotSignature(repository.snapshot), beforeCatalog);
    expect(
      await File(
        _join(canonicalRoot.path, '.wujian-restore-journal.json'),
      ).exists(),
      isFalse,
    );
  });

  test('重启恢复发现 current=OLD 时删除计划新媒体、临时文件与 journal', () async {
    final canonicalRoot = Directory(await targetRoot.resolveSymbolicLinks());
    final images = Directory(_join(canonicalRoot.path, 'images'));
    await images.create(recursive: true);
    final oldBytes = _jpeg(red: 20, green: 90, blue: 150);
    final oldMedia = File(_join(images.path, 'old-referenced.jpg'));
    await oldMedia.writeAsBytes(oldBytes, flush: true);
    final previous = CatalogSnapshot(
      items: [_item(id: 'old-active', name: '中断前目录', imagePath: oldMedia.path)],
      pendingItems: const [],
    );

    final newBytes = _jpeg(red: 150, green: 80, blue: 30);
    final newHash = sha256.convert(newBytes).toString();
    final newName = 'backup-$newHash.jpg';
    final newMedia = File(_join(images.path, newName));
    await newMedia.writeAsBytes(newBytes, flush: true);
    final next = CatalogSnapshot(
      items: [
        _item(
          id: 'new-not-committed',
          name: '尚未提交目录',
          imagePath: newMedia.path,
        ),
      ],
      pendingItems: const [],
    );
    final interruptedTemporary = File(
      _join(images.path, '.restore-1700000000000-0.tmp'),
    );
    await interruptedTemporary.writeAsBytes(const [1, 2, 3], flush: true);
    final journal = await _writeSyntheticRestoreJournal(
      canonicalRoot,
      previous: previous,
      next: next,
      createdMediaNames: [newName],
    );
    final repository = _MemoryCatalogRepository(previous);

    await _service(targetRoot, repository).recoverInterruptedRestore();

    expect(
      _snapshotSignature(repository.snapshot),
      _snapshotSignature(previous),
    );
    expect(await oldMedia.readAsBytes(), oldBytes);
    expect(await newMedia.exists(), isFalse);
    expect(await interruptedTemporary.exists(), isFalse);
    expect(await journal.exists(), isFalse);
    expect(await _imageTree(targetRoot), {
      'old-referenced.jpg': sha256.convert(oldBytes).toString(),
    });
  });

  test('current=OLD 时 journal 计划媒体仍被 catalog 引用会 BLOCK 并保留现场', () async {
    final canonicalRoot = Directory(await targetRoot.resolveSymbolicLinks());
    final images = Directory(_join(canonicalRoot.path, 'images'));
    await images.create(recursive: true);
    final referencedBytes = _jpeg(red: 45, green: 115, blue: 185);
    final referencedHash = sha256.convert(referencedBytes).toString();
    final referencedName = 'backup-$referencedHash.jpg';
    final referencedMedia = File(_join(images.path, referencedName));
    await referencedMedia.writeAsBytes(referencedBytes, flush: true);
    final previous = CatalogSnapshot(
      items: [
        _item(
          id: 'old-still-references-planned',
          name: '仍引用计划媒体',
          imagePath: referencedMedia.path,
        ),
      ],
      pendingItems: const [],
    );
    final next = CatalogSnapshot(
      items: [_item(id: 'different-next', name: '不同下一目录')],
      pendingItems: const [],
    );
    final journal = await _writeSyntheticRestoreJournal(
      canonicalRoot,
      previous: previous,
      next: next,
      createdMediaNames: [referencedName],
    );
    final repository = _MemoryCatalogRepository(previous);

    await _expectCode(
      _service(targetRoot, repository).recoverInterruptedRestore(),
      BackupRestoreErrorCode.rollbackFailed,
    );

    expect(await referencedMedia.readAsBytes(), referencedBytes);
    expect(await journal.exists(), isTrue);
    expect(
      _snapshotSignature(repository.snapshot),
      _snapshotSignature(previous),
    );
  });

  test('current=OLD 时未引用计划媒体实际 SHA 与文件名不符会 BLOCK 并保留现场', () async {
    final canonicalRoot = Directory(await targetRoot.resolveSymbolicLinks());
    final images = Directory(_join(canonicalRoot.path, 'images'));
    await images.create(recursive: true);
    final declaredBytes = _jpeg(red: 20, green: 80, blue: 140);
    final mismatchedBytes = _jpeg(red: 140, green: 80, blue: 20);
    final declaredHash = sha256.convert(declaredBytes).toString();
    final mismatchedName = 'backup-$declaredHash.jpg';
    final mismatchedMedia = File(_join(images.path, mismatchedName));
    await mismatchedMedia.writeAsBytes(mismatchedBytes, flush: true);
    const previous = CatalogSnapshot.empty();
    final next = CatalogSnapshot(
      items: [_item(id: 'different-next-no-media', name: '不同无媒体目录')],
      pendingItems: const [],
    );
    final journal = await _writeSyntheticRestoreJournal(
      canonicalRoot,
      previous: previous,
      next: next,
      createdMediaNames: [mismatchedName],
    );
    final repository = _MemoryCatalogRepository(previous);

    await _expectCode(
      _service(targetRoot, repository).recoverInterruptedRestore(),
      BackupRestoreErrorCode.rollbackFailed,
    );

    expect(await mismatchedMedia.readAsBytes(), mismatchedBytes);
    expect(await journal.exists(), isTrue);
    expect(
      _snapshotSignature(repository.snapshot),
      _snapshotSignature(previous),
    );
  });

  test('重启恢复发现 current=NEW 时保留新引用媒体并清理旧孤儿与 journal', () async {
    final canonicalRoot = Directory(await targetRoot.resolveSymbolicLinks());
    final images = Directory(_join(canonicalRoot.path, 'images'));
    await images.create(recursive: true);
    final oldBytes = _jpeg(red: 35, green: 45, blue: 55);
    final oldOrphan = File(_join(images.path, 'old-orphan.jpg'));
    await oldOrphan.writeAsBytes(oldBytes, flush: true);
    final previous = CatalogSnapshot(
      items: [
        _item(id: 'old-replaced', name: '已被替换目录', imagePath: oldOrphan.path),
      ],
      pendingItems: const [],
    );

    final newBytes = _jpeg(red: 75, green: 135, blue: 195);
    final newHash = sha256.convert(newBytes).toString();
    final newName = 'backup-$newHash.jpg';
    final newMedia = File(_join(images.path, newName));
    await newMedia.writeAsBytes(newBytes, flush: true);
    final next = CatalogSnapshot(
      items: [_item(id: 'new-active', name: '已提交目录', imagePath: newMedia.path)],
      pendingItems: const [],
    );
    final interruptedTemporary = File(
      _join(images.path, '.restore-1700000000001-0.tmp'),
    );
    await interruptedTemporary.writeAsBytes(const [4, 5, 6], flush: true);
    final journal = await _writeSyntheticRestoreJournal(
      canonicalRoot,
      previous: previous,
      next: next,
      createdMediaNames: [newName],
    );
    final repository = _MemoryCatalogRepository(next);

    await _service(targetRoot, repository).recoverInterruptedRestore();

    expect(_snapshotSignature(repository.snapshot), _snapshotSignature(next));
    expect(await newMedia.readAsBytes(), newBytes);
    expect(await oldOrphan.exists(), isFalse);
    expect(await interruptedTemporary.exists(), isFalse);
    expect(await journal.exists(), isFalse);
    expect(await _imageTree(targetRoot), {
      newName: sha256.convert(newBytes).toString(),
    });
  });

  test('current=NEW 重启恢复把相对媒体引用按 documents root 解析并避免误删', () async {
    final canonicalRoot = Directory(await targetRoot.resolveSymbolicLinks());
    final images = Directory(_join(canonicalRoot.path, 'images'));
    await images.create(recursive: true);
    final activeBytes = _jpeg(red: 85, green: 145, blue: 205);
    final activeHash = sha256.convert(activeBytes).toString();
    final activeName = 'backup-$activeHash.jpg';
    final activeMedia = File(_join(images.path, activeName));
    await activeMedia.writeAsBytes(activeBytes, flush: true);
    final orphan = File(_join(images.path, 'relative-recovery-orphan.jpg'));
    await orphan.writeAsBytes(
      _jpeg(red: 205, green: 145, blue: 85),
      flush: true,
    );
    const previous = CatalogSnapshot.empty();
    final next = CatalogSnapshot(
      items: [
        _item(
          id: 'relative-new-active',
          name: '相对引用已提交目录',
          imagePath: 'images/$activeName',
        ),
      ],
      pendingItems: const [],
    );
    final journal = await _writeSyntheticRestoreJournal(
      canonicalRoot,
      previous: previous,
      next: next,
      createdMediaNames: [activeName],
    );
    final repository = _MemoryCatalogRepository(next);

    await _service(targetRoot, repository).recoverInterruptedRestore();

    expect(await activeMedia.readAsBytes(), activeBytes);
    expect(await orphan.exists(), isFalse);
    expect(await journal.exists(), isFalse);
    expect(_snapshotSignature(repository.snapshot), _snapshotSignature(next));
  });

  test('previous 等于 next 且计划媒体缺失时清理已发布部分并回到可重试态', () async {
    final canonicalRoot = Directory(await targetRoot.resolveSymbolicLinks());
    final images = Directory(_join(canonicalRoot.path, 'images'));
    await images.create(recursive: true);
    const current = CatalogSnapshot.empty();
    final publishedBytes = _jpeg(red: 95, green: 145, blue: 195);
    final publishedHash = sha256.convert(publishedBytes).toString();
    final publishedName = 'backup-$publishedHash.jpg';
    final publishedMedia = File(_join(images.path, publishedName));
    await publishedMedia.writeAsBytes(publishedBytes, flush: true);
    final missingBytes = _jpeg(red: 15, green: 65, blue: 115);
    final missingName = 'backup-${sha256.convert(missingBytes)}.jpg';
    final journal = await _writeSyntheticRestoreJournal(
      canonicalRoot,
      previous: current,
      next: current,
      createdMediaNames: [publishedName, missingName],
    );
    final interruptedTemporary = File(
      _join(images.path, '.restore-1700000000003-0.tmp'),
    );
    await interruptedTemporary.writeAsBytes(const [7, 8, 9], flush: true);
    final repository = _MemoryCatalogRepository(current);

    await _service(targetRoot, repository).recoverInterruptedRestore();

    expect(
      _snapshotSignature(repository.snapshot),
      _snapshotSignature(current),
    );
    expect(await publishedMedia.exists(), isFalse);
    expect(await File(_join(images.path, missingName)).exists(), isFalse);
    expect(await interruptedTemporary.exists(), isFalse);
    expect(await journal.exists(), isFalse);
    expect(await _imageTree(targetRoot), isEmpty);
  });

  test('previous 等于 next 且部分缺失时不删除当前 catalog 正引用的计划媒体', () async {
    final canonicalRoot = Directory(await targetRoot.resolveSymbolicLinks());
    final images = Directory(_join(canonicalRoot.path, 'images'));
    await images.create(recursive: true);
    final referencedBytes = _jpeg(red: 105, green: 155, blue: 205);
    final referencedName =
        'backup-${sha256.convert(referencedBytes).toString()}.jpg';
    final referencedMedia = File(_join(images.path, referencedName));
    await referencedMedia.writeAsBytes(referencedBytes, flush: true);
    final missingBytes = _jpeg(red: 25, green: 75, blue: 125);
    final missingName = 'backup-${sha256.convert(missingBytes)}.jpg';
    final current = CatalogSnapshot(
      items: [
        _item(
          id: 'same-hash-current-reference',
          name: '当前目录仍引用计划媒体',
          imagePath: referencedMedia.path,
        ),
      ],
      pendingItems: const [],
    );
    final journal = await _writeSyntheticRestoreJournal(
      canonicalRoot,
      previous: current,
      next: current,
      createdMediaNames: [referencedName, missingName],
    );
    final repository = _MemoryCatalogRepository(current);

    await _expectCode(
      _service(targetRoot, repository).recoverInterruptedRestore(),
      BackupRestoreErrorCode.rollbackFailed,
    );

    expect(await referencedMedia.readAsBytes(), referencedBytes);
    expect(await File(_join(images.path, missingName)).exists(), isFalse);
    expect(await journal.exists(), isTrue);
    expect(
      _snapshotSignature(repository.snapshot),
      _snapshotSignature(current),
    );
  });

  test('空媒体恢复回滚仅 journal 删除失败时保留空 images，解除故障后可收敛 OLD', () async {
    final nextSnapshot = CatalogSnapshot(
      items: [_item(id: 'empty-media-next', name: '无媒体新目录')],
      pendingItems: const [],
    );
    final sourceRepository = _MemoryCatalogRepository(nextSnapshot);
    final package = await _service(
      sourceRoot,
      sourceRepository,
    ).createBackup(baseName: 'empty-media');
    expect(package.inspection.mediaCount, 0);

    final previousSnapshot = CatalogSnapshot(
      items: [_item(id: 'empty-media-old', name: '无媒体旧目录')],
      pendingItems: const [],
    );
    final targetRepository = _MemoryCatalogRepository(previousSnapshot);
    final fileSystem = _FailJournalDeleteBackupFileSystem();
    final service = _service(
      targetRoot,
      targetRepository,
      fileSystem: fileSystem,
      faultInjector: (point) {
        if (point == BackupRestoreFaultPoint.beforeCatalogCommit) {
          throw const FileSystemException('合成空媒体提交中断');
        }
      },
    );

    await _expectCode(
      service.restoreBackup(package.file),
      BackupRestoreErrorCode.rollbackFailed,
    );

    final images = Directory(_join(targetRoot.path, 'images'));
    final journal = File(
      _join(targetRoot.path, '.wujian-restore-journal.json'),
    );
    expect(fileSystem.journalDeleteAttempts, 1);
    expect(await images.exists(), isTrue);
    expect(await images.list(followLinks: false).toList(), isEmpty);
    expect(await journal.exists(), isTrue);
    expect(
      _snapshotSignature(targetRepository.snapshot),
      _snapshotSignature(previousSnapshot),
    );

    fileSystem.failJournalDeletion = false;
    await service.recoverInterruptedRestore();

    expect(await journal.exists(), isFalse);
    expect(await images.exists(), isTrue);
    expect(await images.list(followLinks: false).toList(), isEmpty);
    expect(
      _snapshotSignature(targetRepository.snapshot),
      _snapshotSignature(previousSnapshot),
    );
  });

  test('导出发布前写入中断不留下最终包、partial 或 create 工作区', () async {
    final images = Directory(_join(sourceRoot.path, 'images'));
    await images.create(recursive: true);
    final sourceBytes = _jpeg(red: 45, green: 105, blue: 165);
    final sourceMedia = File(_join(images.path, 'atomic-source.jpg'));
    await sourceMedia.writeAsBytes(sourceBytes, flush: true);
    final snapshot = CatalogSnapshot(
      items: [
        _item(
          id: 'atomic-source-item',
          name: '原子导出源目录',
          imagePath: sourceMedia.path,
        ),
      ],
      pendingItems: const [],
    );
    final repository = _MemoryCatalogRepository(snapshot);
    final beforeCatalog = _snapshotSignature(repository.snapshot);
    final beforeImages = await _imageTree(sourceRoot);
    final service = _service(
      sourceRoot,
      repository,
      faultInjector: (point) {
        if (point == BackupRestoreFaultPoint.beforeBackupPublish) {
          throw const FileSystemException('合成导出发布中断');
        }
      },
    );

    await _expectCode(
      service.createBackup(baseName: 'atomic-failure'),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(_snapshotSignature(repository.snapshot), beforeCatalog);
    expect(await _imageTree(sourceRoot), beforeImages);
    expect(await sourceMedia.readAsBytes(), sourceBytes);
    final backups = Directory(_join(sourceRoot.path, 'backups'));
    final backupEntities = await backups.exists()
        ? await backups.list(recursive: true, followLinks: false).toList()
        : <FileSystemEntity>[];
    expect(
      backupEntities.whereType<File>().where(
        (file) =>
            file.path.endsWith('.wujian-backup') ||
            file.path.endsWith('.partial'),
      ),
      isEmpty,
    );
    final rootEntities = await sourceRoot.list(followLinks: false).toList();
    expect(
      rootEntities.where(
        (entity) => entity.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('.wujian-create-'),
      ),
      isEmpty,
    );
  });

  test('partial 删除失败时保留 owner，模拟重启后 scavenger 可成对回收', () async {
    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final fileSystem = _FailPartialDeleteOnceBackupFileSystem();
    final service = _service(
      sourceRoot,
      repository,
      fileSystem: fileSystem,
      faultInjector: (point) {
        if (point == BackupRestoreFaultPoint.beforeBackupPublish) {
          throw const FileSystemException('合成 partial 清理前故障');
        }
      },
    );

    await _expectCode(
      service.createBackup(baseName: 'partial-owner-retained'),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(fileSystem.partialDeleteFailures, 1);
    final partial = fileSystem.retainedPartial;
    expect(partial, isNotNull);
    final owner = File('${partial!.path}.owner.json');
    expect(await partial.exists(), isTrue);
    expect(await owner.exists(), isTrue);

    final ownerObject =
        jsonDecode(await owner.readAsString()) as Map<String, dynamic>;
    ownerObject['ownerProcessId'] = pid == 0x7fffffff ? pid - 1 : pid + 1;
    await owner.writeAsString(jsonEncode(ownerObject), flush: true);

    await _service(sourceRoot, repository).recoverInterruptedRestore();

    expect(await partial.exists(), isFalse);
    expect(await owner.exists(), isFalse);
  });

  test('启动 scavenger 只清理带所有权标记的崩溃残留并回收可量化字节', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final abandonedPid = pid == 0x7fffffff ? pid - 1 : pid + 1;
    const abandonedAt = '2026-08-08T00:00:00.000Z';
    final ownedPayloads = <File>[];
    for (final purpose in <String>['create', 'validate', 'restore']) {
      final name = '.wujian-$purpose-1000-${ownedPayloads.length}-0';
      final workspace = Directory(_join(targetRoot.path, name));
      await workspace.create(recursive: true);
      await File(_join(workspace.path, '.wujian-operation.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'schemaVersion': 1,
          'kind': 'wujian-backup-workspace',
          'purpose': purpose,
          'directoryName': name,
          'ownerProcessId': abandonedPid,
          'createdAt': abandonedAt,
        }),
        flush: true,
      );
      final payload = File(_join(workspace.path, 'synthetic-payload.bin'));
      await payload.writeAsBytes(List<int>.filled(4096, 7), flush: true);
      ownedPayloads.add(payload);
    }

    final backups = Directory(_join(targetRoot.path, 'backups'));
    await backups.create(recursive: true);
    const partialName = 'audit-1-2-3.wujian-backup.partial';
    final partial = File(_join(backups.path, partialName));
    await partial.writeAsBytes(List<int>.filled(2048, 9), flush: true);
    final partialOwner = File('${partial.path}.owner.json');
    await partialOwner.writeAsString(
      jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'kind': 'wujian-backup-partial',
        'partialName': partialName,
        'ownerProcessId': abandonedPid,
        'createdAt': abandonedAt,
      }),
      flush: true,
    );

    final journalTemporary = File(
      _join(targetRoot.path, '.wujian-restore-journal.json.tmp-1000-1'),
    );
    await journalTemporary.writeAsString(
      jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'ownerProcessId': abandonedPid,
        'createdAt': abandonedAt,
        'previousCatalogSha256': '0' * 64,
        'nextCatalogSha256': '1' * 64,
        'createdMedia': const <String>[],
      }),
      flush: true,
    );

    final decoy = Directory(_join(targetRoot.path, '.wujian-create-2000-1-0'));
    await decoy.create();
    final decoyPayload = File(_join(decoy.path, 'keep.bin'));
    await decoyPayload.writeAsBytes(const <int>[1, 2, 3], flush: true);

    final reclaimedPayloadBytes =
        ownedPayloads.fold<int>(0, (sum, file) => sum + file.lengthSync()) +
        partial.lengthSync() +
        journalTemporary.lengthSync();
    expect(reclaimedPayloadBytes, greaterThanOrEqualTo(14 * 1024));

    await _service(
      targetRoot,
      _MemoryCatalogRepository(const CatalogSnapshot.empty()),
    ).validateBackup(fixture.result.file);

    for (final payload in ownedPayloads) {
      expect(await payload.parent.exists(), isFalse);
    }
    expect(await partial.exists(), isFalse);
    expect(await partialOwner.exists(), isFalse);
    expect(await journalTemporary.exists(), isFalse);
    expect(await decoyPayload.readAsBytes(), const <int>[1, 2, 3]);
  });

  test('fresh same-PID active workspace 作为 lease 阻止同进程另一 isolate 进入', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    const name = '.wujian-restore-3000-1-0';
    final active = Directory(_join(targetRoot.path, name));
    await active.create(recursive: true);
    await File(_join(active.path, '.wujian-operation.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'kind': 'wujian-backup-workspace',
        'purpose': 'restore',
        'directoryName': name,
        'ownerProcessId': pid,
        'createdAt': '2026-08-09T12:00:00.000Z',
      }),
      flush: true,
    );
    final payload = File(_join(active.path, 'keep.bin'));
    await payload.writeAsBytes(const <int>[4, 5, 6], flush: true);

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(fixture.result.file),
      BackupRestoreErrorCode.busy,
    );

    expect(await payload.readAsBytes(), const <int>[4, 5, 6]);
    expect(
      (await targetRoot.list(followLinks: false).toList())
          .where((entry) => _basenameForTest(entry.path).startsWith('.wujian-'))
          .whereType<Directory>(),
      hasLength(1),
    );
  });

  test('正常 finally 删除 workspace 失败时 cleanup marker 允许同 PID 下次立即回收', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final fileSystem = _FailWorkspaceDeleteOnceBackupFileSystem();
    final service = _service(
      targetRoot,
      _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      fileSystem: fileSystem,
    );

    expect(
      await service.validateBackup(fixture.result.file),
      isA<BackupPackageInspection>(),
    );
    expect(fileSystem.workspaceDeleteFailures, 1);
    final retained = fileSystem.retainedWorkspace;
    expect(retained, isNotNull);
    expect(await retained!.exists(), isTrue);
    expect(
      await File(_join(retained.path, '.wujian-cleanup-pending.json')).exists(),
      isTrue,
    );

    expect(
      await service.validateBackup(fixture.result.file),
      isA<BackupPackageInspection>(),
    );

    expect(await retained.exists(), isFalse);
    expect(
      (await targetRoot.list(followLinks: false).toList())
          .whereType<Directory>()
          .where(
            (entry) =>
                _basenameForTest(entry.path).startsWith('.wujian-validate-'),
          ),
      isEmpty,
    );
  });

  test('启动 scavenger 遇到所有权工作区内软链接时 BLOCK 且不删除目标', () async {
    if (Platform.isWindows) {
      return;
    }
    final fixture = await _createBackupFixture(sourceRoot);
    final sentinel = File(_join(sandbox.path, 'scavenger-sentinel.bin'));
    await sentinel.writeAsBytes(const <int>[9, 8, 7], flush: true);
    const name = '.wujian-restore-4000-1-0';
    final workspace = Directory(_join(targetRoot.path, name));
    await workspace.create();
    await File(_join(workspace.path, '.wujian-operation.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'kind': 'wujian-backup-workspace',
        'purpose': 'restore',
        'directoryName': name,
        'ownerProcessId': pid + 1,
        'createdAt': '2026-08-08T00:00:00.000Z',
      }),
      flush: true,
    );
    await Link(_join(workspace.path, 'unsafe-link')).create(sentinel.path);

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(fixture.result.file),
      BackupRestoreErrorCode.rollbackFailed,
    );

    expect(await workspace.exists(), isTrue);
    expect(await sentinel.readAsBytes(), const <int>[9, 8, 7]);
  });

  test('预计 STORE 包超过 maxArchiveBytes 时在写 partial 前失败并清理工作区', () async {
    final images = Directory(_join(sourceRoot.path, 'images'));
    await images.create(recursive: true);
    final media = File(_join(images.path, 'archive-limit.jpg'));
    final bytes = _jpeg(red: 55, green: 115, blue: 175);
    await media.writeAsBytes(bytes, flush: true);
    final repository = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(id: 'archive-limit', name: '预估上限', imagePath: media.path),
        ],
        pendingItems: const <ItemRecord>[],
      ),
    );

    await _expectCode(
      _service(
        sourceRoot,
        repository,
        limits: const BackupRestoreLimits(maxArchiveBytes: 512),
      ).createBackup(baseName: 'too-large'),
      BackupRestoreErrorCode.expandedSizeExceeded,
    );

    final backups = Directory(_join(sourceRoot.path, 'backups'));
    final backupEntries = await backups.exists()
        ? await backups.list(recursive: true, followLinks: false).toList()
        : const <FileSystemEntity>[];
    expect(backupEntries, isEmpty);
    expect(
      (await sourceRoot.list(followLinks: false).toList()).where(
        (entity) => _basenameForTest(entity.path).startsWith('.wujian-create-'),
      ),
      isEmpty,
    );
    expect(await media.readAsBytes(), bytes);
  });

  test('本地备份总字节精确达到上限可发布，下一包在写 partial 前拒绝', () async {
    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final first = await _service(
      sourceRoot,
      repository,
    ).createBackup(baseName: 'retention-first');
    final limited = _service(
      sourceRoot,
      repository,
      limits: BackupRestoreLimits(
        maxStoredBackupBytes: first.packageBytes * 2,
        maxStoredBackupFiles: 8,
      ),
    );

    final second = await limited.createBackup(baseName: 'retention-second');
    expect(first.packageBytes + second.packageBytes, first.packageBytes * 2);

    await _expectCode(
      limited.createBackup(baseName: 'retention-third'),
      BackupRestoreErrorCode.storageLimitExceeded,
    );
    final entries = await Directory(
      _join(sourceRoot.path, 'backups'),
    ).list(followLinks: false).toList();
    expect(
      entries.where((entry) => entry.path.endsWith('.wujian-backup')),
      hasLength(2),
    );
    expect(
      entries.where(
        (entry) =>
            entry.path.endsWith('.partial') ||
            entry.path.endsWith('.partial.owner.json'),
      ),
      isEmpty,
    );
  });

  test('备份目录内未知普通文件计入字节门禁且不会被删除', () async {
    final backups = Directory(_join(sourceRoot.path, 'backups'));
    await backups.create(recursive: true);
    final unknown = File(_join(backups.path, 'retained-sidecar.bin'));
    final unknownBytes = List<int>.generate(64, (index) => index);
    await unknown.writeAsBytes(unknownBytes, flush: true);

    await _expectCode(
      _service(
        sourceRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
        limits: const BackupRestoreLimits(maxStoredBackupBytes: 64),
      ).createBackup(baseName: 'retention-unknown'),
      BackupRestoreErrorCode.storageLimitExceeded,
    );

    expect(await unknown.readAsBytes(), unknownBytes);
    expect(
      (await backups.list(followLinks: false).toList()).where(
        (entry) =>
            entry.path.endsWith('.partial') ||
            entry.path.endsWith('.partial.owner.json'),
      ),
      isEmpty,
    );
  });

  test('最终备份数量达到上限后在准备工作区前拒绝下一包', () async {
    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final service = _service(
      sourceRoot,
      repository,
      limits: const BackupRestoreLimits(maxStoredBackupFiles: 1),
    );
    await service.createBackup(baseName: 'count-limit-first');

    await _expectCode(
      service.createBackup(baseName: 'count-limit-second'),
      BackupRestoreErrorCode.storageLimitExceeded,
    );

    final rootEntries = await sourceRoot.list(followLinks: false).toList();
    expect(
      rootEntries.where(
        (entry) => _basenameForTest(entry.path).startsWith('.wujian-create-'),
      ),
      isEmpty,
    );
  });

  test('备份包后缀的软链接触发门禁且不访问或删除链接目标', () async {
    final backups = Directory(_join(sourceRoot.path, 'backups'));
    await backups.create(recursive: true);
    final sentinel = File(_join(sandbox.path, 'retention-link-sentinel.bin'));
    final sentinelBytes = const <int>[4, 3, 2, 1];
    await sentinel.writeAsBytes(sentinelBytes, flush: true);
    final packageLink = Link(_join(backups.path, 'external.wujian-backup'));
    await packageLink.create(sentinel.path);

    await _expectCode(
      _service(
        sourceRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).createBackup(baseName: 'retention-link'),
      BackupRestoreErrorCode.symbolicLink,
    );

    expect(
      await FileSystemEntity.type(packageLink.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await sentinel.readAsBytes(), sentinelBytes);
  });

  test('进程互斥文件为软链接时拒绝操作且不访问链接目标', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    await targetRoot.create(recursive: true);
    final sentinel = File(_join(sandbox.path, 'operation-lock-sentinel.bin'));
    final sentinelBytes = const <int>[8, 6, 4, 2];
    await sentinel.writeAsBytes(sentinelBytes, flush: true);
    final lockLink = Link(
      _join(targetRoot.path, '.wujian-backup-operation.lock'),
    );
    await lockLink.create(sentinel.path);

    await _expectCode(
      _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(fixture.result.file),
      BackupRestoreErrorCode.symbolicLink,
    );

    expect(
      await FileSystemEntity.type(lockLink.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await sentinel.readAsBytes(), sentinelBytes);
  });

  test('导出 final rename 已落盘后报错会校验并收敛为成功', () async {
    final images = Directory(_join(sourceRoot.path, 'images'));
    await images.create(recursive: true);
    final media = File(_join(images.path, 'rename-source.jpg'));
    await media.writeAsBytes(_jpeg(red: 25, green: 95, blue: 165), flush: true);
    final fileSystem = _PersistRenameThenThrowBackupFileSystem(
      throwOnBackupPublish: true,
    );
    final result = await _service(
      sourceRoot,
      _MemoryCatalogRepository(
        CatalogSnapshot(
          items: [
            _item(
              id: 'rename-export',
              name: '导出 rename 不确定态',
              imagePath: media.path,
            ),
          ],
          pendingItems: const <ItemRecord>[],
        ),
      ),
      fileSystem: fileSystem,
    ).createBackup(baseName: 'rename-committed');

    expect(fileSystem.backupPublishThrows, 1);
    expect(await result.file.exists(), isTrue);
    expect(await result.file.length(), result.packageBytes);
    expect(
      await _service(
        targetRoot,
        _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      ).validateBackup(result.file),
      isA<BackupPackageInspection>(),
    );
  });

  test('导出 rename 前出现同内容竞争目标时不接管目标且清理本次 partial', () async {
    final images = Directory(_join(sourceRoot.path, 'images'));
    await images.create(recursive: true);
    final media = File(_join(images.path, 'rename-race-source.jpg'));
    await media.writeAsBytes(_jpeg(red: 45, green: 105, blue: 165));
    final fileSystem = _PersistRenameThenThrowBackupFileSystem(
      createExactTargetBeforeBackupPublish: true,
    );

    await _expectCode(
      _service(
        sourceRoot,
        _MemoryCatalogRepository(
          CatalogSnapshot(
            items: [
              _item(
                id: 'rename-export-race',
                name: '导出 rename 竞争',
                imagePath: media.path,
              ),
            ],
            pendingItems: const <ItemRecord>[],
          ),
        ),
        fileSystem: fileSystem,
      ).createBackup(baseName: 'rename-race'),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(fileSystem.backupPublishPreRenameThrows, 1);
    final competingTarget = fileSystem.competingBackupTarget;
    expect(competingTarget, isNotNull);
    expect(await competingTarget!.exists(), isTrue);
    final backups = await competingTarget.parent
        .list(followLinks: false)
        .toList();
    expect(
      backups.where(
        (entity) =>
            entity.path.endsWith('.partial') ||
            entity.path.endsWith('.partial.owner.json'),
      ),
      isEmpty,
    );
  });

  test('恢复媒体 rename 已落盘后报错会删除目标并完整回滚 OLD', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final preserved = await _preservedTarget(targetRoot);
    final fileSystem = _PersistRenameThenThrowBackupFileSystem(
      throwOnRestoreMediaPublish: true,
    );

    await _expectCode(
      _service(
        targetRoot,
        preserved.repository,
        fileSystem: fileSystem,
      ).restoreBackup(fixture.result.file),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(fileSystem.restoreMediaPublishThrows, 1);
    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    expect(await _imageTree(targetRoot), preserved.imageTree);
    expect(
      await File(
        _join(targetRoot.path, '.wujian-restore-journal.json'),
      ).exists(),
      isFalse,
    );
  });

  test('恢复 rename 前出现同内容竞争目标时回滚不删除该目标', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final preserved = await _preservedTarget(targetRoot);
    final fileSystem = _PersistRenameThenThrowBackupFileSystem(
      createExactTargetBeforeRestoreMediaPublish: true,
    );

    await _expectCode(
      _service(
        targetRoot,
        preserved.repository,
        fileSystem: fileSystem,
      ).restoreBackup(fixture.result.file),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(fileSystem.restoreMediaPreRenameThrows, 1);
    expect(
      _snapshotSignature(preserved.repository.snapshot),
      preserved.snapshotSignature,
    );
    final competingTarget = fileSystem.competingMediaTarget;
    expect(competingTarget, isNotNull);
    expect(await competingTarget!.readAsBytes(), fixture.mediaBytes);
    for (final entry in preserved.imageTree.entries) {
      expect((await _imageTree(targetRoot))[entry.key], entry.value);
    }
    expect(
      await File(
        _join(targetRoot.path, '.wujian-restore-journal.json'),
      ).exists(),
      isFalse,
    );
  });

  test('journal rename 已落盘后报错仍可被识别并在后续故障中完整回滚', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final fileSystem = _PersistRenameThenThrowBackupFileSystem(
      throwOnJournalPublish: true,
    );

    await _expectCode(
      _service(
        targetRoot,
        repository,
        fileSystem: fileSystem,
        faultInjector: (point) {
          if (point == BackupRestoreFaultPoint.beforeMediaPublish) {
            throw const FileSystemException('合成 journal 发布后故障');
          }
        },
      ).restoreBackup(fixture.result.file),
      BackupRestoreErrorCode.writeFailed,
    );

    expect(fileSystem.journalPublishThrows, 1);
    expect(repository.snapshot.items, isEmpty);
    expect(
      await File(
        _join(targetRoot.path, '.wujian-restore-journal.json'),
      ).exists(),
      isFalse,
    );
    expect(await Directory(_join(targetRoot.path, 'images')).exists(), isFalse);
    expect(
      await _service(
        targetRoot,
        repository,
      ).validateBackup(fixture.result.file),
      isA<BackupPackageInspection>(),
    );
  });

  test('替换恢复提交后清理不再引用的旧媒体与孤儿文件', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final images = Directory(_join(targetRoot.path, 'images'));
    await images.create(recursive: true);
    final oldReferenced = File(_join(images.path, 'old-referenced.jpg'));
    final orphan = File(_join(images.path, 'orphan.jpg'));
    await oldReferenced.writeAsBytes(_jpeg(red: 20, green: 40, blue: 60));
    await orphan.writeAsBytes(_jpeg(red: 80, green: 100, blue: 120));
    final repository = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(id: 'old-item', name: '将被替换', imagePath: oldReferenced.path),
        ],
        pendingItems: const [],
      ),
    );

    final restored = await _service(
      targetRoot,
      repository,
    ).restoreBackup(fixture.result.file);
    final metrics = await _imageMetrics(targetRoot);

    expect(restored.createdMediaCount, 1);
    expect(restored.deletedOrphanCount, 2);
    expect(restored.retainedOrphanCount, 0);
    expect(await oldReferenced.exists(), isFalse);
    expect(await orphan.exists(), isFalse);
    expect(metrics.fileCount, 1);
    expect(metrics.totalBytes, fixture.mediaBytes.length);
  });

  test('media transaction 持久化后提交 catalog 前 restore 立即 busy 且不清理新媒体', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final temporary = Directory(_join(sandbox.path, 'media-transaction-temp'));
    await temporary.create(recursive: true);
    final capture = File(_join(temporary.path, 'transaction-capture.jpg'));
    await capture.writeAsBytes(
      _jpeg(red: 105, green: 155, blue: 205),
      flush: true,
    );
    final media = MediaStorageService(
      documentsDirectoryProvider: () async => targetRoot,
      temporaryDirectoryProvider: () async => temporary,
      timestampProvider: () => DateTime.utc(2026, 8, 10, 9),
    );
    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final service = _service(targetRoot, repository);
    final persisted = Completer<File>();
    final releaseCatalogCommit = Completer<void>();
    final transaction = media.runStorageTransaction(() async {
      final stored = await media.persistImage(
        capture,
        deleteTemporarySource: false,
      );
      persisted.complete(stored);
      await releaseCatalogCommit.future;
      await repository.saveCatalog(
        CatalogSnapshot(
          items: [
            _item(
              id: 'transaction-persisted-item',
              name: '事务内已持久化媒体',
              imagePath: stored.path,
            ),
          ],
          pendingItems: const [],
        ),
      );
    });
    final stored = await persisted.future.timeout(const Duration(seconds: 10));

    try {
      await _expectCode(
        service
            .restoreBackup(fixture.result.file, mode: BackupRestoreMode.merge)
            .timeout(const Duration(seconds: 1)),
        BackupRestoreErrorCode.busy,
      );
      expect(await stored.exists(), isTrue);
      expect(repository.saveCalls, 0);
    } finally {
      if (!releaseCatalogCommit.isCompleted) {
        releaseCatalogCommit.complete();
      }
      await transaction.timeout(const Duration(seconds: 10));
    }

    final restored = await service.restoreBackup(
      fixture.result.file,
      mode: BackupRestoreMode.merge,
    );
    expect(
      restored.snapshot.items.map((item) => item.id),
      contains('transaction-persisted-item'),
    );
    expect(await stored.exists(), isTrue);
  });

  test('restore exclusive 窗口内 media optimize 立即 busy 且不会排队删除旧引用媒体', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final images = Directory(_join(targetRoot.path, 'images'));
    await images.create(recursive: true);
    final existingBytes = _jpeg(red: 195, green: 125, blue: 55);
    final existingMedia = File(_join(images.path, 'existing-active.jpg'));
    await existingMedia.writeAsBytes(existingBytes, flush: true);
    final repository = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(
            id: 'exclusive-existing-item',
            name: '互斥前旧引用',
            imagePath: existingMedia.path,
          ),
        ],
        pendingItems: const [],
      ),
    );
    final temporary = Directory(_join(sandbox.path, 'exclusive-media-temp'));
    await temporary.create(recursive: true);
    final media = MediaStorageService(
      documentsDirectoryProvider: () async => targetRoot,
      temporaryDirectoryProvider: () async => temporary,
      timestampProvider: () => DateTime.utc(2026, 8, 10, 10),
    );
    final restoreEntered = Completer<void>();
    final releaseRestore = Completer<void>();
    final service = _service(
      targetRoot,
      repository,
      faultInjector: (point) async {
        if (point == BackupRestoreFaultPoint.afterRestoreValidation) {
          if (!restoreEntered.isCompleted) {
            restoreEntered.complete();
          }
          await releaseRestore.future;
        }
      },
    );
    final restore = service.restoreBackup(
      fixture.result.file,
      mode: BackupRestoreMode.merge,
    );
    await restoreEntered.future.timeout(const Duration(seconds: 10));

    try {
      await expectLater(
        media
            .optimizeStorage(referencedImagePaths: const <String>[])
            .timeout(const Duration(seconds: 1)),
        throwsA(isA<StorageMutationBusyException>()),
      );
      expect(await existingMedia.readAsBytes(), existingBytes);
    } finally {
      if (!releaseRestore.isCompleted) {
        releaseRestore.complete();
      }
    }
    final restored = await restore.timeout(const Duration(seconds: 10));

    expect(
      restored.snapshot.items.map((item) => item.id),
      contains('exclusive-existing-item'),
    );
    expect(await existingMedia.readAsBytes(), existingBytes);
  });

  test('同一数据根跨 service 实例互斥，释放后首个恢复正常完成', () async {
    final fixture = await _createBackupFixture(sourceRoot);
    final entered = Completer<void>();
    final release = Completer<void>();
    final repository = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final firstService = _service(
      targetRoot,
      repository,
      faultInjector: (point) async {
        if (point == BackupRestoreFaultPoint.afterRestoreValidation) {
          if (!entered.isCompleted) {
            entered.complete();
          }
          await release.future;
        }
      },
    );
    final secondService = _service(targetRoot, repository);

    final firstRestore = firstService.restoreBackup(fixture.result.file);
    await entered.future.timeout(const Duration(seconds: 10));
    try {
      await _expectCode(
        secondService.restoreBackup(fixture.result.file),
        BackupRestoreErrorCode.busy,
      );
    } finally {
      if (!release.isCompleted) {
        release.complete();
      }
    }
    final restored = await firstRestore;

    expect(restored.snapshot.items, hasLength(1));
    expect(restored.snapshot.pendingItems, hasLength(1));
    expect((await _imageMetrics(targetRoot)).fileCount, 1);
  });

  test('底层异常中的合成敏感标记不会进入公开错误文本', () async {
    const privateMarker = 'SYNTHETIC_PRIVATE_MARKER_74D1C9';
    final fixture = await _createBackupFixture(sourceRoot);
    final service = _service(
      targetRoot,
      _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      faultInjector: (point) {
        if (point == BackupRestoreFaultPoint.afterRestoreValidation) {
          throw const FileSystemException(privateMarker);
        }
      },
    );

    BackupRestoreException? captured;
    try {
      await service.restoreBackup(fixture.result.file);
      fail('恢复应因合成故障失败');
    } on BackupRestoreException catch (error) {
      captured = error;
    }

    expect(captured, isNotNull);
    expect(captured.code, BackupRestoreErrorCode.writeFailed);
    expect(captured.toString(), isNot(contains(privateMarker)));
    expect(captured.message, isNot(contains(privateMarker)));
  });
}

LocalBackupRestoreService _service(
  Directory root,
  CatalogRepository repository, {
  BackupRestoreLimits limits = const BackupRestoreLimits(),
  BackupRestoreFaultInjector? faultInjector,
  BackupFileSystem? fileSystem,
}) {
  return LocalBackupRestoreService(
    catalogRepository: repository,
    documentsDirectoryProvider: () async => root,
    fileSystem: fileSystem,
    limits: limits,
    timestampProvider: () => DateTime.utc(2026, 8, 9, 12),
    faultInjector: faultInjector,
  );
}

Future<_BackupFixture> _createBackupFixture(
  Directory root, {
  List<int>? mediaBytes,
}) async {
  final images = Directory(_join(root.path, 'images'));
  await images.create(recursive: true);
  final fixtureMediaBytes = mediaBytes ?? _jpeg(red: 35, green: 115, blue: 185);
  final sharedMedia = File(_join(images.path, 'shared-source.jpg'));
  await sharedMedia.writeAsBytes(fixtureMediaBytes, flush: true);
  final repository = _MemoryCatalogRepository(
    CatalogSnapshot(
      items: [
        _item(
          id: 'catalog-item',
          name: '已归档物品',
          imagePath: sharedMedia.path,
          status: ItemStatus.cataloged,
        ),
      ],
      pendingItems: [
        _item(
          id: 'pending-item',
          name: '待确认物品',
          imagePath: sharedMedia.path,
          queueState: QueueRecognitionState.queued,
        ),
      ],
    ),
  );
  final result = await _service(
    root,
    repository,
  ).createBackup(baseName: 'reliable-test');
  return _BackupFixture(result, fixtureMediaBytes);
}

Future<_PreservedTarget> _preservedTarget(Directory root) async {
  final images = Directory(_join(root.path, 'images'));
  await images.create(recursive: true);
  final oldMedia = File(_join(images.path, 'preserved-old.jpg'));
  await oldMedia.writeAsBytes(
    _jpeg(red: 160, green: 90, blue: 40),
    flush: true,
  );
  final repository = _MemoryCatalogRepository(
    CatalogSnapshot(
      items: [
        _item(id: 'preserved-item', name: '原有目录', imagePath: oldMedia.path),
      ],
      pendingItems: const [],
    ),
  );
  return _PreservedTarget(
    repository,
    _snapshotSignature(repository.snapshot),
    await _imageTree(root),
  );
}

Future<void> _expectCode(
  Future<dynamic> operation,
  BackupRestoreErrorCode code,
) async {
  await expectLater(
    operation,
    throwsA(
      isA<BackupRestoreException>().having((error) => error.code, 'code', code),
    ),
  );
}

Future<Map<String, List<int>>> _readZipEntries(File source) async {
  final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
  return <String, List<int>>{
    for (final entry in archive.files)
      entry.name: List<int>.from(entry.content as List<int>),
  };
}

Future<void> _rewritePackage(
  File source,
  File target,
  void Function(Map<String, List<int>> entries) mutate,
) async {
  final entries = await _readZipEntries(source);
  mutate(entries);
  await _writeArchive(
    target,
    entries.entries
        .map((entry) => _ArchiveEntry(entry.key, entry.value))
        .toList(),
  );
}

Future<void> _writeArchive(
  File target,
  List<_ArchiveEntry> entries, {
  bool compress = false,
}) async {
  final encoder = ZipFileEncoder();
  encoder.create(
    target.path,
    level: compress ? ZipFileEncoder.GZIP : ZipFileEncoder.STORE,
  );
  var open = true;
  try {
    for (final entry in entries) {
      final archiveFile = ArchiveFile(
        entry.path,
        entry.bytes.length,
        Uint8List.fromList(entry.bytes),
      )..compress = compress;
      encoder.addArchiveFile(archiveFile);
    }
    await encoder.close();
    open = false;
  } finally {
    if (open) {
      try {
        await encoder.close();
      } catch (_) {
        // The test keeps the original archive construction error.
      }
    }
  }
}

int _requireStandardEocd(List<int> bytes) {
  const endRecordLength = 22;
  if (bytes.length < endRecordLength) {
    throw StateError('测试 ZIP 缺少 EOCD');
  }
  final offset = bytes.length - endRecordLength;
  if (bytes[offset] != 0x50 ||
      bytes[offset + 1] != 0x4b ||
      bytes[offset + 2] != 0x05 ||
      bytes[offset + 3] != 0x06 ||
      bytes[offset + 20] != 0 ||
      bytes[offset + 21] != 0) {
    throw StateError('测试 ZIP 不是无注释标准 EOCD');
  }
  return offset;
}

void _setUint16(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
}

int _uint16At(List<int> bytes, int offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _uint32At(List<int> bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}

void _setUint32(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = (value >> 16) & 0xff;
  bytes[offset + 3] = (value >> 24) & 0xff;
}

List<int> _standardZipCentralOffsets(List<int> bytes) {
  final eocdOffset = _requireStandardEocd(bytes);
  final totalEntries = _uint16At(bytes, eocdOffset + 10);
  final directoryOffset = _uint32At(bytes, eocdOffset + 16);
  final directorySize = _uint32At(bytes, eocdOffset + 12);
  final offsets = <int>[];
  var position = directoryOffset;
  for (var index = 0; index < totalEntries; index++) {
    if (position + 46 > eocdOffset ||
        _uint32At(bytes, position) != 0x02014b50) {
      throw StateError('测试 ZIP 中央目录结构无效');
    }
    offsets.add(position);
    position +=
        46 +
        _uint16At(bytes, position + 28) +
        _uint16At(bytes, position + 30) +
        _uint16At(bytes, position + 32);
  }
  if (position != directoryOffset + directorySize || position != eocdOffset) {
    throw StateError('测试 ZIP 中央目录边界无效');
  }
  return offsets;
}

List<int> _standardZipLocalOffsets(List<int> bytes) {
  return _standardZipCentralOffsets(
    bytes,
  ).map((offset) => _uint32At(bytes, offset + 42)).toList();
}

Future<void> _insertUndeclaredZipBytes(
  File source,
  File target, {
  required int insertionOffset,
  required List<int> insertedBytes,
}) async {
  if (insertedBytes.isEmpty) {
    throw ArgumentError.value(insertedBytes, 'insertedBytes');
  }
  final original = List<int>.from(await source.readAsBytes());
  final originalEocdOffset = _requireStandardEocd(original);
  final originalDirectoryOffset = _uint32At(original, originalEocdOffset + 16);
  if (insertionOffset < 0 || insertionOffset > originalDirectoryOffset) {
    throw ArgumentError.value(insertionOffset, 'insertionOffset');
  }
  final centralOffsets = _standardZipCentralOffsets(original);
  final delta = insertedBytes.length;
  final rewritten = <int>[
    ...original.sublist(0, insertionOffset),
    ...insertedBytes,
    ...original.sublist(insertionOffset),
  ];
  final rewrittenEocdOffset = originalEocdOffset + delta;
  _setUint32(
    rewritten,
    rewrittenEocdOffset + 16,
    originalDirectoryOffset + delta,
  );
  for (final originalCentralOffset in centralOffsets) {
    final rewrittenCentralOffset = originalCentralOffset + delta;
    final originalLocalOffset = _uint32At(original, originalCentralOffset + 42);
    _setUint32(
      rewritten,
      rewrittenCentralOffset + 42,
      originalLocalOffset >= insertionOffset
          ? originalLocalOffset + delta
          : originalLocalOffset,
    );
  }
  await target.writeAsBytes(rewritten, flush: true);
}

Future<void> _appendZipComment(File archive, List<int> comment) async {
  if (comment.isEmpty || comment.length > 0xffff) {
    throw ArgumentError.value(comment.length, 'comment.length');
  }
  final bytes = List<int>.from(await archive.readAsBytes());
  final eocdOffset = _requireStandardEocd(bytes);
  _setUint16(bytes, eocdOffset + 20, comment.length);
  bytes.addAll(comment);
  await archive.writeAsBytes(bytes, flush: true);
}

Future<void> _markFirstEntryAsUnixSymlink(File archive) async {
  final bytes = await archive.readAsBytes();
  const centralSignature = <int>[0x50, 0x4b, 0x01, 0x02];
  var offset = -1;
  for (
    var index = 0;
    index <= bytes.length - centralSignature.length;
    index++
  ) {
    var matches = true;
    for (var part = 0; part < centralSignature.length; part++) {
      if (bytes[index + part] != centralSignature[part]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      offset = index;
      break;
    }
  }
  if (offset < 0 || offset + 42 > bytes.length) {
    throw StateError('测试 ZIP 缺少中心目录记录');
  }

  // central header: versionMadeBy is +4 (little endian), external attributes
  // is +38. Mark the creator as Unix and the high mode word as symlink 0777.
  bytes[offset + 4] = 20;
  bytes[offset + 5] = 3;
  bytes[offset + 38] = 0;
  bytes[offset + 39] = 0;
  bytes[offset + 40] = 0xff;
  bytes[offset + 41] = 0xa1;
  await archive.writeAsBytes(bytes, flush: true);
}

String _snapshotSignature(CatalogSnapshot snapshot) {
  return jsonEncode({
    'items': snapshot.items.map((item) => item.toJson()).toList(),
    'pendingItems': snapshot.pendingItems.map((item) => item.toJson()).toList(),
  });
}

String _snapshotDigest(CatalogSnapshot snapshot) {
  return sha256.convert(utf8.encode(_snapshotSignature(snapshot))).toString();
}

Future<File> _writeSyntheticRestoreJournal(
  Directory root, {
  required CatalogSnapshot previous,
  required CatalogSnapshot next,
  required List<String> createdMediaNames,
}) async {
  final journal = File(_join(root.path, '.wujian-restore-journal.json'));
  await journal.writeAsString(
    jsonEncode({
      'schemaVersion': 1,
      'previousCatalogSha256': _snapshotDigest(previous),
      'nextCatalogSha256': _snapshotDigest(next),
      'createdMedia': createdMediaNames,
    }),
    flush: true,
  );
  return journal;
}

Future<Map<String, String>> _imageTree(Directory root) async {
  final images = Directory(_join(root.path, 'images'));
  if (!await images.exists()) {
    return const <String, String>{};
  }
  final entries = <MapEntry<String, String>>[];
  await for (final entity in images.list(recursive: true, followLinks: false)) {
    if (await FileSystemEntity.type(entity.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    final relative = entity.path.substring(images.path.length + 1);
    final digest = (await sha256.bind(File(entity.path).openRead()).first)
        .toString();
    entries.add(MapEntry(relative, digest));
  }
  entries.sort((left, right) => left.key.compareTo(right.key));
  return Map<String, String>.fromEntries(entries);
}

Future<_ImageMetrics> _imageMetrics(Directory root) async {
  final images = Directory(_join(root.path, 'images'));
  if (!await images.exists()) {
    return const _ImageMetrics(0, 0);
  }
  var count = 0;
  var bytes = 0;
  await for (final entity in images.list(recursive: true, followLinks: false)) {
    if (await FileSystemEntity.type(entity.path, followLinks: false) ==
        FileSystemEntityType.file) {
      count++;
      bytes += await File(entity.path).length();
    }
  }
  return _ImageMetrics(count, bytes);
}

ItemRecord _item({
  required String id,
  required String name,
  String imagePath = '',
  ItemStatus status = ItemStatus.pending,
  QueueRecognitionState queueState = QueueRecognitionState.ready,
}) {
  final timestamp = DateTime.utc(2026, 8, 9, 10);
  return ItemRecord(
    id: id,
    name: name,
    category: '合成测试',
    quantity: 1,
    status: status,
    imagePath: imagePath,
    description: '仅包含合成测试数据',
    parameters: const {'fixture': 'synthetic'},
    notes: '',
    room: '测试房间',
    box: '测试箱',
    brand: '',
    model: '',
    color: '',
    material: '',
    createdAt: timestamp,
    updatedAt: timestamp,
    queueState: queueState,
    recognitionError: '',
  );
}

List<int> _jpeg({
  required int red,
  required int green,
  required int blue,
  int width = 72,
  int height = 48,
}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(
        x,
        y,
        (red + x * 2 + y).clamp(0, 255),
        (green + x + y * 2).clamp(0, 255),
        (blue + x + y).clamp(0, 255),
      );
    }
  }
  return img.encodeJpg(image, quality: 91);
}

String _join(String parent, String child) {
  return '$parent${Platform.pathSeparator}${child.replaceAll('/', Platform.pathSeparator)}';
}

String _basenameForTest(String path) {
  return path.split(Platform.pathSeparator).last;
}

class _MemoryCatalogRepository implements CatalogRepository {
  _MemoryCatalogRepository(this.snapshot);

  CatalogSnapshot snapshot;
  int failNextSaves = 0;
  bool persistThenFailNextSave = false;
  int failNextSavesAfterPersistFailure = 0;
  int saveCalls = 0;

  @override
  Future<CatalogSnapshot> loadCatalog() async => snapshot;

  @override
  Future<void> saveCatalog(CatalogSnapshot next) async {
    saveCalls++;
    if (persistThenFailNextSave) {
      persistThenFailNextSave = false;
      snapshot = next;
      failNextSaves += failNextSavesAfterPersistFailure;
      failNextSavesAfterPersistFailure = 0;
      throw const FileSystemException('合成目录持久化后中断');
    }
    if (failNextSaves > 0) {
      failNextSaves--;
      throw const FileSystemException('合成目录写入中断');
    }
    snapshot = next;
  }
}

class _PartialWriteThenThrowBackupFileSystem implements BackupFileSystem {
  final LocalBackupFileSystem _delegate = LocalBackupFileSystem();
  bool partialWriteAttempted = false;

  @override
  Future<void> copyAndSync(File source, File destination) async {
    final name = destination.path.split(Platform.pathSeparator).last;
    if (!partialWriteAttempted && name.startsWith('.restore-')) {
      partialWriteAttempted = true;
      final bytes = await source.readAsBytes();
      final partialLength = bytes.length > 1 ? bytes.length ~/ 2 : 1;
      await destination.parent.create(recursive: true);
      await destination.create(exclusive: true);
      await destination.writeAsBytes(
        bytes.sublist(0, partialLength),
        flush: true,
      );
      throw const FileSystemException('合成部分写入中断');
    }
    await _delegate.copyAndSync(source, destination);
  }

  @override
  Future<void> deleteDirectory(Directory directory) {
    return _delegate.deleteDirectory(directory);
  }

  @override
  Future<void> deleteFile(File file) {
    return _delegate.deleteFile(file);
  }

  @override
  Future<File> renameNew(File source, File destination) {
    return _delegate.renameNew(source, destination);
  }

  @override
  Future<void> syncFile(File file) {
    return _delegate.syncFile(file);
  }
}

class _SilentCorruptCopyBackupFileSystem implements BackupFileSystem {
  final LocalBackupFileSystem _delegate = LocalBackupFileSystem();
  bool corruptCopyAttempted = false;

  @override
  Future<void> copyAndSync(File source, File destination) async {
    final name = _basenameForTest(destination.path);
    if (!corruptCopyAttempted && name.startsWith('.restore-')) {
      corruptCopyAttempted = true;
      final bytes = await source.readAsBytes();
      final corrupted = List<int>.from(bytes);
      corrupted[corrupted.length ~/ 2] ^= 0x01;
      await destination.create(exclusive: true);
      await destination.writeAsBytes(corrupted, flush: true);
      return;
    }
    await _delegate.copyAndSync(source, destination);
  }

  @override
  Future<void> deleteDirectory(Directory directory) {
    return _delegate.deleteDirectory(directory);
  }

  @override
  Future<void> deleteFile(File file) {
    return _delegate.deleteFile(file);
  }

  @override
  Future<File> renameNew(File source, File destination) {
    return _delegate.renameNew(source, destination);
  }

  @override
  Future<void> syncFile(File file) {
    return _delegate.syncFile(file);
  }
}

class _FailPartialDeleteOnceBackupFileSystem implements BackupFileSystem {
  final LocalBackupFileSystem _delegate = LocalBackupFileSystem();
  int partialDeleteFailures = 0;
  File? retainedPartial;

  @override
  Future<void> copyAndSync(File source, File destination) {
    return _delegate.copyAndSync(source, destination);
  }

  @override
  Future<void> deleteDirectory(Directory directory) {
    return _delegate.deleteDirectory(directory);
  }

  @override
  Future<void> deleteFile(File file) {
    if (partialDeleteFailures == 0 && file.path.endsWith('.partial')) {
      partialDeleteFailures++;
      retainedPartial = file;
      throw const FileSystemException('合成 partial 删除失败');
    }
    return _delegate.deleteFile(file);
  }

  @override
  Future<File> renameNew(File source, File destination) {
    return _delegate.renameNew(source, destination);
  }

  @override
  Future<void> syncFile(File file) {
    return _delegate.syncFile(file);
  }
}

class _FailWorkspaceDeleteOnceBackupFileSystem implements BackupFileSystem {
  final LocalBackupFileSystem _delegate = LocalBackupFileSystem();
  int workspaceDeleteFailures = 0;
  Directory? retainedWorkspace;

  @override
  Future<void> copyAndSync(File source, File destination) {
    return _delegate.copyAndSync(source, destination);
  }

  @override
  Future<void> deleteDirectory(Directory directory) {
    final name = _basenameForTest(directory.path);
    if (workspaceDeleteFailures == 0 && name.startsWith('.wujian-validate-')) {
      workspaceDeleteFailures++;
      retainedWorkspace = directory;
      throw const FileSystemException('合成 workspace 删除失败');
    }
    return _delegate.deleteDirectory(directory);
  }

  @override
  Future<void> deleteFile(File file) {
    return _delegate.deleteFile(file);
  }

  @override
  Future<File> renameNew(File source, File destination) {
    return _delegate.renameNew(source, destination);
  }

  @override
  Future<void> syncFile(File file) {
    return _delegate.syncFile(file);
  }
}

class _FailJournalDeleteBackupFileSystem implements BackupFileSystem {
  final LocalBackupFileSystem _delegate = LocalBackupFileSystem();
  bool failJournalDeletion = true;
  int journalDeleteAttempts = 0;

  @override
  Future<void> copyAndSync(File source, File destination) {
    return _delegate.copyAndSync(source, destination);
  }

  @override
  Future<void> deleteDirectory(Directory directory) {
    return _delegate.deleteDirectory(directory);
  }

  @override
  Future<void> deleteFile(File file) {
    final name = file.path.split(Platform.pathSeparator).last;
    if (name == '.wujian-restore-journal.json') {
      journalDeleteAttempts++;
      if (failJournalDeletion) {
        throw const FileSystemException('合成 journal 删除中断');
      }
    }
    return _delegate.deleteFile(file);
  }

  @override
  Future<File> renameNew(File source, File destination) {
    return _delegate.renameNew(source, destination);
  }

  @override
  Future<void> syncFile(File file) {
    return _delegate.syncFile(file);
  }
}

class _PersistRenameThenThrowBackupFileSystem implements BackupFileSystem {
  _PersistRenameThenThrowBackupFileSystem({
    this.throwOnBackupPublish = false,
    this.throwOnRestoreMediaPublish = false,
    this.throwOnJournalPublish = false,
    this.createExactTargetBeforeBackupPublish = false,
    this.createExactTargetBeforeRestoreMediaPublish = false,
  });

  final LocalBackupFileSystem _delegate = LocalBackupFileSystem();
  final bool throwOnBackupPublish;
  final bool throwOnRestoreMediaPublish;
  final bool throwOnJournalPublish;
  final bool createExactTargetBeforeBackupPublish;
  final bool createExactTargetBeforeRestoreMediaPublish;
  int backupPublishThrows = 0;
  int restoreMediaPublishThrows = 0;
  int journalPublishThrows = 0;
  int backupPublishPreRenameThrows = 0;
  int restoreMediaPreRenameThrows = 0;
  File? competingBackupTarget;
  File? competingMediaTarget;

  @override
  Future<void> copyAndSync(File source, File destination) {
    return _delegate.copyAndSync(source, destination);
  }

  @override
  Future<void> deleteDirectory(Directory directory) {
    return _delegate.deleteDirectory(directory);
  }

  @override
  Future<void> deleteFile(File file) {
    return _delegate.deleteFile(file);
  }

  @override
  Future<File> renameNew(File source, File destination) async {
    final name = _basenameForTest(destination.path);
    if (createExactTargetBeforeBackupPublish &&
        backupPublishPreRenameThrows == 0 &&
        name.endsWith('.wujian-backup')) {
      backupPublishPreRenameThrows++;
      competingBackupTarget = await source.copy(destination.path);
      throw const FileSystemException('合成导出 rename 前目标竞争');
    }
    if (createExactTargetBeforeRestoreMediaPublish &&
        restoreMediaPreRenameThrows == 0 &&
        RegExp(r'^backup-[0-9a-f]{64}\.(jpg|png|webp)$').hasMatch(name)) {
      restoreMediaPreRenameThrows++;
      competingMediaTarget = await source.copy(destination.path);
      throw const FileSystemException('合成恢复 rename 前目标竞争');
    }
    final published = await _delegate.renameNew(source, destination);
    if (throwOnBackupPublish &&
        backupPublishThrows == 0 &&
        name.endsWith('.wujian-backup')) {
      backupPublishThrows++;
      throw const FileSystemException('合成导出 rename 落盘后报错');
    }
    if (throwOnRestoreMediaPublish &&
        restoreMediaPublishThrows == 0 &&
        RegExp(r'^backup-[0-9a-f]{64}\.(jpg|png|webp)$').hasMatch(name)) {
      restoreMediaPublishThrows++;
      throw const FileSystemException('合成恢复 rename 落盘后报错');
    }
    if (throwOnJournalPublish &&
        journalPublishThrows == 0 &&
        name == '.wujian-restore-journal.json') {
      journalPublishThrows++;
      throw const FileSystemException('合成 journal rename 落盘后报错');
    }
    return published;
  }

  @override
  Future<void> syncFile(File file) {
    return _delegate.syncFile(file);
  }
}

class _BackupFixture {
  const _BackupFixture(this.result, this.mediaBytes);

  final BackupCreateResult result;
  final List<int> mediaBytes;
}

class _PreservedTarget {
  const _PreservedTarget(
    this.repository,
    this.snapshotSignature,
    this.imageTree,
  );

  final _MemoryCatalogRepository repository;
  final String snapshotSignature;
  final Map<String, String> imageTree;
}

class _ArchiveEntry {
  const _ArchiveEntry(this.path, this.bytes);

  final String path;
  final List<int> bytes;
}

class _ImageMetrics {
  const _ImageMetrics(this.fileCount, this.totalBytes);

  final int fileCount;
  final int totalBytes;
}
