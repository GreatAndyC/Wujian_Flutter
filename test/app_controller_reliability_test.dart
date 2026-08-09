import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/services/excel_export_service.dart';
import 'package:icheck/data/services/local_file_save_service.dart';
import 'package:icheck/data/services/markdown_export_service.dart';
import 'package:icheck/data/services/media_storage_service.dart';
import 'package:icheck/data/services/pdf_export_service.dart';
import 'package:icheck/domain/entities/app_settings.dart';
import 'package:icheck/domain/entities/app_settings_store.dart';
import 'package:icheck/domain/entities/item_record.dart';
import 'package:icheck/domain/entities/recognition_result.dart';
import 'package:icheck/domain/entities/token_usage_stats.dart';
import 'package:icheck/domain/repositories/catalog_repository.dart';
import 'package:icheck/domain/repositories/recognition_repository.dart';
import 'package:icheck/domain/repositories/settings_repository.dart';
import 'package:icheck/domain/repositories/token_usage_repository.dart';
import 'package:icheck/features/shell/app_controller.dart';
import 'package:image/image.dart' as img;

void main() {
  late Directory root;
  late Directory documents;
  late Directory temporary;
  late MediaStorageService mediaStorage;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wujian-controller-test-');
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

  test('启动时把中断的 processing 项恢复为 queued 并持久化', () async {
    final catalog = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: const [],
        pendingItems: [
          _item(
            id: 'interrupted',
            imagePath: '${documents.path}/missing.jpg',
            queueState: QueueRecognitionState.processing,
          ),
        ],
      ),
    );
    final controller = _controller(
      catalog: catalog,
      mediaStorage: mediaStorage,
      recognition: _NeverRecognitionRepository(),
    );

    await controller.initialize();

    expect(catalog.savedSnapshots, isNotEmpty);
    expect(
      catalog.savedSnapshots.first.pendingItems.single.queueState,
      QueueRecognitionState.queued,
    );
    expect(
      catalog.savedSnapshots.first.pendingItems.single.description,
      contains('自动重新排队'),
    );
  });

  test('并发导入相同照片只创建一个待确认项目和一个永久文件', () async {
    final catalog = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final controller = _controller(
      catalog: catalog,
      mediaStorage: mediaStorage,
      recognition: _ImmediateRecognitionRepository(),
    );
    await controller.initialize();

    final bytes = _jpeg();
    final first = File('${temporary.path}/capture-1.jpg');
    final second = File('${temporary.path}/capture-2.jpg');
    await first.writeAsBytes(bytes);
    await second.writeAsBytes(bytes);

    final results = await Future.wait([
      controller.queueCapturedFile(first),
      controller.queueCapturedFile(second),
    ]);

    expect(results.where((result) => result), hasLength(1));
    expect(results.where((result) => !result), hasLength(1));
    expect(controller.pendingQueue, hasLength(1));
    final images = Directory('${documents.path}/images').listSync();
    expect(images.whereType<File>(), hasLength(1));
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isFalse);
  });

  test('连续拍摄同一箱子时图片全部落盘且箱号不丢失', () async {
    final catalog = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final controller = _controller(
      catalog: catalog,
      mediaStorage: mediaStorage,
      recognition: _ImmediateRecognitionRepository(),
    );
    await controller.initialize();

    final sources = <File>[];
    for (var index = 0; index < 10; index++) {
      final source = File('${temporary.path}/box-burst-$index.jpg');
      await source.writeAsBytes(
        _jpeg(
          width: 480 + index,
          height: 320,
          red: 20 + index * 20,
          green: 80 + index * 10,
          blue: 40 + index * 12,
        ),
      );
      sources.add(source);
    }

    final results = await Future.wait(
      sources.map(
        (source) => controller.queueCapturedFile(source, box: '客厅-纸箱-01'),
      ),
    );
    await _waitUntil(
      () =>
          !controller.isProcessingQueue &&
          controller.pendingQueue.length == sources.length &&
          controller.pendingQueue.every(
            (item) => item.queueState == QueueRecognitionState.ready,
          ),
    );

    expect(results.every((result) => result), isTrue);
    expect(controller.pendingQueue, hasLength(10));
    expect(
      controller.pendingQueue.every((item) => item.box == '客厅-纸箱-01'),
      isTrue,
    );
    final usage = await mediaStorage.computeUsage();
    expect(usage.imageCount, 10);
    expect(usage.imageBytes, greaterThan(0));
    expect(usage.captureCacheCount, 0);
    expect(sources.every((source) => !source.existsSync()), isTrue);

    // ignore: avoid_print
    print(
      '[storage-metrics] continuous-capture '
      'images=${usage.imageCount} '
      'permanentBytes=${usage.imageBytes} '
      'cacheCount=${usage.captureCacheCount} '
      'cacheBytes=${usage.captureCacheBytes}',
    );
  });

  test('目录保存失败时内存状态回滚且导入返回失败', () async {
    final catalog = _MemoryCatalogRepository(const CatalogSnapshot.empty());
    final controller = _controller(
      catalog: catalog,
      mediaStorage: mediaStorage,
      recognition: _ImmediateRecognitionRepository(),
    );
    await controller.initialize();
    catalog.failNextSave = true;
    final source = File('${temporary.path}/capture-failure.jpg');
    await source.writeAsBytes(_jpeg());

    final succeeded = await controller.queueCapturedFile(source);

    expect(succeeded, isFalse);
    expect(controller.pendingQueue, isEmpty);
    expect(await source.exists(), isTrue);
    expect(
      Directory('${documents.path}/images').listSync().whereType<File>(),
      isEmpty,
    );
  });

  test('配置保存失败时恢复原配置并给出错误消息', () async {
    final settings = _MemorySettingsRepository()..failNextSave = true;
    final controller = _controller(
      catalog: _MemoryCatalogRepository(const CatalogSnapshot.empty()),
      mediaStorage: mediaStorage,
      recognition: _ImmediateRecognitionRepository(),
      settings: settings,
    );
    await controller.initialize();
    final originalProfile = controller.activeProfile;

    await controller.saveProfile(
      profileId: originalProfile.id,
      profileName: '保存失败的新名称',
      settings: originalProfile.settings,
    );

    expect(controller.activeProfile.name, originalProfile.name);
    expect(controller.message, contains('simulated settings failure'));
  });

  test('启动优化会压缩并合并旧版本永久图片', () async {
    final legacyImages = Directory('${documents.path}/images');
    await legacyImages.create(recursive: true);
    final firstLegacy = File('${legacyImages.path}/${'a' * 64}.jpg');
    final secondLegacy = File('${legacyImages.path}/${'b' * 64}.jpg');
    final bytes = _jpeg(width: 3000, height: 1200);
    await firstLegacy.writeAsBytes(bytes);
    await secondLegacy.writeAsBytes(bytes);
    final before = await mediaStorage.computeUsage();
    final catalog = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(
            id: 'legacy-1',
            imagePath: firstLegacy.path,
            queueState: QueueRecognitionState.ready,
          ),
          _item(
            id: 'legacy-2',
            imagePath: secondLegacy.path,
            queueState: QueueRecognitionState.ready,
          ),
        ],
        pendingItems: const [],
      ),
    );
    final controller = _controller(
      catalog: catalog,
      mediaStorage: mediaStorage,
      recognition: _ImmediateRecognitionRepository(),
    );

    await controller.initialize();
    await _waitUntil(
      () =>
          controller.items.every(
            (item) =>
                RegExp(r'/v2-[0-9a-f]{64}\.jpg$').hasMatch(item.imagePath),
          ) &&
          !controller.isBusy,
    );
    final after = await mediaStorage.computeUsage();

    expect(
      controller.items.map((item) => item.imagePath).toSet(),
      hasLength(1),
    );
    expect(await firstLegacy.exists(), isFalse);
    expect(await secondLegacy.exists(), isFalse);
    expect(
      Directory('${documents.path}/images').listSync().whereType<File>(),
      hasLength(1),
    );
    expect(before.imageCount, 2);
    expect(after.imageCount, 1);
    expect(after.imageBytes, lessThan(before.imageBytes));
    expect(after.captureCacheCount, 0);
    // ignore: avoid_print
    print(
      '[storage-metrics] migration '
      'beforeImages=${before.imageCount} '
      'beforePermanentBytes=${before.imageBytes} '
      'afterImages=${after.imageCount} '
      'afterPermanentBytes=${after.imageBytes} '
      'deltaPermanentBytes=${after.imageBytes - before.imageBytes}',
    );
  });

  test('启动迁移按 canonical documents root 解析旧 catalog 相对图片路径', () async {
    final legacyImages = Directory('${documents.path}/images');
    await legacyImages.create(recursive: true);
    final legacy = File('${legacyImages.path}/legacy-relative.jpg');
    await legacy.writeAsBytes(_jpeg(width: 960, height: 640));
    final catalog = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(
            id: 'legacy-relative',
            imagePath: 'images/legacy-relative.jpg',
            queueState: QueueRecognitionState.ready,
          ),
        ],
        pendingItems: const [],
      ),
    );
    final controller = _controller(
      catalog: catalog,
      mediaStorage: mediaStorage,
      recognition: _ImmediateRecognitionRepository(),
    );

    await controller.initialize();
    await _waitUntil(
      () =>
          RegExp(
            r'/v2-[0-9a-f]{64}\.jpg$',
          ).hasMatch(controller.items.single.imagePath) &&
          !controller.isBusy,
    );

    final migratedPath = controller.items.single.imagePath;
    expect(File(migratedPath).isAbsolute, isTrue);
    expect(await File(migratedPath).exists(), isTrue);
    expect(await legacy.exists(), isFalse);
    expect(catalog.savedSnapshots.last.items.single.imagePath, migratedPath);
    expect((await mediaStorage.computeUsage()).imageCount, 1);
  });

  test('旧版临时图迁移保存失败时保留源图，重试成功且幂等', () async {
    final legacy = File('${temporary.path}/legacy-retry.jpg');
    await legacy.writeAsBytes(_jpeg(width: 960, height: 640));
    final originalBytes = await legacy.readAsBytes();
    final catalog = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(
            id: 'legacy-retry',
            imagePath: legacy.path,
            queueState: QueueRecognitionState.ready,
          ),
        ],
        pendingItems: const [],
      ),
    )..failNextSave = true;
    final controller = _controller(
      catalog: catalog,
      mediaStorage: mediaStorage,
      recognition: _ImmediateRecognitionRepository(),
    );

    await controller.initialize();
    await _waitUntil(() => !controller.isBusy);

    expect(await legacy.exists(), isTrue);
    expect(await legacy.readAsBytes(), originalBytes);
    expect(controller.items.single.imagePath, legacy.path);
    expect(
      Directory('${documents.path}/images').listSync().whereType<File>(),
      isEmpty,
    );

    await controller.optimizeStorage();
    final migratedPath = controller.items.single.imagePath;
    final afterRetry = await mediaStorage.computeUsage();
    expect(migratedPath, isNot(legacy.path));
    expect(await legacy.exists(), isFalse);
    expect(afterRetry.imageCount, 1);
    expect(afterRetry.captureCacheCount, 0);

    await controller.optimizeStorage();
    final afterSecondPass = await mediaStorage.computeUsage();
    expect(controller.items.single.imagePath, migratedPath);
    expect(afterSecondPass.imageCount, afterRetry.imageCount);
    expect(afterSecondPass.imageBytes, afterRetry.imageBytes);
  });

  test('损坏旧图不阻断其他迁移且原文件与引用均保留', () async {
    final legacyImages = Directory('${documents.path}/images');
    await legacyImages.create(recursive: true);
    final broken = File('${legacyImages.path}/broken-legacy.jpg');
    final valid = File('${legacyImages.path}/valid-legacy.jpg');
    const brokenBytes = [1, 2, 3, 4, 5];
    await broken.writeAsBytes(brokenBytes);
    await valid.writeAsBytes(_jpeg(width: 1280, height: 720));
    final catalog = _MemoryCatalogRepository(
      CatalogSnapshot(
        items: [
          _item(
            id: 'broken-legacy',
            imagePath: 'images/broken-legacy.jpg',
            queueState: QueueRecognitionState.ready,
          ),
          _item(
            id: 'valid-legacy',
            imagePath: valid.path,
            queueState: QueueRecognitionState.ready,
          ),
        ],
        pendingItems: const [],
      ),
    );
    final controller = _controller(
      catalog: catalog,
      mediaStorage: mediaStorage,
      recognition: _ImmediateRecognitionRepository(),
    );

    await controller.initialize();
    await _waitUntil(() => !controller.isBusy);

    final brokenRecord = controller.items.singleWhere(
      (item) => item.id == 'broken-legacy',
    );
    final validRecord = controller.items.singleWhere(
      (item) => item.id == 'valid-legacy',
    );
    expect(brokenRecord.imagePath, 'images/broken-legacy.jpg');
    expect(await broken.readAsBytes(), brokenBytes);
    expect(validRecord.imagePath, isNot(valid.path));
    expect(await valid.exists(), isFalse);
    expect((await mediaStorage.computeUsage()).imageCount, 2);

    final migratedPath = validRecord.imagePath;
    await controller.optimizeStorage();
    expect(
      controller.items
          .singleWhere((item) => item.id == 'valid-legacy')
          .imagePath,
      migratedPath,
    );
    expect(await broken.readAsBytes(), brokenBytes);
  });

  test('火山识别并发上限为四个且队列最终全部完成', () async {
    final images = Directory('${documents.path}/images');
    await images.create(recursive: true);
    final pendingItems = <ItemRecord>[];
    for (var index = 0; index < 10; index++) {
      final fileName = index.toRadixString(16).padLeft(64, '0');
      final file = File('${images.path}/$fileName.jpg');
      await file.writeAsBytes(_jpeg());
      pendingItems.add(
        _item(
          id: 'queued-$index',
          imagePath: file.path,
          queueState: QueueRecognitionState.queued,
        ),
      );
    }
    final recognition = _DelayedRecognitionRepository();
    final controller = _controller(
      catalog: _MemoryCatalogRepository(
        CatalogSnapshot(items: const [], pendingItems: pendingItems),
      ),
      mediaStorage: mediaStorage,
      recognition: recognition,
    );

    await controller.initialize();
    await _waitUntil(
      () => controller.pendingQueue.every(
        (item) => item.queueState == QueueRecognitionState.ready,
      ),
    );

    expect(recognition.maximumConcurrentRequests, 4);
    expect(recognition.completedRequests, 10);
  });
}

