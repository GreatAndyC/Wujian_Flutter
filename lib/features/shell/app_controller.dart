import 'dart:async';
import 'dart:io';

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
import '../../domain/repositories/item_repository.dart';
import '../../domain/repositories/pending_queue_repository.dart';
import '../../domain/repositories/recognition_repository.dart';
import '../../domain/repositories/settings_repository.dart';
import '../../domain/repositories/token_usage_repository.dart';

class AppController extends ChangeNotifier {
  AppController({
    required SettingsRepository settingsRepository,
    required ItemRepository itemRepository,
    required PendingQueueRepository pendingQueueRepository,
    required RecognitionRepository recognitionRepository,
    required TokenUsageRepository tokenUsageRepository,
    required PdfExportService pdfExportService,
    required ExcelExportService excelExportService,
    required MarkdownExportService markdownExportService,
    required LocalFileSaveService localFileSaveService,
    required MediaStorageService mediaStorageService,
  }) : _settingsRepository = settingsRepository,
       _itemRepository = itemRepository,
       _pendingQueueRepository = pendingQueueRepository,
       _recognitionRepository = recognitionRepository,
       _tokenUsageRepository = tokenUsageRepository,
       _pdfExportService = pdfExportService,
       _excelExportService = excelExportService,
       _markdownExportService = markdownExportService,
       _localFileSaveService = localFileSaveService,
       _mediaStorageService = mediaStorageService;

  final SettingsRepository _settingsRepository;
  final ItemRepository _itemRepository;
  final PendingQueueRepository _pendingQueueRepository;
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
  String? _message;
  File? _latestImage;

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
    _items = await _itemRepository.loadItems();
    _pendingQueue = await _pendingQueueRepository.loadPendingItems();
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

