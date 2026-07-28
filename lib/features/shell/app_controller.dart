import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/services/excel_export_service.dart';
import '../../data/services/local_file_save_service.dart';
import '../../data/services/markdown_export_service.dart';
import '../../data/services/media_storage_service.dart';
import '../../data/services/pdf_export_service.dart';
import '../../domain/entities/app_settings.dart';
import '../../domain/entities/app_settings_profile.dart';
import '../../domain/entities/app_settings_store.dart';
import '../../domain/entities/export_format.dart';
import '../../domain/entities/export_grouping.dart';
import '../../domain/entities/item_record.dart';
import '../../domain/entities/recognition_result.dart';
import '../../domain/entities/storage_usage_summary.dart';
import '../../domain/entities/token_usage_stats.dart';
import '../../domain/repositories/catalog_repository.dart';
import '../../domain/repositories/recognition_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/repositories/token_usage_repository.dart';

class AppController extends ChangeNotifier {
  AppController({
    required SettingsRepository settingsRepository,
    required CatalogRepository catalogRepository,
    required RecognitionRepository recognitionRepository,
    required TokenUsageRepository tokenUsageRepository,
    required PdfExportService pdfExportService,
    required ExcelExportService excelExportService,
    required MarkdownExportService markdownExportService,
    required LocalFileSaveService localFileSaveService,
    required MediaStorageService mediaStorageService,
  }) : _settingsRepository = settingsRepository,
       _catalogRepository = catalogRepository,
       _recognitionRepository = recognitionRepository,
       _tokenUsageRepository = tokenUsageRepository,
       _pdfExportService = pdfExportService,
       _excelExportService = excelExportService,
       _markdownExportService = markdownExportService,
       _localFileSaveService = localFileSaveService,
       _mediaStorageService = mediaStorageService;

  final SettingsRepository _settingsRepository;
  final CatalogRepository _catalogRepository;
  final RecognitionRepository _recognitionRepository;
  final TokenUsageRepository _tokenUsageRepository;
  final PdfExportService _pdfExportService;
  final ExcelExportService _excelExportService;
  final MarkdownExportService _markdownExportService;
  final LocalFileSaveService _localFileSaveService;
  final MediaStorageService _mediaStorageService;

  AppSettingsStore _settingsStore = AppSettingsStore.initial();
  List<ItemRecord> _items = const [];
  List<ItemRecord> _pendingQueue = const [];
  Map<String, TokenUsageStats> _usageStatsByProfileId = {};
  StorageUsageSummary _storageUsage = const StorageUsageSummary.empty();
  int _currentIndex = 0;
  bool _isReady = false;
  bool _isBusy = false;
  bool _isProcessingQueue = false;
  Future<void> _catalogMutation = Future.value();
  Future<void> _usageMutation = Future.value();
  String? _message;
  File? _latestImage;
  String? _activeCaptureBox;

  AppSettings get settings => _settingsStore.activeProfile.settings;
  AppSettingsProfile get activeProfile => _settingsStore.activeProfile;
  List<AppSettingsProfile> get profiles => _settingsStore.profiles;
  List<ItemRecord> get items => _items;
  List<ItemRecord> get pendingQueue => _pendingQueue;
  StorageUsageSummary get storageUsage => _storageUsage;
  int get currentIndex => _currentIndex;
  bool get isReady => _isReady;
  bool get isBusy => _isBusy;
  bool get isProcessingQueue => _isProcessingQueue;
  String? get message => _message;
  File? get latestImage => _latestImage;
  String? get activeCaptureBox => _activeCaptureBox;
  TokenUsageStats get activeUsageStats =>
      _usageStatsByProfileId[activeProfile.id] ?? TokenUsageStats.empty();
  TokenUsageStats get overallUsageStats {
    var requestCount = 0;
    var promptTokens = 0;
    var completionTokens = 0;
    var totalTokens = 0;
    var lastUpdatedAt = '';
    for (final stats in _usageStatsByProfileId.values) {
      requestCount += stats.requestCount;
      promptTokens += stats.promptTokens;
      completionTokens += stats.completionTokens;
      totalTokens += stats.totalTokens;
      if (stats.lastUpdatedAt.compareTo(lastUpdatedAt) > 0) {
        lastUpdatedAt = stats.lastUpdatedAt;
      }
    }
    return TokenUsageStats(
      requestCount: requestCount,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
      lastUpdatedAt: lastUpdatedAt,
    );
  }