AppController _controller({
  required _MemoryCatalogRepository catalog,
  required MediaStorageService mediaStorage,
  required RecognitionRepository recognition,
  _MemorySettingsRepository? settings,
}) {
  return AppController(
    settingsRepository: settings ?? _MemorySettingsRepository(),
    catalogRepository: catalog,
    recognitionRepository: recognition,
    tokenUsageRepository: _MemoryTokenUsageRepository(),
    pdfExportService: PdfExportService(mediaStorage),
    excelExportService: ExcelExportService(mediaStorage),
    markdownExportService: MarkdownExportService(mediaStorage),
    localFileSaveService: LocalFileSaveService(),
    mediaStorageService: mediaStorage,
  );
}

ItemRecord _item({
  required String id,
  required String imagePath,
  required QueueRecognitionState queueState,
}) {
  final now = DateTime.parse('2026-07-28T12:00:00Z');
  return ItemRecord(
    id: id,
    name: '待识别物品',
    category: '待分类',
    quantity: 1,
    status: ItemStatus.pending,
    imagePath: imagePath,
    description: '正在后台识别',
    parameters: const {'识别状态': '识别中'},
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

List<int> _jpeg({
  int width = 640,
  int height = 480,
  int red = 80,
  int green = 160,
  int blue = 100,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(red, green, blue));
  return img.encodeJpg(image);
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met before timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _MemoryCatalogRepository implements CatalogRepository {
  _MemoryCatalogRepository(this.snapshot);

  CatalogSnapshot snapshot;
  bool failNextSave = false;
  final List<CatalogSnapshot> savedSnapshots = [];

  @override
  Future<CatalogSnapshot> loadCatalog() async => snapshot;

  @override
  Future<void> saveCatalog(CatalogSnapshot snapshot) async {
    if (failNextSave) {
      failNextSave = false;
      throw const FileSystemException('simulated save failure');
    }
    this.snapshot = CatalogSnapshot(
      items: [...snapshot.items],
      pendingItems: [...snapshot.pendingItems],
    );
    savedSnapshots.add(this.snapshot);
  }
}

class _MemorySettingsRepository implements SettingsRepository {
  AppSettingsStore store = AppSettingsStore.initial();
  bool failNextSave = false;

  @override
  Future<AppSettingsStore> loadSettingsStore() async => store;

  @override
  Future<void> saveSettingsStore(AppSettingsStore store) async {
    if (failNextSave) {
      failNextSave = false;
      throw Exception('simulated settings failure');
    }
    this.store = store;
  }
}

class _MemoryTokenUsageRepository implements TokenUsageRepository {
  Map<String, TokenUsageStats> stats = {};

  @override
  Future<Map<String, TokenUsageStats>> loadUsageStats() async => stats;

  @override
  Future<void> saveUsageStats(
    Map<String, TokenUsageStats> statsByProfileId,
  ) async {
    stats = {...statsByProfileId};
  }
}

class _NeverRecognitionRepository implements RecognitionRepository {
  final Completer<RecognitionResult> _completer = Completer();

  @override
  Future<RecognitionResult> recognizeItem({
    required AppSettings settings,
    required List<int> imageBytes,
    required String mimeType,
  }) {
    return _completer.future;
  }

  @override
  Future<void> testConnection(AppSettings settings) async {}
}

class _ImmediateRecognitionRepository implements RecognitionRepository {
  @override
  Future<RecognitionResult> recognizeItem({
    required AppSettings settings,
    required List<int> imageBytes,
    required String mimeType,
  }) async {
    return const RecognitionResult(
      name: '测试物品',
      category: '杂物',
      quantity: 1,
      description: '测试识别结果',
      parameters: {},
      room: '',
      box: '',
      brand: '',
      model: '',
      color: '',
      material: '',
      notes: '',
      status: ItemStatus.pending,
      rawResponse: '',
      promptTokens: 1,
      completionTokens: 1,
      totalTokens: 2,
    );
  }

  @override
  Future<void> testConnection(AppSettings settings) async {}
}

class _DelayedRecognitionRepository extends _ImmediateRecognitionRepository {
  int _activeRequests = 0;
  int maximumConcurrentRequests = 0;
  int completedRequests = 0;

  @override
  Future<RecognitionResult> recognizeItem({
    required AppSettings settings,
    required List<int> imageBytes,
    required String mimeType,
  }) async {
    _activeRequests++;
    if (_activeRequests > maximumConcurrentRequests) {
      maximumConcurrentRequests = _activeRequests;
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    _activeRequests--;
    completedRequests++;
    return super.recognizeItem(
      settings: settings,
      imageBytes: imageBytes,
      mimeType: mimeType,
    );
  }
}
