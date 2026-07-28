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
}

List<int> _jpeg({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(35, 120, 180));
  return img.encodeJpg(image, quality: 95);
}