    _settingsStore = _settingsStore.copyWith(
      activeProfileId: resolvedId,
      profiles: profiles,
    );
    await _settingsRepository.saveSettingsStore(_settingsStore);
    _message = '配置已保存';
    notifyListeners();
  }

  Future<void> selectProfile(String profileId) async {
    if (!_settingsStore.profiles.any((profile) => profile.id == profileId)) {
      return;
    }
    _settingsStore = _settingsStore.copyWith(activeProfileId: profileId);
    await _settingsRepository.saveSettingsStore(_settingsStore);
    notifyListeners();
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

    _settingsStore = _settingsStore.copyWith(
      activeProfileId: nextActiveId,
      profiles: profiles,
    );
    await _settingsRepository.saveSettingsStore(_settingsStore);
    _message = '配置已删除';
    notifyListeners();
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
      _items = _items.where((item) => !ids.contains(item.id)).toList();
      await _itemRepository.saveItems(_items);
      await _mediaStorageService.optimizeStorage(
        referencedImagePaths: _allReferencedImagePaths(),
      );
      await _refreshStorageUsage();
      _message = '已删除 ${ids.length} 件物品';
    });
  }

  Future<void> queueCapturedFile(File photo) async {
    try {
      final draft = await _createQueuedDraft(photo);
      await enqueuePendingItem(draft);
      _message = '已加入后台识别队列';
      notifyListeners();
      unawaited(_processPendingQueue());
    } catch (error) {
      _message = error.toString().replaceFirst('Exception: ', '');
      notifyListeners();
    }
  }

  Future<void> enqueuePendingItem(ItemRecord item, {bool notify = true}) async {
    _pendingQueue = [
      item,
      ..._pendingQueue.where((entry) => entry.id != item.id),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _pendingQueueRepository.savePendingItems(_pendingQueue);
    await _refreshStorageUsage();
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> removePendingItem(String id) async {
    _pendingQueue = _pendingQueue.where((entry) => entry.id != id).toList();
    await _pendingQueueRepository.savePendingItems(_pendingQueue);
    await optimizeStorage(silent: true);
    _message = '已移出待确认队列';
    notifyListeners();
  }

  Future<void> confirmPendingItem(ItemRecord item) async {
    _pendingQueue = _pendingQueue
        .where((entry) => entry.id != item.id)
        .toList();
    _items = [item, ..._items.where((entry) => entry.id != item.id)]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _pendingQueueRepository.savePendingItems(_pendingQueue);
    await _itemRepository.saveItems(_items);
    await _refreshStorageUsage();
    _message = '物品已确认并入库';
    notifyListeners();
  }

  Future<void> saveItem(ItemRecord item) async {
    _items = [item, ..._items.where((entry) => entry.id != item.id)]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _itemRepository.saveItems(_items);
    await _refreshStorageUsage();
    _message = '物品已保存';
    notifyListeners();
  }

  Future<void> updateItem(ItemRecord item) async {
    _items = _items.map((entry) => entry.id == item.id ? item : entry).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _itemRepository.saveItems(_items);
    _message = '物品已更新';
    notifyListeners();
  }

  Future<void> optimizeStorage({bool silent = false}) async {
    await _runBusy(() async {
      await _mediaStorageService.optimizeStorage(
        referencedImagePaths: _allReferencedImagePaths(),
      );
      await _refreshStorageUsage();
      if (!silent) {
        _message = '已完成存储优化';
      }
    }, keepBusyState: silent);
  }

  void clearMessage() {
    _message = null;
    notifyListeners();
  }

  Future<ItemRecord> _createQueuedDraft(File photo) async {
    final imageFile = await _persistImage(photo);
    _latestImage = imageFile;
    await _refreshStorageUsage();
    notifyListeners();

    final now = DateTime.now();
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
      box: '',
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
        final nextIndex = _pendingQueue.indexWhere(
          (item) => item.queueState == QueueRecognitionState.queued,
        );
        if (nextIndex < 0) {
          break;
        }

        final queued = _pendingQueue[nextIndex];
        await _replacePendingItem(
          queued.copyWith(
            queueState: QueueRecognitionState.processing,
            description: '正在后台识别',
            parameters: {...queued.parameters, '识别状态': '识别中'},
            updatedAt: DateTime.now(),
          ),
        );

        try {
          final bytes = await File(queued.imagePath).readAsBytes();
          final recognition = await _recognitionRepository.recognizeItem(
            settings: settings,
            imageBytes: bytes,
            mimeType: _detectMimeType(queued.imagePath),
          );
          _applyUsage(recognition);
          final recognized = recognition.toItem(
            id: queued.id,
            imagePath: queued.imagePath,
            now: DateTime.now(),
          );
          await _replacePendingItem(
            recognized.copyWith(
              queueState: QueueRecognitionState.ready,
              recognitionError: '',
              updatedAt: DateTime.now(),
            ),
          );
        } catch (error) {
          await _replacePendingItem(
            queued.copyWith(
              queueState: QueueRecognitionState.failed,
              description: '识别失败，请稍后重试或手动补充',
              recognitionError: error.toString().replaceFirst(
                'Exception: ',
                '',
              ),
              parameters: {...queued.parameters, '识别状态': '识别失败'},
              updatedAt: DateTime.now(),
            ),
          );
        }
      }
    } finally {
      _isProcessingQueue = false;
      notifyListeners();
    }
  }

  void _applyUsage(RecognitionResult recognition) {
    final profileId = activeProfile.id;
    final current =
        _usageStatsByProfileId[profileId] ?? TokenUsageStats.empty();
    _usageStatsByProfileId[profileId] = current.add(
      promptTokens: recognition.promptTokens,
      completionTokens: recognition.completionTokens,
      totalTokens: recognition.totalTokens,
    );
    unawaited(_tokenUsageRepository.saveUsageStats(_usageStatsByProfileId));
  }

  Future<void> _replacePendingItem(ItemRecord item) async {
    _pendingQueue =
        _pendingQueue
            .map((entry) => entry.id == item.id ? item : entry)
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _pendingQueueRepository.savePendingItems(_pendingQueue);
    notifyListeners();
  }

  Future<File> _persistImage(File source) async {
    return _mediaStorageService.persistImage(source);
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