  Future<void> initialize() async {
    _settingsStore = await _settingsRepository.loadSettingsStore();
    final catalog = await _catalogRepository.loadCatalog();
    _items = [...catalog.items]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final hadInterruptedItems = catalog.pendingItems.any(
      (item) => item.queueState == QueueRecognitionState.processing,
    );
    _pendingQueue = _restoreInterruptedQueue(catalog.pendingItems)
      ..sort(_comparePendingItems);
    if (hadInterruptedItems) {
      await _saveCatalog();
    }
    _usageStatsByProfileId = await _tokenUsageRepository.loadUsageStats();
    await _refreshStorageUsage();
    _isReady = true;
    notifyListeners();
    unawaited(optimizeStorage(silent: true));
    unawaited(_processPendingQueue());
  }

  void setCurrentIndex(int value) {
    _currentIndex = value;
    notifyListeners();
  }

  Future<void> saveProfile({
    required String profileName,
    required AppSettings settings,
    String? profileId,
  }) async {
    final resolvedId =
        profileId ?? DateTime.now().microsecondsSinceEpoch.toString();
    final profile = AppSettingsProfile(
      id: resolvedId,
      name: profileName.trim().isEmpty ? '未命名配置' : profileName.trim(),
      settings: settings,
    );

    final profiles = [
      for (final entry in _settingsStore.profiles)
        if (entry.id != resolvedId) entry,
      profile,
    ]..sort((a, b) => a.id.compareTo(b.id));

    final nextStore = _settingsStore.copyWith(
      activeProfileId: resolvedId,
      profiles: profiles,
    );
    await _saveSettingsMutation(nextStore, successMessage: '配置已保存');
  }

  Future<void> selectProfile(String profileId) async {
    if (!_settingsStore.profiles.any((profile) => profile.id == profileId)) {
      return;
    }
    await _saveSettingsMutation(
      _settingsStore.copyWith(activeProfileId: profileId),
    );
  }

  Future<void> deleteProfile(String profileId) async {
    if (_settingsStore.profiles.length == 1) {
      _message = '至少保留一个配置';
      notifyListeners();
      return;
    }

    final profiles = _settingsStore.profiles
        .where((profile) => profile.id != profileId)
        .toList();
    final nextActiveId = _settingsStore.activeProfileId == profileId
        ? profiles.first.id
        : _settingsStore.activeProfileId;

    final nextStore = _settingsStore.copyWith(
      activeProfileId: nextActiveId,
      profiles: profiles,
    );
    await _saveSettingsMutation(nextStore, successMessage: '配置已删除');
  }

  Future<void> testConnection() async {
    await _runBusy(() async {
      await _recognitionRepository.testConnection(settings);
      _message = '连接测试成功';
    });
  }

