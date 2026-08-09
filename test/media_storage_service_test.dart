import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/services/media_storage_service.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory root;
  late Directory documents;
  late Directory temporary;
  late MediaStorageService service;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wujian-media-test-');
    documents = Directory('${root.path}${Platform.pathSeparator}documents');
    temporary = Directory('${root.path}${Platform.pathSeparator}temporary');
    await documents.create(recursive: true);
    await temporary.create(recursive: true);
    service = MediaStorageService(
      documentsDirectoryProvider: () async => documents,
      temporaryDirectoryProvider: () async => temporary,
    );
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('同一图片只保留一个压缩文件并删除临时源文件', () async {
    final bytes = _jpeg(width: 3000, height: 1200);
    final firstSource = File('${temporary.path}/capture-first.jpg');
    final secondSource = File('${temporary.path}/capture-second.jpg');
    await firstSource.writeAsBytes(bytes);
    await secondSource.writeAsBytes(bytes);

    final first = await service.persistImage(firstSource);
    final second = await service.persistImage(secondSource);

    expect(second.path, first.path);
    expect(await first.exists(), isTrue);
    expect(await firstSource.exists(), isFalse);
    expect(await secondSource.exists(), isFalse);

    final decoded = img.decodeImage(await first.readAsBytes());
    expect(decoded, isNotNull);
    expect(decoded!.width, 2048);
    expect(decoded.height, 819);

    final usage = await service.computeUsage();
    expect(usage.imageCount, 1);
    expect(usage.captureCacheCount, 0);
    expect(usage.imageBytes, greaterThan(0));
  });

  test('重复导入不同源压缩质量的同一画面仍只保留一张永久图片', () async {
    final firstSource = File('${temporary.path}/quality-high.jpg');
    final secondSource = File('${temporary.path}/quality-low.jpg');
    await firstSource.writeAsBytes(_sceneJpeg(quality: 95));
    await secondSource.writeAsBytes(_sceneJpeg(quality: 45));

    final first = await service.persistImage(firstSource);
    final second = await service.persistImage(secondSource);
    final usage = await service.computeUsage();

    expect(second.path, first.path);
    expect(usage.imageCount, 1);
    expect(usage.captureCacheCount, 0);
    // ignore: avoid_print
    print(
      '[storage-metrics] jpeg-quality-near-duplicate '
      'images=${usage.imageCount} '
      'permanentBytes=${usage.imageBytes} '
      'cacheCount=${usage.captureCacheCount} '
      'cacheBytes=${usage.captureCacheBytes}',
    );
  });

  test('横竖构图不会被视觉指纹误合并', () async {
    final landscape = File('${temporary.path}/landscape.jpg');
    final portrait = File('${temporary.path}/portrait.jpg');
    await landscape.writeAsBytes(
      _jpeg(width: 800, height: 600, red: 40, green: 120, blue: 180),
    );
    await portrait.writeAsBytes(
      _jpeg(width: 600, height: 800, red: 40, green: 120, blue: 180),
    );

    final landscapeStored = await service.persistImage(landscape);
    final portraitStored = await service.persistImage(portrait);
    final usage = await service.computeUsage();

    expect(portraitStored.path, isNot(landscapeStored.path));
    expect(usage.imageCount, 2);
    expect(usage.captureCacheCount, 0);
  });

  test('粗指纹候选相同的不同色块仍保留两份永久图片', () async {
    final first = File('${temporary.path}/color-first.jpg');
    final second = File('${temporary.path}/color-second.jpg');
    await first.writeAsBytes(
      _jpeg(width: 640, height: 480, red: 40, green: 120, blue: 180),
    );
    await second.writeAsBytes(
      _jpeg(width: 640, height: 480, red: 52, green: 120, blue: 180),
    );

    final firstStored = await service.persistImage(first);
    final secondStored = await service.persistImage(second);
    final usage = await service.computeUsage();

    expect(secondStored.path, isNot(firstStored.path));
    expect(usage.imageCount, 2);
    expect(usage.captureCacheCount, 0);
    // ignore: avoid_print
    print(
      '[storage-metrics] fingerprint-boundary '
      'images=${usage.imageCount} '
      'permanentBytes=${usage.imageBytes} '
      'cacheCount=${usage.captureCacheCount} '
      'cacheBytes=${usage.captureCacheBytes}',
    );
  });

  test('自动优化清理旧临时图但保留最近拍摄中的文件', () async {
    final oldCache = File('${temporary.path}/nested/old.jpg');
    final recentCache = File('${temporary.path}/recent.jpg');
    await oldCache.parent.create(recursive: true);
    await oldCache.writeAsBytes(_jpeg(width: 64, height: 64));
    await recentCache.writeAsBytes(_jpeg(width: 64, height: 64));
    await oldCache.setLastModified(
      DateTime.now().subtract(const Duration(hours: 2)),
    );

    final before = await service.computeUsage();
    expect(before.captureCacheCount, 2);

    await service.optimizeStorage(referencedImagePaths: const []);

    expect(await oldCache.exists(), isFalse);
    expect(await recentCache.exists(), isTrue);

    await service.clearTransientCache();
    expect(await recentCache.exists(), isFalse);
    expect((await service.computeUsage()).captureCacheCount, 0);
  });

  test('优化只删除未引用的永久图片', () async {
    final source = File('${temporary.path}/capture-kept.jpg');
    await source.writeAsBytes(_jpeg(width: 320, height: 240));
    final persisted = await service.persistImage(source);

    await service.optimizeStorage(referencedImagePaths: [persisted.path]);
    expect(await persisted.exists(), isTrue);

    await service.optimizeStorage(referencedImagePaths: const []);
    expect(await persisted.exists(), isFalse);
  });

  test('连续拍摄并发保存时按内容去重并记录存储指标', () async {
    final sources = <File>[];
    for (var index = 0; index < 12; index++) {
      final payload = _jpeg(
        width: 640,
        height: 480,
        red: 30 + (index % 4) * 20,
        green: 100,
        blue: 180,
      );
      final source = File('${temporary.path}/burst-$index.jpg');
      await source.writeAsBytes(payload);
      sources.add(source);
    }

    final before = await service.computeUsage();
    final persisted = await Future.wait(sources.map(service.persistImage));
    final after = await service.computeUsage();

    expect(before.imageCount, 0);
    expect(after.imageCount, 4);
    expect(after.imageBytes, greaterThan(0));
    expect(after.captureCacheCount, 0);
    expect(persisted.map((file) => file.path).toSet(), hasLength(4));
    expect(sources.every((source) => !source.existsSync()), isTrue);

    // These lines make the storage regression signal visible in CI logs.
    // ignore: avoid_print
    print(
      '[storage-metrics] burst '
      'images=${after.imageCount} '
      'permanentBytes=${after.imageBytes} '
      'cacheCount=${after.captureCacheCount} '
      'cacheBytes=${after.captureCacheBytes} '
      'deltaPermanentBytes=${after.imageBytes - before.imageBytes}',
    );
  });

  test('原子写入并发完成后不留下临时文件', () async {
    final sources = <File>[];
    for (var index = 0; index < 20; index++) {
      final source = File('${temporary.path}/concurrent-$index.jpg');
      await source.writeAsBytes(
        _jpeg(width: 320, height: 240, red: 20 + index, green: 80, blue: 160),
      );
      sources.add(source);
    }

    await Future.wait(sources.map(service.persistImage));

    final imageFiles = Directory(
      '${documents.path}/images',
    ).listSync().whereType<File>().toList();
    expect(imageFiles, isNotEmpty);
    expect(imageFiles.any((file) => file.path.contains('.tmp-')), isFalse);
    expect((await service.computeUsage()).captureCacheCount, 0);
  });

  test('中断遗留的部分写入不计入永久占用且优化可清理孤儿', () async {
    final source = File('${temporary.path}/referenced.jpg');
    await source.writeAsBytes(_sceneJpeg(quality: 90));
    final referenced = await service.persistImage(source);
    final referencedBytes = await referenced.length();
    final images = Directory('${documents.path}/images');
    final orphan = File('${images.path}/${'f' * 64}.jpg');
    final interrupted = File('${images.path}/${'e' * 64}.jpg.tmp-interrupted');
    await referenced.copy(orphan.path);
    await interrupted.writeAsBytes(const [1, 2, 3, 4]);

    final before = await service.computeUsage();
    expect(before.imageCount, 2);
    expect(before.imageBytes, referencedBytes * 2);

    await service.optimizeStorage(referencedImagePaths: [referenced.path]);

    final after = await service.computeUsage();
    expect(await referenced.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
    expect(await interrupted.exists(), isFalse);
    expect(after.imageCount, 1);
    expect(after.imageBytes, referencedBytes);
    expect(after.captureCacheCount, 0);
    // ignore: avoid_print
    print(
      '[storage-metrics] interrupted-write-orphan-cleanup '
      'beforeImages=${before.imageCount} '
      'beforePermanentBytes=${before.imageBytes} '
      'afterImages=${after.imageCount} '
      'afterPermanentBytes=${after.imageBytes} '
      'deltaPermanentBytes=${after.imageBytes - before.imageBytes}',
    );
  });

  test('异常图片不会生成永久文件，清理临时缓存后可回收源文件', () async {
    final broken = File('${temporary.path}/broken.jpg');
    await broken.writeAsBytes(const [1, 2, 3, 4]);

    await expectLater(
      service.persistImage(broken),
      throwsA(isA<FormatException>()),
    );
    final before = await service.computeUsage();
    expect(before.imageCount, 0);
    expect(before.captureCacheCount, 0);
    expect(await broken.exists(), isFalse);

    await service.clearTransientCache();
    final after = await service.computeUsage();
    expect(after.imageCount, 0);
    expect(after.imageBytes, 0);
    expect(after.captureCacheCount, 0);
    expect(await broken.exists(), isFalse);

    final external = File('${documents.path}/user-picked.jpg');
    await external.writeAsBytes(const [1, 2, 3, 4]);
    await expectLater(
      service.persistImage(external),
      throwsA(isA<FormatException>()),
    );
    expect(await external.exists(), isTrue);

    final actualTraversalTarget = File(
      '${documents.path}/user-picked-via-parent.jpg',
    );
    await actualTraversalTarget.writeAsBytes(const [1, 2, 3, 4]);
    final traversalSource = File(
      '${temporary.path}${Platform.pathSeparator}..'
      '${Platform.pathSeparator}documents'
      '${Platform.pathSeparator}user-picked-via-parent.jpg',
    );
    await expectLater(
      service.persistImage(traversalSource),
      throwsA(isA<FormatException>()),
    );
    expect(await actualTraversalTarget.exists(), isTrue);
  });

  test('导出清理最多保留六个临时导出并清除旧目录', () async {
    final exports = Directory('${temporary.path}/exports');
    final legacyExports = Directory('${documents.path}/exports');
    await exports.create(recursive: true);
    await legacyExports.create(recursive: true);

    for (var index = 0; index < 8; index++) {
      final file = File('${exports.path}/export-$index.md');
      await file.writeAsString('export $index');
      await file.setLastModified(
        DateTime.now().subtract(Duration(minutes: index)),
      );
    }
    final legacy = File('${legacyExports.path}/legacy.md');
    await legacy.writeAsString('legacy export');

    final before = await service.computeUsage();
    await service.pruneExports();
    final after = await service.computeUsage();
    final remaining = exports.listSync().whereType<File>().toList();

    expect(before.exportCount, 9);
    expect(after.exportCount, 6);
    expect(remaining, hasLength(6));
    expect(await legacy.exists(), isFalse);
    expect(after.exportBytes, greaterThan(0));

    // ignore: avoid_print
    print(
      '[storage-metrics] exports '
      'beforeCount=${before.exportCount} '
      'beforeBytes=${before.exportBytes} '
      'afterCount=${after.exportCount} '
      'afterBytes=${after.exportBytes}',
    );
  });
}

List<int> _jpeg({
  required int width,
  required int height,
  int red = 35,
  int green = 120,
  int blue = 180,
  int quality = 95,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(red, green, blue));
  return img.encodeJpg(image, quality: quality);
}

List<int> _sceneJpeg({required int quality}) {
  const width = 480;
  const height = 320;
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final checker = ((x ~/ 40) + (y ~/ 32)).isEven ? 18 : -18;
      final red = (30 + x * 170 ~/ width + checker).clamp(0, 255);
      final green = (45 + y * 150 ~/ height - checker).clamp(0, 255);
      final blue = (70 + (x + y) * 120 ~/ (width + height)).clamp(0, 255);
      image.setPixelRgb(x, y, red, green, blue);
    }
  }
  return img.encodeJpg(image, quality: quality);
}
