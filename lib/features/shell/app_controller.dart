import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/app_settings.dart';
import '../../domain/entities/app_settings_profile.dart';
import '../../domain/entities/app_settings_store.dart';
import '../../domain/entities/item_record.dart';
import '../../domain/entities/recognition_result.dart';
import '../../domain/repositories/item_repository.dart';
import '../../domain/repositories/pending_queue_repository.dart';
import '../../domain/repositories/recognition_repository.dart';
import '../../domain/repositories/settings_repository.dart';

class AppController extends ChangeNotifier {
  AppController({
    required SettingsRepository settingsRepository,
    required ItemRepository itemRepository,
    required PendingQueueRepository pendingQueueRepository,
    required RecognitionRepository recognitionRepository,
  }) : _settingsRepository = settingsRepository,
       _itemRepository = itemRepository,
       _pendingQueueRepository = pendingQueueRepository,
       _recognitionRepository = recognitionRepository;

  final SettingsRepository _settingsRepository;
  final ItemRepository _itemRepository;
  final PendingQueueRepository _pendingQueueRepository;
  final RecognitionRepository _recognitionRepository;
  final ImagePicker _picker = ImagePicker();

  AppSettingsStore _settingsStore = AppSettingsStore.initial();
  List<ItemRecord> _items = const [];
  List<ItemRecord> _pendingQueue = const [];
  int _currentIndex = 0;
  bool _isReady = false;
  bool _isBusy = false;
  bool _isContinuousCapturing = false;
  String? _message;
  File? _latestImage;

  AppSettings get settings => _settingsStore.activeProfile.settings;
  AppSettingsProfile get activeProfile => _settingsStore.activeProfile;
  List<AppSettingsProfile> get profiles => _settingsStore.profiles;
  List<ItemRecord> get items => _items;
  List<ItemRecord> get pendingQueue => _pendingQueue;
  int get currentIndex => _currentIndex;
  bool get isReady => _isReady;
  bool get isBusy => _isBusy;
  bool get isContinuousCapturing => _isContinuousCapturing;
  String? get message => _message;
  File? get latestImage => _latestImage;

  Future<void> initialize() async {
    _settingsStore = await _settingsRepository.loadSettingsStore();
    _items = await _itemRepository.loadItems();
    _pendingQueue = await _pendingQueueRepository.loadPendingItems();
    _isReady = true;
    notifyListeners();
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

  Future<ItemRecord?> captureAndRecognizeSingle() async {
    final photo = await _pickPhoto();
    if (photo == null) {
      return null;
    }

    return _recognizeDraftFromPhoto(photo);
  }

  Future<void> captureToQueue() async {
    final draft = await captureAndRecognizeSingle();
    if (draft == null) {
      return;
    }
    await enqueuePendingItem(draft);
    _message = '已加入待确认队列';
    notifyListeners();
  }

  Future<void> startContinuousCapture() async {
    if (_isContinuousCapturing) {
      return;
    }

    _isContinuousCapturing = true;
    _message = null;
    notifyListeners();

    var capturedCount = 0;
    try {
      while (true) {
        final photo = await _pickPhoto();
        if (photo == null) {
          break;
        }
        final draft = await _recognizeDraftFromPhoto(photo);
        if (draft == null) {
          continue;
        }
        await enqueuePendingItem(draft, notify: false);
        capturedCount++;
      }
      _message = capturedCount == 0
          ? '已结束连续拍照'
          : '连续拍照完成，新增 $capturedCount 条待确认记录';
    } catch (error) {
      _message = error.toString().replaceFirst('Exception: ', '');
    } finally {
      _isContinuousCapturing = false;
      notifyListeners();
    }
  }

  Future<void> enqueuePendingItem(ItemRecord item, {bool notify = true}) async {
    _pendingQueue = [
      item,
      ..._pendingQueue.where((entry) => entry.id != item.id),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _pendingQueueRepository.savePendingItems(_pendingQueue);
    if (notify) {
      notifyListeners();
    }
  }

  Future<void> removePendingItem(String id) async {
    _pendingQueue = _pendingQueue.where((entry) => entry.id != id).toList();
    await _pendingQueueRepository.savePendingItems(_pendingQueue);
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
    _message = '物品已确认并入库';
    notifyListeners();
  }

  Future<void> saveItem(ItemRecord item) async {
    _items = [item, ..._items.where((entry) => entry.id != item.id)]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _itemRepository.saveItems(_items);
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

  void clearMessage() {
    _message = null;
    notifyListeners();
  }

  Future<XFile?> _pickPhoto() async {
    XFile? photo;
    await _runBusy(() async {
      photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 88,
        maxWidth: 1800,
      );
    }, keepBusyState: true);
    return photo;
  }

  Future<ItemRecord?> _recognizeDraftFromPhoto(XFile photo) async {
    final imageFile = await _persistImage(File(photo.path));
    _latestImage = imageFile;
    notifyListeners();

    ItemRecord? draft;
    await _runBusy(() async {
      final bytes = await imageFile.readAsBytes();
      final recognition = await _recognitionRepository.recognizeItem(
        settings: settings,
        imageBytes: bytes,
        mimeType: _detectMimeType(imageFile.path),
      );
      draft = _createDraft(recognition, imageFile.path);
      _message = settings.isConfigured ? '识别完成' : '尚未配置 API，已生成待确认记录';
    }, keepBusyState: true);
    return draft;
  }

  ItemRecord _createDraft(RecognitionResult recognition, String imagePath) {
    final now = DateTime.now();
    return recognition.toItem(
      id: now.microsecondsSinceEpoch.toString(),
      imagePath: imagePath,
      now: now,
    );
  }

  Future<File> _persistImage(File source) async {
    final root = await getApplicationDocumentsDirectory();
    final folder = Directory('${root.path}${Platform.pathSeparator}images');
    await folder.create(recursive: true);
    final target = File(
      '${folder.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    return source.copy(target.path);
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