  Future<void> exportItems({
    required List<ItemRecord> items,
    required ExportGrouping grouping,
    required ExportFormat format,
    required ExportDestination destination,
    Rect? sharePositionOrigin,
  }) async {
    if (items.isEmpty) {
      _message = '当前没有可导出的物品';
      notifyListeners();
      return;
    }

    await _runBusy(() async {
      final file = switch (format) {
        ExportFormat.pdf => await _pdfExportService.exportItems(
          items: items,
          grouping: grouping,
        ),
        ExportFormat.excel => await _excelExportService.exportItems(
          items: items,
          grouping: grouping,
        ),
        ExportFormat.markdown => await _markdownExportService.exportItems(
          items: items,
          grouping: grouping,
        ),
      };

      await _refreshStorageUsage();
      if (destination == ExportDestination.share) {
        _message = '${format.label} 已导出';
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path)],
            text: '物见导出清单 · ${format.label} · ${grouping.label}',
            subject: '物见导出清单',
            sharePositionOrigin: sharePositionOrigin,
          ),
        );
        return;
      }

      final saved = await _localFileSaveService.saveFile(
        file,
        mimeType: _localFileSaveService.mimeTypeFor(file),
      );
      _message = saved ? '${format.label} 已保存到本地' : '已取消保存';
    });
  }

  Future<void> deleteItemsById(Set<String> ids) async {
    if (ids.isEmpty) {
      return;
    }

    await _runBusy(() async {
      await _mutateCatalog(() async {
        _items = _items.where((item) => !ids.contains(item.id)).toList();
        await _saveCatalog();
        await _mediaStorageService.optimizeStorage(
          referencedImagePaths: _allReferencedImagePaths(),
        );
        await _refreshStorageUsage();
        _message = '已删除 ${ids.length} 件物品';
      });
    });
  }

  Future<bool> queueCapturedFile(File photo, {String? box}) async {
    final previousLatestImage = _latestImage;
    try {
      final queued = await _mutateCatalog(() async {
        final draft = await _createQueuedDraft(photo, box: box);
        final duplicate = _allReferencedImagePaths().contains(draft.imagePath);
        if (duplicate) {
          _message = '这张照片已经加入过队列';
          return false;
        }
        _pendingQueue = [
          draft,
          ..._pendingQueue.where((entry) => entry.id != draft.id),
        ]..sort(_comparePendingItems);
        await _saveCatalog();
        await _refreshStorageUsage();
        return true;
      });
      if (!queued) {
        notifyListeners();
        return false;
      }
      _message = '已加入后台识别队列';
      notifyListeners();
      unawaited(_processPendingQueue());
      return true;
    } catch (error) {
      _latestImage = previousLatestImage;
      try {
        await _mediaStorageService.optimizeStorage(
          referencedImagePaths: _allReferencedImagePaths(),
        );
        await _refreshStorageUsage();
      } catch (_) {
        // Keep the original failure visible; a later optimization can retry.
      }
      _message = error.toString().replaceFirst('Exception: ', '');
      notifyListeners();
      return false;
    }
  }

  Future<void> enqueuePendingItem(ItemRecord item, {bool notify = true}) async {
    await _mutateCatalog(() async {
      _pendingQueue = [
        item,
        ..._pendingQueue.where((entry) => entry.id != item.id),
      ]..sort(_comparePendingItems);
      await _saveCatalog();
      await _refreshStorageUsage();
      if (notify) {
        notifyListeners();
      }
    });
  }

  Future<void> removePendingItem(String id) async {
    await _mutateCatalog(() async {
      _pendingQueue = _pendingQueue.where((entry) => entry.id != id).toList();
      await _saveCatalog();
      await _mediaStorageService.optimizeStorage(
        referencedImagePaths: _allReferencedImagePaths(),
      );
      await _refreshStorageUsage();
      _message = '已移出待确认队列';
      notifyListeners();
    });
  }

  Future<void> confirmPendingItem(ItemRecord item) async {
    await _mutateCatalog(() async {
      _pendingQueue = _pendingQueue
          .where((entry) => entry.id != item.id)
          .toList();
      _items = [item, ..._items.where((entry) => entry.id != item.id)]
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _saveCatalog();
      await _refreshStorageUsage();
      _message = '物品已确认并入库';
      notifyListeners();
    });
  }

  Future<void> retryPendingRecognition(String id) async {
    final index = _pendingQueue.indexWhere((entry) => entry.id == id);
    if (index < 0) {
      return;
    }
    final target = _pendingQueue[index];
    await _replacePendingItem(
      target.copyWith(
        queueState: QueueRecognitionState.queued,
        name: '待识别物品',
        category: '待分类',
        description: '等待后台识别',
        brand: '',
        model: '',
        color: '',
        material: '',
        notes: '',
        recognitionError: '',
        parameters: {
          if (target.box.trim().isNotEmpty) '来源箱号': target.box.trim(),
          '识别状态': '排队中',
        },
        updatedAt: DateTime.now(),
      ),
    );
    _message = '已重新加入识别队列';
    notifyListeners();
    unawaited(_processPendingQueue());
  }

  Future<void> confirmAllReadyPendingItems() async {
    final readyItems = _pendingQueue
        .where((item) => item.queueState == QueueRecognitionState.ready)
        .toList();
    if (readyItems.isEmpty) {
      return;
    }
    await _mutateCatalog(() async {
      final readyIds = readyItems.map((item) => item.id).toSet();
      _pendingQueue = _pendingQueue
          .where((entry) => !readyIds.contains(entry.id))
          .toList();
      for (final item in readyItems) {
        final confirmed = item.copyWith(
          queueState: QueueRecognitionState.ready,
          recognitionError: '',
          updatedAt: DateTime.now(),
        );
        _items = [
          confirmed,
          ..._items.where((entry) => entry.id != confirmed.id),
        ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      }
      await _saveCatalog();
      await _refreshStorageUsage();
      _message = '已批量添加 ${readyItems.length} 项';
      notifyListeners();
    });
  }

  Future<void> retryAllFailedPendingItems() async {
    final failedItems = _pendingQueue
        .where((item) => item.queueState == QueueRecognitionState.failed)
        .toList();
    if (failedItems.isEmpty) {
      return;
    }
    await _mutateCatalog(() async {
      final failedIds = failedItems.map((item) => item.id).toSet();
      _pendingQueue = _pendingQueue.map((item) {
        if (!failedIds.contains(item.id)) {
          return item;
        }
        return item.copyWith(
          queueState: QueueRecognitionState.queued,
          name: '待识别物品',
          category: '待分类',
          description: '等待后台识别',
          brand: '',
          model: '',
          color: '',
          material: '',
          notes: '',
          recognitionError: '',
          parameters: {
            if (item.box.trim().isNotEmpty) '来源箱号': item.box.trim(),
            '识别状态': '排队中',
          },
          updatedAt: DateTime.now(),
        );
      }).toList()..sort(_comparePendingItems);
      await _saveCatalog();
    });
    _message = '已重新识别 ${failedItems.length} 项';
    notifyListeners();
    unawaited(_processPendingQueue());
  }

  Future<void> saveItem(ItemRecord item) async {
    await _mutateCatalog(() async {
      _items = [item, ..._items.where((entry) => entry.id != item.id)]
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _saveCatalog();
      await _refreshStorageUsage();
      _message = '物品已保存';
      notifyListeners();
    });
  }

  Future<void> updateItem(ItemRecord item) async {
    await _mutateCatalog(() async {
      _items =
          _items.map((entry) => entry.id == item.id ? item : entry).toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      await _saveCatalog();
      _message = '物品已更新';
      notifyListeners();
    });
  }

  Future<void> optimizeStorage({bool silent = false}) async {
    await _runBusy(() async {
      await _migrateLegacyImages();
      await _mutateCatalog(() async {
        await _mediaStorageService.optimizeStorage(
          referencedImagePaths: _allReferencedImagePaths(),
        );
        await _refreshStorageUsage();
        if (!silent) {
          _message = '已完成存储优化';
        }
      });
    }, keepBusyState: silent);
  }

  Future<void> clearTransientCache() async {
    await _runBusy(() async {
      await _mutateCatalog(() async {
        await _mediaStorageService.clearTransientCache();
        await _refreshStorageUsage();
        _message = '已清理临时缓存';
      });
    });
  }

  void clearMessage() {
    _message = null;
    notifyListeners();
  }

  void setActiveCaptureBox(String? box) {
    final normalized = box?.trim();
    _activeCaptureBox = normalized == null || normalized.isEmpty
        ? null
        : normalized;
    notifyListeners();
  }

  Future<ItemRecord> _createQueuedDraft(File photo, {String? box}) async {
    final imageFile = await _persistImage(photo);
    _latestImage = imageFile;
    await _refreshStorageUsage();
    notifyListeners();

    final now = DateTime.now();
    final resolvedBox = (box ?? _activeCaptureBox ?? '').trim();
    return ItemRecord(
      id: now.microsecondsSinceEpoch.toString(),
      name: '待识别物品',
      category: '待分类',
      quantity: 1,
      status: ItemStatus.pending,
      imagePath: imageFile.path,
      description: '等待后台识别',
      parameters: const {'识别状态': '排队中'},
      notes: '',
      room: '',
      box: resolvedBox,
      brand: '',
      model: '',
      color: '',
      material: '',
      createdAt: now,
      updatedAt: now,
      queueState: QueueRecognitionState.queued,
      recognitionError: '',
    );
  }

  Future<void> _processPendingQueue() async {
    if (_isProcessingQueue) {
      return;
    }
    _isProcessingQueue = true;
    notifyListeners();

    try {
      while (true) {
        final queuedItems = _pendingQueue
            .where((item) => item.queueState == QueueRecognitionState.queued)
            .take(_pendingQueueConcurrencyLimit())
            .toList();
        if (queuedItems.isEmpty) {
          break;
        }
        await Future.wait(queuedItems.map(_processQueuedItem));
      }
    } finally {
      _isProcessingQueue = false;
      notifyListeners();
    }
  }

  Future<void> _processQueuedItem(ItemRecord queued) async {
    final recognitionSettings = settings;
    final usageProfileId = activeProfile.id;
    try {
      await _replacePendingItem(
        queued.copyWith(
          queueState: QueueRecognitionState.processing,
          description: '正在后台识别',
          parameters: {...queued.parameters, '识别状态': '识别中'},
          updatedAt: DateTime.now(),
        ),
      );
      final stopwatch = Stopwatch()..start();
      final bytes = await File(queued.imagePath).readAsBytes();
      final recognition = await _recognitionRepository.recognizeItem(
        settings: recognitionSettings,
        imageBytes: bytes,
        mimeType: _detectMimeType(queued.imagePath),
      );
      stopwatch.stop();
      await _applyUsage(recognition, usageProfileId);
      final recognized = recognition.toItem(
        id: queued.id,
        imagePath: queued.imagePath,
        now: DateTime.now(),
      );
      await _replacePendingItem(
        recognized.copyWith(
          parameters: {
            ...recognized.parameters,
            '识别用时': _formatRecognitionDuration(stopwatch.elapsed),
          },
          box: queued.box.trim().isEmpty ? recognized.box : queued.box,
          queueState: QueueRecognitionState.ready,
          recognitionError: '',
          updatedAt: DateTime.now(),
        ),
      );
    } catch (error) {
      try {
        await _replacePendingItem(
          queued.copyWith(
            queueState: QueueRecognitionState.failed,
            description: '识别失败，请稍后重试或手动补充',
            recognitionError: error.toString().replaceFirst('Exception: ', ''),
            parameters: {...queued.parameters, '识别状态': '识别失败'},
            updatedAt: DateTime.now(),
          ),
        );
      } catch (persistenceError) {
        _message =
            '识别队列无法保存：${persistenceError.toString().replaceFirst('Exception: ', '')}';
        notifyListeners();
      }
    }
  }

  String _formatRecognitionDuration(Duration duration) {
    if (duration.inSeconds >= 1) {
      final seconds = duration.inMilliseconds / 1000;
      return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)}秒';
    }
    return '${duration.inMilliseconds}毫秒';
  }

  Future<void> _applyUsage(
    RecognitionResult recognition,
    String profileId,
  ) async {
    final previous = _usageMutation;
    final gate = Completer<void>();
    _usageMutation = gate.future;
    await previous.catchError((_) {});
    try {
      final current =
          _usageStatsByProfileId[profileId] ?? TokenUsageStats.empty();
      _usageStatsByProfileId[profileId] = current.add(
        promptTokens: recognition.promptTokens,
        completionTokens: recognition.completionTokens,
        totalTokens: recognition.totalTokens,
      );
      await _tokenUsageRepository.saveUsageStats({..._usageStatsByProfileId});
    } finally {
      gate.complete();
    }
  }

  Future<void> _replacePendingItem(ItemRecord item) async {
    await _mutateCatalog(() async {
      _pendingQueue =
          _pendingQueue
              .map((entry) => entry.id == item.id ? item : entry)
              .toList()
            ..sort(_comparePendingItems);
      await _saveCatalog();
      notifyListeners();
    });
  }

  int _comparePendingItems(ItemRecord left, ItemRecord right) {
    final priorityDiff =
        _pendingQueuePriority(left.queueState) -
        _pendingQueuePriority(right.queueState);
    if (priorityDiff != 0) {
      return priorityDiff;
    }
    return right.updatedAt.compareTo(left.updatedAt);
  }

  int _pendingQueuePriority(QueueRecognitionState state) {
    return switch (state) {
      QueueRecognitionState.ready => 0,
      QueueRecognitionState.processing => 1,
      QueueRecognitionState.queued => 2,
      QueueRecognitionState.failed => 3,
    };
  }

  int _pendingQueueConcurrencyLimit() {
    return switch (settings.providerId) {
      'volcengine' => 4,
      'xiaomi-payg' => 1,
      'xiaomi-token-plan' => 1,
      _ => 2,
    };
  }

  Future<T> _mutateCatalog<T>(Future<T> Function() action) async {
    final previous = _catalogMutation;
    final gate = Completer<void>();
    _catalogMutation = gate.future;
    await previous.catchError((_) {});
    final previousItems = _items;
    final previousPendingQueue = _pendingQueue;
    try {
      return await action();
    } catch (_) {
      _items = previousItems;
      _pendingQueue = previousPendingQueue;
      rethrow;
    } finally {
      gate.complete();
    }
  }

  Future<void> _saveCatalog() {
    return _catalogRepository.saveCatalog(
      CatalogSnapshot(items: _items, pendingItems: _pendingQueue),
    );
  }

  List<ItemRecord> _restoreInterruptedQueue(List<ItemRecord> items) {
    return items.map((item) {
      if (item.queueState != QueueRecognitionState.processing) {
        return item;
      }
      return item.copyWith(
        queueState: QueueRecognitionState.queued,
        description: '上次识别被中断，已自动重新排队',
        recognitionError: '',
        parameters: {...item.parameters, '识别状态': '排队中'},
        updatedAt: DateTime.now(),
      );
    }).toList();
  }

  Future<File> _persistImage(File source) async {
    return _mediaStorageService.persistImage(source);
  }

  Future<void> _migrateLegacyImages() async {
    final legacyPaths = _allReferencedImagePaths()
        .where((path) => !_isContentAddressedImage(path))
        .toSet()
        .toList();
    for (final legacyPath in legacyPaths) {
      final source = File(legacyPath);
      if (!await source.exists()) {
        continue;
      }
      await _mutateCatalog(() async {
        if (!_allReferencedImagePaths().contains(legacyPath)) {
          return;
        }
        final normalized = await _persistImage(source);
        _items = _items
            .map(
              (item) => item.imagePath == legacyPath
                  ? item.copyWith(imagePath: normalized.path)
                  : item,
            )
            .toList();
        _pendingQueue = _pendingQueue
            .map(
              (item) => item.imagePath == legacyPath
                  ? item.copyWith(imagePath: normalized.path)
                  : item,
            )
            .toList();
        if (_latestImage?.path == legacyPath) {
          _latestImage = normalized;
        }
        await _saveCatalog();
      });
    }
  }

  bool _isContentAddressedImage(String path) {
    final normalized = path.replaceAll('\\', '/');
    final fileName = normalized.substring(normalized.lastIndexOf('/') + 1);
    return RegExp(r'^[0-9a-f]{64}\.jpg$').hasMatch(fileName);
  }

  Future<void> _refreshStorageUsage() async {
    _storageUsage = await _mediaStorageService.computeUsage();
  }

  Iterable<String> _allReferencedImagePaths() sync* {
    for (final item in _items) {
      yield item.imagePath;
    }
    for (final item in _pendingQueue) {
      yield item.imagePath;
    }
  }

  String _detectMimeType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  Future<void> _saveSettingsMutation(
    AppSettingsStore nextStore, {
    String? successMessage,
  }) async {
    final previousStore = _settingsStore;
    _settingsStore = nextStore;
    try {
      await _settingsRepository.saveSettingsStore(nextStore);
      _message = successMessage;
    } catch (error) {
      _settingsStore = previousStore;
      _message = error.toString().replaceFirst('Exception: ', '');
    }
    notifyListeners();
  }

  Future<void> _runBusy(
    Future<void> Function() action, {
    bool keepBusyState = false,
  }) async {
    _isBusy = true;
    if (!keepBusyState) {
      _message = null;
    }
    notifyListeners();
    try {
      await action();
    } catch (error) {
      _message = error.toString().replaceFirst('Exception: ', '');
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }
}

enum ExportDestination { share, save }
