import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/entities/item_record.dart';
import '../../domain/repositories/catalog_repository.dart';

typedef DocumentsDirectoryProvider = Future<Directory> Function();

class LocalCatalogRepository implements CatalogRepository {
  LocalCatalogRepository({
    DocumentsDirectoryProvider? documentsDirectoryProvider,
  }) : _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory;

  static const _schemaVersion = 1;
  static const _catalogFileName = 'catalog.json';
  static const _backupSuffix = '.backup';

  final DocumentsDirectoryProvider _documentsDirectoryProvider;
  Future<void> _mutation = Future.value();

  @override
  Future<CatalogSnapshot> loadCatalog() {
    return _serialize(() async {
      final primary = await _catalogFile();
      final backup = File('${primary.path}$_backupSuffix');
      final primaryResult = await _tryReadSnapshot(primary);
      if (primaryResult != null) {
        return primaryResult;
      }

      final backupResult = await _tryReadSnapshot(backup);
      if (backupResult != null) {
        await _quarantineCorruptFile(primary);
        await _writeSnapshot(primary, backupResult, preserveBackup: false);
        return backupResult;
      }

      final migrated = await _loadLegacySnapshot(primary.parent);
      await _quarantineCorruptFile(primary);
      await _quarantineCorruptFile(backup);
      await _writeSnapshot(primary, migrated, preserveBackup: false);
      await _archiveLegacyFiles(primary.parent);
      return migrated;
    });
  }

  @override
  Future<void> saveCatalog(CatalogSnapshot snapshot) {
    return _serialize(() async {
      final target = await _catalogFile();
      await _writeSnapshot(target, snapshot);
    });
  }

  Future<File> _catalogFile() async {
    final root = await _documentsDirectoryProvider();
    await root.create(recursive: true);
    return File('${root.path}${Platform.pathSeparator}$_catalogFileName');
  }

  Future<CatalogSnapshot?> _tryReadSnapshot(File file) async {
    try {
      if (!await file.exists()) {
        return null;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return null;
      }
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final schemaVersion = decoded['schemaVersion'];
      if (schemaVersion is int && schemaVersion > _schemaVersion) {
        throw UnsupportedError('本地目录来自更高版本的物见，请升级应用后再试');
      }
      if (schemaVersion != _schemaVersion ||
          decoded['items'] is! List<dynamic> ||
          decoded['pendingItems'] is! List<dynamic>) {
        throw const FormatException('本地目录结构无效');
      }
      final items = _decodeItems(decoded['items']);
      final pendingItems = _decodeItems(decoded['pendingItems']);
      return CatalogSnapshot(items: items, pendingItems: pendingItems);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  List<ItemRecord> _decodeItems(dynamic rawItems) {
    final entries = rawItems as List<dynamic>? ?? const [];
    return entries
        .map((entry) => ItemRecord.fromJson(entry as Map<String, dynamic>))
        .toList();
  }

  Future<CatalogSnapshot> _loadLegacySnapshot(Directory root) async {
    final items = await _loadLegacyItems(
      File('${root.path}${Platform.pathSeparator}items.json'),
    );
    final pendingItems = await _loadLegacyItems(
      File('${root.path}${Platform.pathSeparator}pending_items.json'),
    );
    return CatalogSnapshot(items: items, pendingItems: pendingItems);
  }

  Future<List<ItemRecord>> _loadLegacyItems(File file) async {
    try {
      if (!await file.exists()) {
        return const [];
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const [];
      }
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((entry) => ItemRecord.fromJson(entry as Map<String, dynamic>))
          .toList();
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  Future<void> _writeSnapshot(
    File target,
    CatalogSnapshot snapshot, {
    bool preserveBackup = true,
  }) async {
    await target.parent.create(recursive: true);
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final temporary = File('${target.path}.tmp-$nonce');
    final backup = File('${target.path}$_backupSuffix');
    final backupTemporary = File('${backup.path}.tmp-$nonce');
    final payload = jsonEncode({
      'schemaVersion': _schemaVersion,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'items': snapshot.items.map((item) => item.toJson()).toList(),
      'pendingItems': snapshot.pendingItems
          .map((item) => item.toJson())
          .toList(),
    });

    try {
      await temporary.writeAsString(payload, flush: true);
      final verified = await _tryReadSnapshot(temporary);
      if (verified == null) {
        throw const FormatException('本地目录数据写入校验失败');
      }

      if (preserveBackup && await target.exists()) {
        await target.copy(backupTemporary.path);
        if (await backup.exists()) {
          await backup.delete();
        }
        await backupTemporary.rename(backup.path);
      }

      try {
        await temporary.rename(target.path);
      } on FileSystemException {
        if (await target.exists()) {
          await target.delete();
        }
        await temporary.rename(target.path);
      }
      await _refreshBackupBestEffort(target, backup, backupTemporary);
    } finally {
      for (final file in [temporary, backupTemporary]) {
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
  }

  Future<void> _quarantineCorruptFile(File file) async {
    if (!await file.exists()) {
      return;
    }
    final quarantine = File(
      '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
    );
    try {
      await file.rename(quarantine.path);
    } on FileSystemException {
      // Keep the original in place if it cannot be quarantined.
    }
  }

  Future<void> _refreshBackupBestEffort(
    File target,
    File backup,
    File backupTemporary,
  ) async {
    try {
      await target.copy(backupTemporary.path);
      if (await backup.exists()) {
        await backup.delete();
      }
      await backupTemporary.rename(backup.path);
    } on FileSystemException {
      if (await backupTemporary.exists()) {
        await backupTemporary.delete();
      }
    }
  }

  Future<void> _archiveLegacyFiles(Directory root) async {
    for (final fileName in ['items.json', 'pending_items.json']) {
      final file = File('${root.path}${Platform.pathSeparator}$fileName');
      if (!await file.exists()) {
        continue;
      }
      final archived = File('${file.path}.migrated');
      try {
        if (await archived.exists()) {
          await archived.delete();
        }
        await file.rename(archived.path);
      } on FileSystemException {
        // Migration has already succeeded; retaining a legacy copy is harmless.
      }
    }
  }

  Future<T> _serialize<T>(Future<T> Function() action) async {
    final previous = _mutation;
    final gate = Completer<void>();
    _mutation = gate.future;
    await previous.catchError((_) {});
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }
}
