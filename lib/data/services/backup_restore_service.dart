import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/backup_restore.dart';
import '../../domain/entities/item_record.dart';
import '../../domain/repositories/catalog_repository.dart';
import 'backup_file_system.dart';
import 'storage_mutation_coordinator.dart';

typedef BackupDirectoryProvider = Future<Directory> Function();
typedef BackupTimestampProvider = DateTime Function();
typedef BackupRestoreFaultInjector =
    FutureOr<void> Function(BackupRestoreFaultPoint point);

/// Stable failure checkpoints used by reliability tests. Production callers
/// leave the injector unset.
enum BackupRestoreFaultPoint {
  beforeArchiveWrite,
  afterArchiveWrite,
  beforeBackupPublish,
  afterRestoreValidation,
  beforeMediaPublish,
  afterMediaPublish,
  beforeCatalogCommit,
}

/// Creates and restores local, self-validating Wujian backup packages.
///
/// A restore validates and extracts the entire package before loading or
/// mutating the active catalog. New media is then durably prepared beside its
/// final destination, atomically published, and finally referenced by one
/// catalog commit. Failures before that commit remove every newly published
/// file and restore the previous catalog if a write was attempted.
class LocalBackupRestoreService implements BackupRestoreOperations {
  LocalBackupRestoreService({
    required CatalogRepository catalogRepository,
    BackupDirectoryProvider? documentsDirectoryProvider,
    BackupFileSystem? fileSystem,
    BackupRestoreLimits limits = const BackupRestoreLimits(),
    BackupTimestampProvider? timestampProvider,
    BackupRestoreFaultInjector? faultInjector,
  }) : _catalogRepository = catalogRepository,
       _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory,
       _fileSystem = fileSystem ?? LocalBackupFileSystem(),
       _limits = limits,
       _timestampProvider = timestampProvider ?? DateTime.now,
       _faultInjector = faultInjector;

  static const _packageName = 'wujian-local-backup';
  static const _formatVersion = 1;
  static const _catalogSchemaVersion = 1;
  static const _manifestPath = 'manifest.json';
  static const _catalogPath = 'data/catalog.json';
  static const _restoreJournalName = '.wujian-restore-journal.json';
  static const _operationLockName = '.wujian-backup-operation.lock';
  static const _workspaceMarkerName = '.wujian-operation.json';
  static const _workspaceCleanupMarkerName = '.wujian-cleanup-pending.json';
  static const _partialOwnerSuffix = '.owner.json';
  static var _globalSequence = 0;

  final CatalogRepository _catalogRepository;
  final BackupDirectoryProvider _documentsDirectoryProvider;
  final BackupFileSystem _fileSystem;
  final BackupRestoreLimits _limits;
  final BackupTimestampProvider _timestampProvider;
  final BackupRestoreFaultInjector? _faultInjector;

  @override
  Future<BackupCreateResult> createBackup({String baseName = 'wujian-backup'}) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(baseName)) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidFileName,
        '备份文件名不安全，请只使用字母、数字、下划线或连字符。',
      );
    }
    return _guarded(
      () => _withRootLock(
        (root) => _createBackupLocked(root, baseName: baseName),
      ),
      fallbackCode: BackupRestoreErrorCode.writeFailed,
      fallbackMessage: '创建备份失败，现有数据未被修改。',
    );
  }

  @override
  Future<BackupPackageInspection> validateBackup(File file) {
    return _guarded(
      () => _withRootLock((root) => _validateBackupLocked(root, file)),
      fallbackCode: BackupRestoreErrorCode.invalidArchive,
      fallbackMessage: '备份包无法读取或结构无效。',
    );
  }

  @override
  Future<BackupRestoreResult> restoreBackup(
    File file, {
    BackupRestoreMode mode = BackupRestoreMode.replace,
  }) {
    return _guarded(
      () =>
          _withRootLock((root) => _restoreBackupLocked(root, file, mode: mode)),
      fallbackCode: BackupRestoreErrorCode.writeFailed,
      fallbackMessage: '恢复失败，现有目录和媒体保持不变。',
    );
  }

  /// Completes cleanup or rollback for a process interruption that happened
  /// after durable restore preparation. Normal backup/validate/restore calls
  /// invoke the same recovery automatically before doing their own work.
  Future<void> recoverInterruptedRestore() {
    return _guarded(
      () => _withRootLock((_) async {}),
      fallbackCode: BackupRestoreErrorCode.rollbackFailed,
      fallbackMessage: '上次中断的恢复无法自动收敛，请保留现场。',
    );
  }

  Future<BackupCreateResult> _createBackupLocked(
    Directory root, {
    required String baseName,
  }) async {
    final backupsDirectory = Directory(_join(root.path, 'backups'));
    // A backup package is always non-empty. Reject an already exhausted
    // retention budget before copying or decoding source media.
    await _ensureBackupStorageCapacity(backupsDirectory, 1);
    final workspace = await _createWorkspace(root, 'create');
    File? partialPackage;
    File? partialOwner;
    try {
      final snapshot = await _catalogRepository.loadCatalog();
      _validateUniqueIds(snapshot);

      final prepared = await _prepareExportSnapshot(root, workspace, snapshot);
      final createdAt = _timestampProvider().toUtc();
      final dataDirectory = Directory(_join(workspace.path, 'data'));
      await dataDirectory.create(recursive: true);
      final catalogFile = File(_join(workspace.path, _catalogPath));
      final catalogPayload = utf8.encode(
        jsonEncode({
          'schemaVersion': _catalogSchemaVersion,
          'items': prepared.snapshot.items
              .map((item) => item.toJson())
              .toList(),
          'pendingItems': prepared.snapshot.pendingItems
              .map((item) => item.toJson())
              .toList(),
        }),
      );
      if (catalogPayload.length > _limits.maxCatalogBytes) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.expandedSizeExceeded,
          '业务数据超过备份包大小限制。',
        );
      }
      await catalogFile.writeAsBytes(catalogPayload, flush: true);
      await _fileSystem.syncFile(catalogFile);
      final catalogHash = sha256.convert(catalogPayload).toString();

      final manifest = <String, dynamic>{
        'package': _packageName,
        'formatVersion': _formatVersion,
        'createdAt': createdAt.toIso8601String(),
        'catalog': <String, dynamic>{
          'path': _catalogPath,
          'schemaVersion': _catalogSchemaVersion,
          'byteLength': catalogPayload.length,
          'sha256': catalogHash,
          'itemCount': prepared.snapshot.items.length,
          'pendingItemCount': prepared.snapshot.pendingItems.length,
        },
        'media': prepared.media
            .map(
              (media) => <String, dynamic>{
                'path': media.entry.path,
                'byteLength': media.entry.byteLength,
                'sha256': media.entry.sha256,
              },
            )
            .toList(),
      };
      final manifestFile = File(_join(workspace.path, _manifestPath));
      final manifestPayload = utf8.encode(jsonEncode(manifest));
      if (manifestPayload.length > _limits.maxCatalogBytes) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.expandedSizeExceeded,
          '备份清单超过大小限制。',
        );
      }
      final estimatedArchiveBytes = _storedZipSize(<String, int>{
        _manifestPath: manifestPayload.length,
        _catalogPath: catalogPayload.length,
        for (final media in prepared.media)
          media.entry.path: media.entry.byteLength,
      });
      if (estimatedArchiveBytes > _limits.maxArchiveBytes) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.expandedSizeExceeded,
          '备份包预计大小超过限制。',
        );
      }
      await manifestFile.writeAsBytes(manifestPayload, flush: true);
      await _fileSystem.syncFile(manifestFile);

      await _requireSafeDirectory(backupsDirectory, create: true);
      await _ensureBackupStorageCapacity(
        backupsDirectory,
        estimatedArchiveBytes,
      );
      final nonce = _nonce();
      final finalPackage = File(
        _join(
          backupsDirectory.path,
          '$baseName-${createdAt.microsecondsSinceEpoch}-$nonce.wujian-backup',
        ),
      );
      partialPackage = File('${finalPackage.path}.partial');
      partialOwner = File('${partialPackage.path}$_partialOwnerSuffix');
      if (await FileSystemEntity.type(
                partialPackage.path,
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound ||
          await FileSystemEntity.type(partialOwner.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.writeFailed,
          '无法分配唯一的备份临时文件。',
        );
      }
      await _writeOwnedMarker(partialOwner, <String, dynamic>{
        'schemaVersion': 1,
        'kind': 'wujian-backup-partial',
        'partialName': _basename(partialPackage.path),
      });

      await _fault(BackupRestoreFaultPoint.beforeArchiveWrite);
      final encoder = ZipFileEncoder();
      var encoderOpen = false;
      try {
        encoder.create(partialPackage.path, level: ZipFileEncoder.STORE);
        encoderOpen = true;
        await encoder.addFile(
          manifestFile,
          _manifestPath,
          ZipFileEncoder.STORE,
        );
        await encoder.addFile(catalogFile, _catalogPath, ZipFileEncoder.STORE);
        for (final media in prepared.media) {
          await encoder.addFile(
            media.file,
            media.entry.path,
            ZipFileEncoder.STORE,
          );
        }
        await encoder.close();
        encoderOpen = false;
      } finally {
        if (encoderOpen) {
          try {
            await encoder.close();
          } catch (_) {
            // The partial file is removed below; preserve the primary error.
          }
        }
      }
      await _fileSystem.syncFile(partialPackage);
      await _fault(BackupRestoreFaultPoint.afterArchiveWrite);

      final validationWorkspace = await _createWorkspace(
        workspace,
        'self-check',
      );
      _ValidatedPackage validated;
      try {
        validated = await _extractAndValidate(
          partialPackage,
          validationWorkspace,
        );
      } finally {
        await _deleteWorkspaceBestEffort(validationWorkspace);
      }
      await _fault(BackupRestoreFaultPoint.beforeBackupPublish);
      final expectedPackageLength = await partialPackage.length();
      final expectedPackageHash = await _hashFile(partialPackage);
      File published;
      try {
        published = await _fileSystem.renameNew(partialPackage, finalPackage);
      } catch (_) {
        // rename can be durably applied even when the platform reports an
        // error afterwards. The source disappearing distinguishes that case
        // from a competing writer creating an identical destination before
        // our rename. Never claim another writer's file as this publication.
        final sourceType = await FileSystemEntity.type(
          partialPackage.path,
          followLinks: false,
        );
        if (sourceType != FileSystemEntityType.notFound ||
            !await _matchesExpectedFile(
              finalPackage,
              expectedPackageLength,
              expectedPackageHash,
            )) {
          rethrow;
        }
        published = finalPackage;
      }
      partialPackage = null;
      await _deleteFileBestEffort(partialOwner);
      partialOwner = null;
      return BackupCreateResult(
        file: published,
        inspection: validated.inspection,
        packageBytes: await published.length(),
      );
    } finally {
      if (partialPackage != null) {
        await _deleteFileBestEffort(partialPackage);
        var partialIsMissing = false;
        try {
          partialIsMissing =
              await FileSystemEntity.type(
                partialPackage.path,
                followLinks: false,
              ) ==
              FileSystemEntityType.notFound;
        } on FileSystemException {
          // Keep the owner marker when absence cannot be proven. The next
          // startup can safely retry both files instead of orphaning a large
          // partial package with no ownership evidence.
        }
        if (partialIsMissing && partialOwner != null) {
          await _deleteFileBestEffort(partialOwner);
        }
      } else if (partialOwner != null) {
        await _deleteFileBestEffort(partialOwner);
      }
      await _deleteWorkspaceBestEffort(workspace);
    }
  }

  Future<BackupPackageInspection> _validateBackupLocked(
    Directory root,
    File file,
  ) async {
    final workspace = await _createWorkspace(root, 'validate');
    try {
      return (await _extractAndValidate(file, workspace)).inspection;
    } finally {
      await _deleteWorkspaceBestEffort(workspace);
    }
  }

  Future<BackupRestoreResult> _restoreBackupLocked(
    Directory root,
    File packageFile, {
    required BackupRestoreMode mode,
  }) async {
    final workspace = await _createWorkspace(root, 'restore');
    final preparedTemporaryFiles = <File>[];
    final preparedPublications = <_PreparedMediaPublication>[];
    final createdMediaFiles = <File>[];
    CatalogSnapshot? previousSnapshot;
    var catalogWriteAttempted = false;
    var catalogCommitted = false;
    var imagesDirectoryCreated = false;
    File? restoreJournal;
    try {
      final validated = await _extractAndValidate(packageFile, workspace);
      await _fault(BackupRestoreFaultPoint.afterRestoreValidation);

      previousSnapshot = await _catalogRepository.loadCatalog();
      _validateUniqueIds(previousSnapshot);

      final imagesDirectory = Directory(_join(root.path, 'images'));
      final imagesType = await FileSystemEntity.type(
        imagesDirectory.path,
        followLinks: false,
      );
      if (imagesType == FileSystemEntityType.link) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.symbolicLink,
          '媒体目录不能是软链接。',
        );
      }
      if (imagesType == FileSystemEntityType.notFound) {
        await imagesDirectory.create(recursive: false);
        imagesDirectoryCreated = true;
      } else if (imagesType != FileSystemEntityType.directory) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.writeFailed,
          '媒体目录不可用。',
        );
      }

      final pathMapping = <String, String>{};
      final mediaPlans = <_RestoreMediaPlan>[];
      for (final media in validated.media.values) {
        final extension = _extensionOf(media.entry.path);
        final target = File(
          _join(
            imagesDirectory.path,
            'backup-${media.entry.sha256}.$extension',
          ),
        );
        pathMapping[media.entry.path] = target.path;
        final targetType = await FileSystemEntity.type(
          target.path,
          followLinks: false,
        );
        if (targetType == FileSystemEntityType.file) {
          await _verifyExistingTarget(target, media.entry);
          continue;
        }
        if (targetType != FileSystemEntityType.notFound) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.symbolicLink,
            '媒体发布目标不是普通文件。',
          );
        }
        mediaPlans.add(_RestoreMediaPlan(media, target));
      }

      final incoming = _rewriteSnapshotPaths(validated.snapshot, pathMapping);
      final nextSnapshot = mode == BackupRestoreMode.replace
          ? incoming
          : _mergeSnapshots(previousSnapshot, incoming);
      _validateUniqueIds(nextSnapshot);

      restoreJournal = await _writeRestoreJournal(
        root,
        previousSnapshot: previousSnapshot,
        nextSnapshot: nextSnapshot,
        plannedMedia: mediaPlans.map((plan) => plan.target).toList(),
      );
      var mediaIndex = 0;
      for (final plan in mediaPlans) {
        final temporary = File(
          _join(
            imagesDirectory.path,
            '.restore-${_nonce()}-${mediaIndex++}.tmp',
          ),
        );
        preparedTemporaryFiles.add(temporary);
        await _fileSystem.copyAndSync(plan.media.file, temporary);
        if (!await _matchesExpectedFile(
          temporary,
          plan.media.entry.byteLength,
          plan.media.entry.sha256,
        )) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.writeFailed,
            '恢复媒体写入后校验失败，现有数据未被修改。',
          );
        }
        preparedPublications.add(
          _PreparedMediaPublication(temporary, plan.target, plan.media.entry),
        );
      }
      await _fault(BackupRestoreFaultPoint.beforeMediaPublish);
      for (final publication in preparedPublications) {
        File published;
        try {
          published = await _fileSystem.renameNew(
            publication.temporary,
            publication.target,
          );
        } catch (_) {
          // A post-rename I/O error is an ambiguous completion. Register an
          // exact, hash-matching destination only if our source disappeared.
          // If the source remains, a competing writer may own the destination
          // and rollback must not delete it.
          final sourceType = await FileSystemEntity.type(
            publication.temporary.path,
            followLinks: false,
          );
          if (sourceType == FileSystemEntityType.notFound &&
              await _matchesExpectedFile(
                publication.target,
                publication.entry.byteLength,
                publication.entry.sha256,
              )) {
            createdMediaFiles.add(publication.target);
          }
          rethrow;
        }
        preparedTemporaryFiles.remove(publication.temporary);
        createdMediaFiles.add(published);
      }
      await _fault(BackupRestoreFaultPoint.afterMediaPublish);
      await _fault(BackupRestoreFaultPoint.beforeCatalogCommit);
      catalogWriteAttempted = true;
      await _catalogRepository.saveCatalog(nextSnapshot);
      catalogCommitted = true;

      final cleanupReferences = await _referencedPaths(nextSnapshot, root);
      cleanupReferences.add(await _canonicalOrAbsolute(packageFile));
      final cleanup = await _cleanupOrphans(
        imagesDirectory,
        referencedPaths: cleanupReferences,
      );
      await _deleteFileBestEffort(restoreJournal);
      return BackupRestoreResult(
        snapshot: nextSnapshot,
        inspection: validated.inspection,
        mode: mode,
        createdMediaCount: createdMediaFiles.length,
        deletedOrphanCount: cleanup.deleted,
        retainedOrphanCount: cleanup.retained,
      );
    } catch (error, stackTrace) {
      if (!catalogCommitted) {
        final rollbackSucceeded = await _rollbackRestore(
          preparedTemporaryFiles: preparedTemporaryFiles,
          createdMediaFiles: createdMediaFiles,
          previousSnapshot: previousSnapshot,
          restoreCatalog: catalogWriteAttempted,
          root: root,
          removeImagesDirectoryIfEmpty: imagesDirectoryCreated,
          restoreJournal: restoreJournal,
        );
        if (!rollbackSucceeded) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.rollbackFailed,
            '恢复失败且自动回滚未能完整完成，请勿继续写入并保留现场。',
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      await _deleteWorkspaceBestEffort(workspace);
    }
  }

  Future<_PreparedExport> _prepareExportSnapshot(
    Directory root,
    Directory workspace,
    CatalogSnapshot snapshot,
  ) async {
    final imagesDirectory = Directory(_join(root.path, 'images'));
    final imagesType = await FileSystemEntity.type(
      imagesDirectory.path,
      followLinks: false,
    );
    if (imagesType == FileSystemEntityType.link) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.symbolicLink,
        '媒体目录不能是软链接。',
      );
    }
    final mediaDirectory = Directory(_join(workspace.path, 'media'));
    await mediaDirectory.create(recursive: true);

    final canonicalToLogical = <String, String>{};
    final mediaByLogical = <String, _ValidatedMedia>{};
    var totalMediaBytes = 0;

    Future<ItemRecord> prepareItem(ItemRecord item) async {
      final rawPath = item.imagePath.trim();
      if (rawPath.isEmpty) {
        return item;
      }
      final source = _resolveCatalogMediaFile(root, rawPath);
      final sourceType = await FileSystemEntity.type(
        source.path,
        followLinks: false,
      );
      if (sourceType == FileSystemEntityType.link) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.symbolicLink,
          '备份媒体不能是软链接。',
        );
      }
      if (sourceType != FileSystemEntityType.file) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.missingMedia,
          '目录引用的媒体文件不存在。',
        );
      }
      if (imagesType != FileSystemEntityType.directory) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.missingMedia,
          '媒体目录不存在。',
        );
      }
      final canonicalRoot = await imagesDirectory.resolveSymbolicLinks();
      final canonicalSource = await source.resolveSymbolicLinks();
      if (!_isPathWithin(canonicalSource, canonicalRoot)) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.unsafePath,
          '目录引用了媒体目录之外的文件。',
        );
      }
      final existingLogical = canonicalToLogical[canonicalSource];
      if (existingLogical != null) {
        return item.copyWith(imagePath: existingLogical);
      }

      final statBefore = await source.stat();
      if (statBefore.size <= 0) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidMedia,
          '备份媒体为空或已损坏。',
        );
      }
      if (statBefore.size > _limits.maxSingleEntryBytes) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.expandedSizeExceeded,
          '单个媒体文件超过备份限制。',
        );
      }
      final temporary = File(
        _join(mediaDirectory.path, '.source-${_nonce()}.tmp'),
      );
      await _fileSystem.copyAndSync(source, temporary);
      final statAfter = await source.stat();
      if (statAfter.size != statBefore.size ||
          statAfter.modified != statBefore.modified) {
        await _deleteFileBestEffort(temporary);
        throw const BackupRestoreException(
          BackupRestoreErrorCode.writeFailed,
          '备份期间媒体文件发生变化，请重试。',
        );
      }
      final bytes = await temporary.readAsBytes();
      final extension = _validateAndDetectImage(bytes);
      final digest = sha256.convert(bytes).toString();
      if (await _hashFile(source) != digest) {
        await _deleteFileBestEffort(temporary);
        throw const BackupRestoreException(
          BackupRestoreErrorCode.writeFailed,
          '备份期间媒体内容发生变化，请重试。',
        );
      }
      final logicalPath = 'media/$digest.$extension';
      final destination = File(_join(workspace.path, logicalPath));
      final existingMedia = mediaByLogical[logicalPath];
      if (existingMedia == null) {
        if (mediaByLogical.length >= _limits.maxMediaFiles) {
          await _deleteFileBestEffort(temporary);
          throw const BackupRestoreException(
            BackupRestoreErrorCode.entryLimitExceeded,
            '媒体文件数量超过备份限制。',
          );
        }
        totalMediaBytes += bytes.length;
        if (totalMediaBytes > _limits.maxExpandedBytes) {
          await _deleteFileBestEffort(temporary);
          throw const BackupRestoreException(
            BackupRestoreErrorCode.expandedSizeExceeded,
            '媒体总大小超过备份限制。',
          );
        }
        final minimumArchiveBytes = _storedZipSize(<String, int>{
          _manifestPath: 0,
          _catalogPath: 0,
          for (final existing in mediaByLogical.values)
            existing.entry.path: existing.entry.byteLength,
          logicalPath: bytes.length,
        });
        if (minimumArchiveBytes > _limits.maxArchiveBytes) {
          await _deleteFileBestEffort(temporary);
          throw const BackupRestoreException(
            BackupRestoreErrorCode.expandedSizeExceeded,
            '媒体总大小会使备份包超过限制。',
          );
        }
        final published = await _fileSystem.renameNew(temporary, destination);
        final entry = BackupMediaManifestEntry(
          path: logicalPath,
          byteLength: bytes.length,
          sha256: digest,
        );
        mediaByLogical[logicalPath] = _ValidatedMedia(entry, published);
      } else {
        await _deleteFileBestEffort(temporary);
      }
      canonicalToLogical[canonicalSource] = logicalPath;
      return item.copyWith(imagePath: logicalPath);
    }

    final items = <ItemRecord>[];
    for (final item in snapshot.items) {
      items.add(await prepareItem(item));
    }
    final pendingItems = <ItemRecord>[];
    for (final item in snapshot.pendingItems) {
      pendingItems.add(await prepareItem(item));
    }
    final media = mediaByLogical.values.toList()
      ..sort((left, right) => left.entry.path.compareTo(right.entry.path));
    return _PreparedExport(
      CatalogSnapshot(items: items, pendingItems: pendingItems),
      media,
    );
  }

  int _storedZipSize(Map<String, int> entries) {
    var total = 22; // EOCD
    for (final entry in entries.entries) {
      final nameBytes = utf8.encode(entry.key).length;
      // STORE uses a 30-byte local header and a 46-byte central header. The
      // current writer does not add comments, data descriptors, or extras.
      total += 30 + nameBytes + entry.value;
      total += 46 + nameBytes;
    }
    return total;
  }

  Future<_ValidatedPackage> _extractAndValidate(
    File packageFile,
    Directory workspace,
  ) async {
    final type = await FileSystemEntity.type(
      packageFile.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.symbolicLink,
        '备份包不能是软链接。',
      );
    }
    if (type != FileSystemEntityType.file) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.sourceMissing,
        '备份包不存在。',
      );
    }
    final archiveBytes = await packageFile.length();
    if (archiveBytes <= 0 || archiveBytes > _limits.maxArchiveBytes) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.expandedSizeExceeded,
        '备份包大小超过限制或内容为空。',
      );
    }

    final extractionRoot = Directory(_join(workspace.path, 'extracted'));
    await extractionRoot.create(recursive: true);
    final entries = await _readZipDirectory(packageFile);
    final input = InputFileStream(packageFile.path);
    try {
      final seenPaths = <String>{};
      final seenFoldedPaths = <String>{};
      var declaredExpandedBytes = 0;
      for (final entry in entries) {
        final entryPath = entry.path;
        _validateArchiveEntryPath(entryPath);
        if (!seenPaths.add(entryPath) ||
            !seenFoldedPaths.add(entryPath.toLowerCase())) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.duplicateEntry,
            '备份包包含重复或大小写冲突的条目。',
          );
        }
        _validateArchiveEntryType(entry);
        final compressed = entry.compressedSize;
        final expanded = entry.uncompressedSize;
        if (expanded > _limits.maxSingleEntryBytes) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.expandedSizeExceeded,
            '单个备份条目展开后超过限制。',
          );
        }
        declaredExpandedBytes += expanded;
        if (declaredExpandedBytes > _limits.maxExpandedBytes) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.expandedSizeExceeded,
            '备份包展开总大小超过限制。',
          );
        }
        if (expanded > 0) {
          if (compressed == 0 ||
              expanded / compressed > _limits.maxCompressionRatio) {
            throw const BackupRestoreException(
              BackupRestoreErrorCode.compressionRatioExceeded,
              '备份包压缩比超过安全限制。',
            );
          }
        }
        if ((entryPath == _manifestPath ||
                entryPath == _catalogPath ||
                entryPath == 'items.json' ||
                entryPath == 'pending_items.json') &&
            expanded > _limits.maxCatalogBytes) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.expandedSizeExceeded,
            '备份业务数据超过限制。',
          );
        }
      }

      final budget = _ExtractionBudget(_limits.maxExpandedBytes);
      final extracted = <String, File>{};
      for (final entry in entries) {
        // Packages created by this service always use STORE. The archive
        // dependency's raw DEFLATE decoder does not expose whether a valid
        // final block was observed, so accepting DEFLATE here could treat a
        // stream with a valid prefix and an invalid terminator as complete.
        // Compression metadata is still preflighted above so bomb-like ratios
        // receive their specific error before compressed payloads are refused.
        if (entry.compressionMethod != ZipFile.zipCompressionStore) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包仅支持可精确校验边界的 STORE 条目。',
          );
        }
        final destination = _entryFile(extractionRoot, entry.path);
        await destination.parent.create(recursive: true);
        if (await FileSystemEntity.type(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.duplicateEntry,
            '备份条目在当前文件系统上发生路径冲突。',
          );
        }
        final output = _BoundedFileOutput(
          destination.path,
          entryLimit: _limits.maxSingleEntryBytes,
          budget: budget,
        );
        try {
          final rawContent = input.subset(
            entry.dataOffset,
            entry.compressedSize,
          );
          output.writeInputStream(rawContent);
          if (!rawContent.isEOS) {
            throw const BackupRestoreException(
              BackupRestoreErrorCode.invalidArchive,
              '备份压缩数据包含未消费的尾部字节。',
            );
          }
          output.flush();
        } finally {
          output.closeSync();
        }
        final expectedLength = entry.uncompressedSize;
        if (output.length != expectedLength ||
            await destination.length() != expectedLength) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.sizeMismatch,
            '备份包条目尺寸校验失败。',
          );
        }
        if (output.crc32 != entry.crc32) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.hashMismatch,
            '备份包条目完整性校验失败。',
          );
        }
        await _fileSystem.syncFile(destination);
        extracted[entry.path] = destination;
      }

      if (extracted.containsKey(_manifestPath)) {
        return _validateVersionOnePackage(extracted);
      }
      return _validateLegacyPackage(packageFile, extracted);
    } on BackupRestoreException {
      rethrow;
    } on ArchiveException {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidArchive,
        '备份包不是有效的 ZIP 文件。',
      );
    } on RangeError {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidArchive,
        '备份包结构已损坏。',
      );
    } finally {
      await input.close();
    }
  }

  Future<_ValidatedPackage> _validateVersionOnePackage(
    Map<String, File> extracted,
  ) async {
    final manifestFile = extracted[_manifestPath]!;
    final manifest = _decodeObject(await manifestFile.readAsBytes());
    if (manifest['package'] != _packageName) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '备份包标识无效。',
      );
    }
    final version = manifest['formatVersion'];
    if (version is! int || version != _formatVersion) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.unsupportedVersion,
        '备份包版本不受支持。',
      );
    }
    final createdAtRaw = manifest['createdAt'];
    final createdAt = createdAtRaw is String
        ? DateTime.tryParse(createdAtRaw)
        : null;
    if (createdAt == null || !createdAt.isUtc) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '备份创建时间必须包含 UTC 时区。',
      );
    }

    final catalogManifest = _asObject(manifest['catalog']);
    if (catalogManifest['path'] != _catalogPath ||
        catalogManifest['schemaVersion'] != _catalogSchemaVersion) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '备份业务数据清单无效。',
      );
    }
    final catalogLength = _positiveOrZeroInt(
      catalogManifest['byteLength'],
      '备份业务数据尺寸无效。',
    );
    final catalogHash = _shaString(catalogManifest['sha256']);
    final itemCount = _positiveOrZeroInt(
      catalogManifest['itemCount'],
      '物品数量无效。',
    );
    final pendingItemCount = _positiveOrZeroInt(
      catalogManifest['pendingItemCount'],
      '待确认物品数量无效。',
    );
    final catalogFile = extracted[_catalogPath];
    if (catalogFile == null) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidReference,
        '备份业务数据文件缺失。',
      );
    }
    await _verifyFile(catalogFile, catalogLength, catalogHash);
    final catalog = _decodeObject(await catalogFile.readAsBytes());
    if (catalog['schemaVersion'] != _catalogSchemaVersion) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '备份业务数据版本无效。',
      );
    }
    final snapshot = _decodeSnapshot(
      catalog['items'],
      catalog['pendingItems'],
      legacy: false,
    );
    if (snapshot.items.length != itemCount ||
        snapshot.pendingItems.length != pendingItemCount) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.sizeMismatch,
        '业务数据条目数量与清单不一致。',
      );
    }

    final mediaRaw = manifest['media'];
    if (mediaRaw is! List<dynamic> || mediaRaw.length > _limits.maxMediaFiles) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.entryLimitExceeded,
        '媒体清单数量无效或超过限制。',
      );
    }
    final media = <String, _ValidatedMedia>{};
    final seenHashes = <String>{};
    var mediaBytes = 0;
    for (final rawEntry in mediaRaw) {
      final object = _asObject(rawEntry);
      final path = object['path'];
      if (path is! String) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidSchema,
          '媒体清单路径无效。',
        );
      }
      _validateMediaLogicalPath(path);
      final byteLength = _positiveInt(object['byteLength'], '媒体尺寸无效。');
      final hash = _shaString(object['sha256']);
      if (!path.startsWith('media/$hash.') || !seenHashes.add(hash)) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.duplicateEntry,
          '媒体清单未按真实内容去重。',
        );
      }
      if (media.containsKey(path)) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.duplicateEntry,
          '媒体清单包含重复条目。',
        );
      }
      final file = extracted[path];
      if (file == null) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.missingMedia,
          '媒体清单引用的文件缺失。',
        );
      }
      await _verifyFile(file, byteLength, hash);
      final detectedExtension = _validateAndDetectImage(
        await file.readAsBytes(),
      );
      if (detectedExtension != _extensionOf(path)) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidMedia,
          '媒体文件内容与清单扩展名不一致。',
        );
      }
      mediaBytes += byteLength;
      if (mediaBytes > _limits.maxExpandedBytes) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.expandedSizeExceeded,
          '媒体总大小超过限制。',
        );
      }
      final entry = BackupMediaManifestEntry(
        path: path,
        byteLength: byteLength,
        sha256: hash,
      );
      media[path] = _ValidatedMedia(entry, file);
    }

    final expectedEntries = <String>{
      _manifestPath,
      _catalogPath,
      ...media.keys,
    };
    if (!expectedEntries.containsAll(extracted.keys) ||
        !extracted.keys.toSet().containsAll(expectedEntries)) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidReference,
        '备份包包含清单之外的条目。',
      );
    }
    final references = _logicalReferences(snapshot);
    if (!references.containsAll(media.keys) ||
        !media.keys.toSet().containsAll(references)) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidReference,
        '业务数据与媒体清单引用不完整。',
      );
    }
    return _ValidatedPackage(
      snapshot,
      BackupPackageInspection(
        formatVersion: version,
        createdAt: createdAt.toUtc(),
        itemCount: itemCount,
        pendingItemCount: pendingItemCount,
        mediaCount: media.length,
        mediaBytes: mediaBytes,
        legacyMigrated: false,
      ),
      media,
    );
  }

  Future<_ValidatedPackage> _validateLegacyPackage(
    File packageFile,
    Map<String, File> extracted,
  ) async {
    final itemsFile = extracted['items.json'];
    if (itemsFile == null ||
        extracted.keys.any(
          (path) =>
              path != 'items.json' &&
              path != 'pending_items.json' &&
              !(path.startsWith('images/') &&
                  !path.substring('images/'.length).contains('/')),
        )) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '旧版备份结构无效。',
      );
    }
    final itemsRaw = _decodeArray(await itemsFile.readAsBytes());
    final pendingFile = extracted['pending_items.json'];
    final pendingRaw = pendingFile == null
        ? <dynamic>[]
        : _decodeArray(await pendingFile.readAsBytes());
    final legacySnapshot = _decodeSnapshot(itemsRaw, pendingRaw, legacy: true);

    final images = <String, File>{
      for (final entry in extracted.entries)
        if (entry.key.startsWith('images/')) entry.key: entry.value,
    };
    if (images.length > _limits.maxMediaFiles) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.entryLimitExceeded,
        '旧版媒体数量超过限制。',
      );
    }
    final foldedImages = <String, String>{
      for (final path in images.keys) path.toLowerCase(): path,
    };
    final usedLegacyPaths = <String>{};
    final media = <String, _ValidatedMedia>{};

    Future<ItemRecord> migrateItem(ItemRecord item) async {
      if (item.imagePath.trim().isEmpty) {
        return item;
      }
      final legacyName = _basename(item.imagePath.replaceAll(r'\', '/'));
      final requested = 'images/$legacyName';
      final actualPath = images.containsKey(requested)
          ? requested
          : foldedImages[requested.toLowerCase()];
      if (actualPath == null) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.missingMedia,
          '旧版备份引用的媒体文件缺失。',
        );
      }
      usedLegacyPaths.add(actualPath);
      final file = images[actualPath]!;
      final bytes = await file.readAsBytes();
      final extension = _validateAndDetectImage(bytes);
      final hash = sha256.convert(bytes).toString();
      final logicalPath = 'media/$hash.$extension';
      media.putIfAbsent(
        logicalPath,
        () => _ValidatedMedia(
          BackupMediaManifestEntry(
            path: logicalPath,
            byteLength: bytes.length,
            sha256: hash,
          ),
          file,
        ),
      );
      return item.copyWith(imagePath: logicalPath);
    }

    final items = <ItemRecord>[];
    for (final item in legacySnapshot.items) {
      items.add(await migrateItem(item));
    }
    final pendingItems = <ItemRecord>[];
    for (final item in legacySnapshot.pendingItems) {
      pendingItems.add(await migrateItem(item));
    }
    if (usedLegacyPaths.length != images.length) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidReference,
        '旧版备份包含未被业务数据引用的媒体。',
      );
    }
    final snapshot = CatalogSnapshot(items: items, pendingItems: pendingItems);
    _validateUniqueIds(snapshot);
    final stat = await packageFile.stat();
    final mediaBytes = media.values.fold<int>(
      0,
      (total, value) => total + value.entry.byteLength,
    );
    return _ValidatedPackage(
      snapshot,
      BackupPackageInspection(
        formatVersion: 0,
        createdAt: stat.modified.toUtc(),
        itemCount: items.length,
        pendingItemCount: pendingItems.length,
        mediaCount: media.length,
        mediaBytes: mediaBytes,
        legacyMigrated: true,
      ),
      media,
    );
  }

  CatalogSnapshot _decodeSnapshot(
    dynamic rawItems,
    dynamic rawPendingItems, {
    required bool legacy,
  }) {
    if (rawItems is! List<dynamic> || rawPendingItems is! List<dynamic>) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '业务数据列表结构无效。',
      );
    }
    List<ItemRecord> decodeList(List<dynamic> raw) {
      return raw.map((entry) {
        final object = _asObject(entry);
        _validateItemObject(object, legacy: legacy);
        final normalized = legacy ? _normalizeLegacyItemObject(object) : object;
        try {
          return ItemRecord.fromJson(normalized);
        } on Object {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidSchema,
            '业务数据条目无法解析。',
          );
        }
      }).toList();
    }

    final snapshot = CatalogSnapshot(
      items: decodeList(rawItems),
      pendingItems: decodeList(rawPendingItems),
    );
    _validateUniqueIds(snapshot);
    return snapshot;
  }

  Map<String, dynamic> _normalizeLegacyItemObject(Map<String, dynamic> object) {
    const epoch = '1970-01-01T00:00:00.000Z';
    final normalized = Map<String, dynamic>.from(object);
    final createdAt = normalized['createdAt'];
    if (createdAt is! String || DateTime.tryParse(createdAt) == null) {
      normalized['createdAt'] = epoch;
    }
    final updatedAt = normalized['updatedAt'];
    if (updatedAt is! String || DateTime.tryParse(updatedAt) == null) {
      normalized['updatedAt'] = normalized['createdAt'];
    }
    return normalized;
  }

  void _validateItemObject(
    Map<String, dynamic> object, {
    required bool legacy,
  }) {
    final id = object['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '物品标识无效。',
      );
    }
    final imagePath = object['imagePath'];
    if (imagePath != null && imagePath is! String) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '物品媒体引用无效。',
      );
    }
    if (legacy) {
      return;
    }
    const stringFields = <String>{
      'name',
      'category',
      'status',
      'imagePath',
      'description',
      'notes',
      'room',
      'box',
      'brand',
      'model',
      'color',
      'material',
      'createdAt',
      'updatedAt',
      'queueState',
      'recognitionError',
    };
    for (final field in stringFields) {
      if (object[field] is! String) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidSchema,
          '物品字段类型无效。',
        );
      }
    }
    if (object['quantity'] is! int || (object['quantity'] as int) <= 0) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '物品数量字段无效。',
      );
    }
    final parameters = object['parameters'];
    if (parameters is! Map ||
        parameters.entries.any(
          (entry) => entry.key is! String || entry.value is! String,
        )) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '物品参数字段无效。',
      );
    }
    if (!ItemStatus.values.any((value) => value.name == object['status']) ||
        !QueueRecognitionState.values.any(
          (value) => value.name == object['queueState'],
        ) ||
        DateTime.tryParse(object['createdAt'] as String) == null ||
        DateTime.tryParse(object['updatedAt'] as String) == null) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '物品枚举或时间字段无效。',
      );
    }
  }

  CatalogSnapshot _rewriteSnapshotPaths(
    CatalogSnapshot snapshot,
    Map<String, String> mapping,
  ) {
    ItemRecord rewrite(ItemRecord item) {
      final logical = item.imagePath.trim();
      if (logical.isEmpty) {
        return item;
      }
      final target = mapping[logical];
      if (target == null) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidReference,
          '恢复媒体映射不完整。',
        );
      }
      return item.copyWith(imagePath: target);
    }

    return CatalogSnapshot(
      items: snapshot.items.map(rewrite).toList(),
      pendingItems: snapshot.pendingItems.map(rewrite).toList(),
    );
  }

  CatalogSnapshot _mergeSnapshots(
    CatalogSnapshot current,
    CatalogSnapshot incoming,
  ) {
    final items = List<ItemRecord>.from(current.items);
    final pending = List<ItemRecord>.from(current.pendingItems);

    void removeId(String id) {
      items.removeWhere((item) => item.id == id);
      pending.removeWhere((item) => item.id == id);
    }

    for (final item in incoming.items) {
      removeId(item.id);
      items.add(item);
    }
    for (final item in incoming.pendingItems) {
      removeId(item.id);
      pending.add(item);
    }
    return CatalogSnapshot(items: items, pendingItems: pending);
  }

  Future<File> _writeRestoreJournal(
    Directory root, {
    required CatalogSnapshot previousSnapshot,
    required CatalogSnapshot nextSnapshot,
    required List<File> plannedMedia,
  }) async {
    final journal = File(_join(root.path, _restoreJournalName));
    if (await FileSystemEntity.type(journal.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.rollbackFailed,
        '检测到尚未收敛的恢复记录，请先完成中断恢复。',
      );
    }
    final names = <String>{};
    for (final file in plannedMedia) {
      final name = _basename(file.path);
      if (!RegExp(r'^backup-[0-9a-f]{64}\.(jpg|png|webp)$').hasMatch(name) ||
          !names.add(name)) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidReference,
          '恢复媒体发布清单无效。',
        );
      }
    }
    final payload = utf8.encode(
      jsonEncode(<String, dynamic>{
        'schemaVersion': 1,
        'ownerProcessId': pid,
        'createdAt': _timestampProvider().toUtc().toIso8601String(),
        'previousCatalogSha256': _snapshotDigest(previousSnapshot),
        'nextCatalogSha256': _snapshotDigest(nextSnapshot),
        'createdMedia': names.toList()..sort(),
      }),
    );
    final temporary = File('${journal.path}.tmp-${_nonce()}');
    try {
      await temporary.writeAsBytes(payload, flush: true);
      await _fileSystem.syncFile(temporary);
      try {
        return await _fileSystem.renameNew(temporary, journal);
      } catch (_) {
        final sourceType = await FileSystemEntity.type(
          temporary.path,
          followLinks: false,
        );
        if (sourceType != FileSystemEntityType.notFound ||
            !await _matchesExpectedFile(
              journal,
              payload.length,
              sha256.convert(payload).toString(),
            )) {
          rethrow;
        }
        return journal;
      }
    } finally {
      await _deleteFileBestEffort(temporary);
    }
  }

  Future<void> _recoverInterruptedRestore(Directory root) async {
    final journal = File(_join(root.path, _restoreJournalName));
    final journalType = await FileSystemEntity.type(
      journal.path,
      followLinks: false,
    );
    final imagesDirectory = Directory(_join(root.path, 'images'));
    final imagesType = await FileSystemEntity.type(
      imagesDirectory.path,
      followLinks: false,
    );

    if (journalType == FileSystemEntityType.notFound) {
      return;
    }
    if (journalType != FileSystemEntityType.file) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.rollbackFailed,
        '中断恢复记录类型异常，已停止自动处理。',
      );
    }
    final journalLength = await journal.length();
    if (journalLength <= 0 || journalLength > 1024 * 1024) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.rollbackFailed,
        '中断恢复记录大小异常，已停止自动处理。',
      );
    }

    Map<String, dynamic> object;
    try {
      final decoded = jsonDecode(utf8.decode(await journal.readAsBytes()));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      object = decoded;
    } on Object {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.rollbackFailed,
        '中断恢复记录结构无效，已保留现场。',
      );
    }
    final previousHash = object['previousCatalogSha256'];
    final nextHash = object['nextCatalogSha256'];
    final rawMedia = object['createdMedia'];
    if (object['schemaVersion'] != 1 ||
        previousHash is! String ||
        nextHash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(previousHash) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(nextHash) ||
        rawMedia is! List<dynamic>) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.rollbackFailed,
        '中断恢复记录字段无效，已保留现场。',
      );
    }
    final mediaNames = <String>{};
    for (final value in rawMedia) {
      if (value is! String ||
          !RegExp(r'^backup-[0-9a-f]{64}\.(jpg|png|webp)$').hasMatch(value) ||
          !mediaNames.add(value)) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.rollbackFailed,
          '中断恢复媒体清单无效，已保留现场。',
        );
      }
    }

    final current = await _catalogRepository.loadCatalog();
    final currentHash = _snapshotDigest(current);
    if (currentHash != nextHash && currentHash != previousHash) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.rollbackFailed,
        '当前目录既不匹配恢复前也不匹配已提交状态，已保留现场。',
      );
    }
    final currentReferences = await _referencedPaths(current, root);
    if (imagesType == FileSystemEntityType.notFound) {
      if (mediaNames.isNotEmpty || currentReferences.isNotEmpty) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.rollbackFailed,
          '中断恢复缺少必要的媒体目录，已保留现场。',
        );
      }
      // Older builds could remove an empty images directory before deleting
      // the journal. With no planned or referenced media, either catalog hash
      // is already a complete state and deleting the stale journal is safe.
      await _fileSystem.deleteFile(journal);
      return;
    }
    if (imagesType != FileSystemEntityType.directory) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.rollbackFailed,
        '中断恢复媒体目录类型异常，已停止自动处理。',
      );
    }
    await _cleanupInterruptedMediaTemps(
      imagesDirectory,
      protectedPaths: currentReferences,
    );
    if (previousHash == nextHash) {
      var publicationIncomplete = false;
      var plannedMediaReferencedByCurrent = false;
      final publishedBeforeInterruption = <File>[];
      for (final name in mediaNames) {
        final file = File(_join(imagesDirectory.path, name));
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (currentReferences.contains(await _canonicalOrAbsolute(file))) {
          plannedMediaReferencedByCurrent = true;
        }
        if (type == FileSystemEntityType.notFound) {
          publicationIncomplete = true;
          continue;
        }
        if (type != FileSystemEntityType.file ||
            await _hashFile(file) != _hashFromMediaName(name)) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.rollbackFailed,
            '同内容恢复的媒体发布状态异常，已保留现场。',
          );
        }
        publishedBeforeInterruption.add(file);
      }
      if (publicationIncomplete) {
        if (plannedMediaReferencedByCurrent) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.rollbackFailed,
            '同内容恢复的计划媒体仍被当前目录引用，已保留现场。',
          );
        }
        for (final file in publishedBeforeInterruption) {
          await _fileSystem.deleteFile(file);
        }
        await _fileSystem.deleteFile(journal);
        return;
      }
    }
    if (currentHash == nextHash) {
      for (final name in mediaNames) {
        final file = File(_join(imagesDirectory.path, name));
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type != FileSystemEntityType.file ||
            await _hashFile(file) != _hashFromMediaName(name)) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.rollbackFailed,
            '已提交恢复缺少完整媒体，已保留现场。',
          );
        }
      }
      await _cleanupOrphans(
        imagesDirectory,
        referencedPaths: await _referencedPaths(current, root),
      );
      await _fileSystem.deleteFile(journal);
      return;
    }
    if (currentHash == previousHash) {
      for (final name in mediaNames) {
        final file = File(_join(imagesDirectory.path, name));
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type == FileSystemEntityType.notFound) {
          continue;
        }
        if (type != FileSystemEntityType.file) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.rollbackFailed,
            '待回滚媒体目标类型异常，已保留现场。',
          );
        }
        final canonicalFile = _normalizedPath(
          await file.resolveSymbolicLinks(),
        );
        if (currentReferences.contains(canonicalFile)) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.rollbackFailed,
            '待回滚媒体仍被当前目录引用，已保留现场。',
          );
        }
        if (await _hashFile(file) != _hashFromMediaName(name)) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.rollbackFailed,
            '待回滚媒体内容与中断记录不一致，已保留现场。',
          );
        }
        await _fileSystem.deleteFile(file);
      }
      await _fileSystem.deleteFile(journal);
      return;
    }
  }

  Future<void> _cleanupInterruptedMediaTemps(
    Directory imagesDirectory, {
    required Set<String> protectedPaths,
  }) async {
    await for (final entity in imagesDirectory.list(followLinks: false)) {
      final name = _basename(entity.path);
      if (!RegExp(r'^\.restore-[0-9-]+\.tmp$').hasMatch(name)) {
        continue;
      }
      if (protectedPaths.contains(_normalizedAbsolute(entity.path))) {
        continue;
      }
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.rollbackFailed,
          '中断恢复临时媒体类型异常，已保留现场。',
        );
      }
      await _fileSystem.deleteFile(File(entity.path));
    }
  }

  String _snapshotDigest(CatalogSnapshot snapshot) {
    return sha256
        .convert(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'items': snapshot.items.map((item) => item.toJson()).toList(),
              'pendingItems': snapshot.pendingItems
                  .map((item) => item.toJson())
                  .toList(),
            }),
          ),
        )
        .toString();
  }

  String _hashFromMediaName(String name) {
    return name.substring('backup-'.length, 'backup-'.length + 64);
  }

  Future<bool> _rollbackRestore({
    required List<File> preparedTemporaryFiles,
    required List<File> createdMediaFiles,
    required CatalogSnapshot? previousSnapshot,
    required bool restoreCatalog,
    required Directory root,
    required bool removeImagesDirectoryIfEmpty,
    required File? restoreJournal,
  }) async {
    var succeeded = true;
    // Prepared files are never catalog references and are always safe to
    // remove. Published media must remain until an attempted catalog commit
    // has been durably rolled back; otherwise an after-write exception could
    // leave a NEW catalog pointing at media that rollback already deleted.
    for (final file in preparedTemporaryFiles) {
      try {
        await _fileSystem.deleteFile(file);
      } catch (_) {
        succeeded = false;
      }
    }
    var previousCatalogRestored = !restoreCatalog;
    if (restoreCatalog && previousSnapshot != null) {
      try {
        await _catalogRepository.saveCatalog(previousSnapshot);
        previousCatalogRestored = true;
      } catch (_) {
        succeeded = false;
      }
    }
    if (previousCatalogRestored) {
      for (final file in createdMediaFiles) {
        try {
          await _fileSystem.deleteFile(file);
        } catch (_) {
          succeeded = false;
        }
      }
    }
    // Delete the durable recovery record before removing an images directory
    // that this attempt created. If journal deletion fails, retaining the
    // empty directory keeps the next recovery attempt structurally possible.
    if (restoreJournal != null && succeeded) {
      try {
        await _fileSystem.deleteFile(restoreJournal);
      } catch (_) {
        succeeded = false;
      }
    }
    if (removeImagesDirectoryIfEmpty && succeeded) {
      final directory = Directory(_join(root.path, 'images'));
      try {
        final entities = await directory
            .list(followLinks: false)
            .take(1)
            .toList();
        if (entities.isEmpty) {
          await _fileSystem.deleteDirectory(directory);
        } else {
          succeeded = false;
        }
      } catch (_) {
        succeeded = false;
      }
    }
    return succeeded;
  }

  Future<_CleanupResult> _cleanupOrphans(
    Directory imagesDirectory, {
    required Set<String> referencedPaths,
  }) async {
    var deleted = 0;
    var retained = 0;
    try {
      await for (final entity in imagesDirectory.list(followLinks: false)) {
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type != FileSystemEntityType.file) {
          retained++;
          continue;
        }
        if (referencedPaths.contains(_normalizedAbsolute(entity.path))) {
          continue;
        }
        if (!_isManagedMediaOrTemporary(_basename(entity.path))) {
          retained++;
          continue;
        }
        try {
          await _fileSystem.deleteFile(File(entity.path));
          deleted++;
        } catch (_) {
          retained++;
        }
      }
    } catch (_) {
      retained++;
    }
    return _CleanupResult(deleted, retained);
  }

  bool _isManagedMediaOrTemporary(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.heic') ||
        RegExp(r'^\.restore-[0-9-]+\.tmp$').hasMatch(name) ||
        RegExp(r'^\.tmp-[A-Za-z0-9._-]+$').hasMatch(name);
  }

  Future<String> _canonicalOrAbsolute(File file) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        return _normalizedPath(await file.resolveSymbolicLinks());
      }
    } on FileSystemException {
      // A concurrently moved package is still protected by its absolute
      // spelling; restore validation will report the primary read failure.
    }
    return _normalizedAbsolute(file.path);
  }

  Future<void> _verifyExistingTarget(
    File file,
    BackupMediaManifestEntry entry,
  ) async {
    await _verifyFile(file, entry.byteLength, entry.sha256);
    _validateAndDetectImage(await file.readAsBytes());
  }

  Future<void> _verifyFile(File file, int length, String hash) async {
    if (await file.length() != length) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.sizeMismatch,
        '备份文件尺寸校验失败。',
      );
    }
    if (await _hashFile(file) != hash) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.hashMismatch,
        '备份文件 SHA-256 校验失败。',
      );
    }
  }

  Future<bool> _matchesExpectedFile(
    File file,
    int expectedLength,
    String expectedHash,
  ) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != expectedLength) {
        return false;
      }
      return await _hashFile(file) == expectedHash;
    } on FileSystemException {
      return false;
    }
  }

  String _validateAndDetectImage(List<int> bytes) {
    if (bytes.isEmpty) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidMedia,
        '媒体文件无法解码或已损坏。',
      );
    }
    final payload = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    try {
      final decoder = img.findDecoderForData(payload);
      final info = decoder?.startDecode(payload);
      if (decoder == null ||
          info == null ||
          info.width <= 0 ||
          info.height <= 0 ||
          info.width > _limits.maxImageDimension ||
          info.height > _limits.maxImageDimension ||
          info.width * info.height > _limits.maxImagePixels ||
          decoder.decodeFrame(0) == null) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidMedia,
          '媒体文件无法解码或尺寸不安全。',
        );
      }
    } on BackupRestoreException {
      rethrow;
    } on Object {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidMedia,
        '媒体文件无法解码或已损坏。',
      );
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'jpg';
    }
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'webp';
    }
    throw const BackupRestoreException(
      BackupRestoreErrorCode.invalidMedia,
      '媒体编码格式不受支持。',
    );
  }

  void _validateArchiveEntryPath(String path) {
    if (path.isEmpty ||
        path.length > 1024 ||
        path.startsWith('/') ||
        path.startsWith('\\') ||
        path.contains('\\') ||
        path.contains('\u0000') ||
        path.endsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(path) ||
        !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(path) ||
        path.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.unsafePath,
        '备份包包含不安全路径。',
      );
    }
    final segments = path.split('/');
    if (segments.any(
      (segment) =>
          segment.isEmpty ||
          segment.length > 255 ||
          segment == '.' ||
          segment == '..' ||
          segment.endsWith('.') ||
          _isWindowsReservedName(segment),
    )) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.unsafePath,
        '备份包包含路径穿越条目。',
      );
    }
  }

  bool _isWindowsReservedName(String segment) {
    final stem = segment.split('.').first.toUpperCase();
    return const <String>{
      'CON',
      'PRN',
      'AUX',
      'NUL',
      'COM1',
      'COM2',
      'COM3',
      'COM4',
      'COM5',
      'COM6',
      'COM7',
      'COM8',
      'COM9',
      'LPT1',
      'LPT2',
      'LPT3',
      'LPT4',
      'LPT5',
      'LPT6',
      'LPT7',
      'LPT8',
      'LPT9',
    }.contains(stem);
  }

  void _validateArchiveEntryType(_ZipEntryMetadata entry) {
    if ((entry.versionMadeBy >> 8) == 3) {
      final mode = entry.externalFileAttributes >> 16;
      final fileType = mode & 0xF000;
      if (fileType == 0xA000) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.symbolicLink,
          '备份包不能包含软链接。',
        );
      }
      if (fileType != 0 && fileType != 0x8000) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidArchive,
          '备份包只能包含普通文件。',
        );
      }
    }
    if (entry.path.endsWith('/')) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidArchive,
        '备份包不能包含目录条目。',
      );
    }
  }

  void _validateMediaLogicalPath(String path) {
    _validateArchiveEntryPath(path);
    if (!RegExp(r'^media/[0-9a-f]{64}\.(jpg|png|webp)$').hasMatch(path)) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '媒体清单路径格式无效。',
      );
    }
  }

  Set<String> _logicalReferences(CatalogSnapshot snapshot) {
    final result = <String>{};
    for (final item in <ItemRecord>[
      ...snapshot.items,
      ...snapshot.pendingItems,
    ]) {
      final path = item.imagePath.trim();
      if (path.isEmpty) {
        continue;
      }
      _validateMediaLogicalPath(path);
      result.add(path);
    }
    return result;
  }

  Future<Set<String>> _referencedPaths(
    CatalogSnapshot snapshot,
    Directory root,
  ) async {
    final references = <String>{};
    for (final item in <ItemRecord>[
      ...snapshot.items,
      ...snapshot.pendingItems,
    ]) {
      final path = item.imagePath.trim();
      if (path.isEmpty) {
        continue;
      }
      final file = _resolveCatalogMediaFile(root, path);
      try {
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
          references.add(_normalizedPath(await file.resolveSymbolicLinks()));
          continue;
        }
      } on FileSystemException {
        // A missing or concurrently changing reference is still represented
        // by its absolute spelling; cleanup never traverses outside images.
      }
      references.add(_normalizedAbsolute(file.path));
    }
    return references;
  }

  File _resolveCatalogMediaFile(Directory root, String path) {
    final direct = File(path);
    if (direct.isAbsolute) {
      return direct;
    }
    final platformRelative = path.replaceAll(
      Platform.isWindows ? '/' : '\\',
      Platform.pathSeparator,
    );
    return File(_join(root.path, platformRelative));
  }

  void _validateUniqueIds(CatalogSnapshot snapshot) {
    final ids = <String>{};
    for (final item in <ItemRecord>[
      ...snapshot.items,
      ...snapshot.pendingItems,
    ]) {
      if (item.id.trim().isEmpty || !ids.add(item.id)) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidReference,
          '业务数据包含空标识或重复物品标识。',
        );
      }
    }
  }

  Future<T> _withRootLock<T>(Future<T> Function(Directory root) action) async {
    try {
      return await StorageMutationCoordinator.shared.runWithRootProvider(
        _documentsDirectoryProvider,
        (canonicalRoot) async {
          return _withProcessOperationLock(canonicalRoot, () async {
            await _scavengeInterruptedOperations(canonicalRoot);
            await _recoverInterruptedRestore(canonicalRoot);
            return action(canonicalRoot);
          });
        },
        exclusive: true,
        failIfBusy: true,
      );
    } on StorageMutationBusyException {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.busy,
        '同一数据目录已有备份或恢复操作正在进行。',
      );
    }
  }

  Future<T> _withProcessOperationLock<T>(
    Directory root,
    Future<T> Function() action,
  ) async {
    final lockFile = File(_join(root.path, _operationLockName));
    var lockType = await FileSystemEntity.type(
      lockFile.path,
      followLinks: false,
    );
    if (lockType == FileSystemEntityType.notFound) {
      try {
        await lockFile.create(exclusive: true);
      } on FileSystemException {
        // A cooperating or external writer may have created the lock between
        // lstat and create. Recheck its nofollow type before opening it.
      }
      lockType = await FileSystemEntity.type(lockFile.path, followLinks: false);
    }
    if (lockType == FileSystemEntityType.link) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.symbolicLink,
        '备份互斥文件不能是软链接。',
      );
    }
    if (lockType != FileSystemEntityType.file) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.writeFailed,
        '备份互斥文件不可用。',
      );
    }
    final handle = await lockFile.open(mode: FileMode.append);
    var locked = false;
    try {
      try {
        await handle.lock(FileLock.exclusive);
        locked = true;
      } on FileSystemException {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.busy,
          '另一个进程正在使用同一数据目录。',
        );
      }
      return await action();
    } finally {
      if (locked) {
        try {
          await handle.unlock();
        } on FileSystemException {
          // Closing the handle below also releases the advisory lock.
        }
      }
      await handle.close();
    }
  }

  Future<void> _scavengeInterruptedOperations(Directory root) async {
    await _scavengeOwnedWorkspaces(root);
    await _scavengeOwnedPartialPackages(root);
    await _scavengeOwnedJournalTemporaries(root);
  }

  Future<void> _scavengeOwnedWorkspaces(Directory root) async {
    final pattern = RegExp(
      r'^\.wujian-(create|validate|restore)-[0-9]+-[0-9]+-[0-9]+$',
    );
    await for (final entity in root.list(followLinks: false)) {
      final name = _basename(entity.path);
      final match = pattern.firstMatch(name);
      if (match == null) {
        continue;
      }
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final directory = Directory(entity.path);
      final marker = File(_join(directory.path, _workspaceMarkerName));
      final object = await _readSmallJsonObject(marker, maxBytes: 4096);
      if (object == null ||
          object.length != 6 ||
          object['schemaVersion'] != 1 ||
          object['kind'] != 'wujian-backup-workspace' ||
          object['purpose'] != match.group(1) ||
          object['directoryName'] != name ||
          object['ownerProcessId'] is! int ||
          (object['ownerProcessId'] as int) <= 0 ||
          !_isValidMarkerTimestamp(object['createdAt'])) {
        continue;
      }
      final cleanupPending = await _hasValidWorkspaceCleanupMarker(
        directory,
        object,
      );
      if (!cleanupPending && !_isAbandonedMarker(object)) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.busy,
          '检测到同一进程仍在使用备份工作区。',
        );
      }
      if (!await _directoryTreeContainsNoLinks(directory)) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.rollbackFailed,
          '上次中断的备份工作区包含链接，已保留现场。',
        );
      }
      try {
        await _fileSystem.deleteDirectory(directory);
      } on Object {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.rollbackFailed,
          '上次中断的备份工作区无法安全清理。',
        );
      }
    }
  }

  Future<void> _scavengeOwnedPartialPackages(Directory root) async {
    final backupsDirectory = Directory(_join(root.path, 'backups'));
    final directoryType = await FileSystemEntity.type(
      backupsDirectory.path,
      followLinks: false,
    );
    if (directoryType == FileSystemEntityType.notFound) {
      return;
    }
    if (directoryType != FileSystemEntityType.directory) {
      return;
    }
    final partialPattern = RegExp(
      r'^[A-Za-z0-9_-]+-[0-9]+-[0-9]+-[0-9]+\.wujian-backup\.partial$',
    );
    await for (final entity in backupsDirectory.list(followLinks: false)) {
      final ownerName = _basename(entity.path);
      if (!ownerName.endsWith(_partialOwnerSuffix) ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
        continue;
      }
      final owner = File(entity.path);
      final object = await _readSmallJsonObject(owner, maxBytes: 4096);
      final partialName = object?['partialName'];
      if (object == null ||
          object.length != 5 ||
          object['schemaVersion'] != 1 ||
          object['kind'] != 'wujian-backup-partial' ||
          partialName is! String ||
          !partialPattern.hasMatch(partialName) ||
          ownerName != '$partialName$_partialOwnerSuffix' ||
          !_isAbandonedMarker(object)) {
        continue;
      }
      final partial = File(_join(backupsDirectory.path, partialName));
      final partialType = await FileSystemEntity.type(
        partial.path,
        followLinks: false,
      );
      if (partialType != FileSystemEntityType.notFound &&
          partialType != FileSystemEntityType.file) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.rollbackFailed,
          '上次中断的备份临时包类型异常，已保留现场。',
        );
      }
      try {
        if (partialType == FileSystemEntityType.file) {
          await _fileSystem.deleteFile(partial);
        }
        await _fileSystem.deleteFile(owner);
      } on Object {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.rollbackFailed,
          '上次中断的备份临时包无法安全清理。',
        );
      }
    }
  }

  Future<void> _scavengeOwnedJournalTemporaries(Directory root) async {
    final pattern = RegExp(
      r'^\.wujian-restore-journal\.json\.tmp-[0-9]+-[0-9]+$',
    );
    await for (final entity in root.list(followLinks: false)) {
      if (!pattern.hasMatch(_basename(entity.path)) ||
          await FileSystemEntity.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file) {
        continue;
      }
      final file = File(entity.path);
      final object = await _readSmallJsonObject(file, maxBytes: 1024 * 1024);
      if (object == null ||
          !_isStructurallyValidRestoreJournal(object) ||
          !_isAbandonedMarker(object)) {
        continue;
      }
      try {
        await _fileSystem.deleteFile(file);
      } on Object {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.rollbackFailed,
          '上次中断的恢复记录临时文件无法安全清理。',
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _readSmallJsonObject(
    File file, {
    required int maxBytes,
  }) async {
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final length = await file.length();
      if (length <= 0 || length > maxBytes) {
        return null;
      }
      final decoded = jsonDecode(utf8.decode(await file.readAsBytes()));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  Future<bool> _hasValidWorkspaceCleanupMarker(
    Directory directory,
    Map<String, dynamic> owner,
  ) async {
    final marker = File(_join(directory.path, _workspaceCleanupMarkerName));
    final object = await _readSmallJsonObject(marker, maxBytes: 4096);
    return object != null &&
        object.length == 5 &&
        object['schemaVersion'] == 1 &&
        object['kind'] == 'wujian-backup-cleanup-pending' &&
        object['directoryName'] == owner['directoryName'] &&
        object['ownerProcessId'] == owner['ownerProcessId'] &&
        _isValidMarkerTimestamp(object['createdAt']);
  }

  bool _isValidMarkerTimestamp(dynamic value) {
    if (value is! String || !value.endsWith('Z')) {
      return false;
    }
    return DateTime.tryParse(value)?.isUtc ?? false;
  }

  bool _isAbandonedMarker(Map<String, dynamic> object) {
    final ownerProcessId = object['ownerProcessId'];
    final rawCreatedAt = object['createdAt'];
    if (ownerProcessId is! int ||
        ownerProcessId <= 0 ||
        !_isValidMarkerTimestamp(rawCreatedAt)) {
      return false;
    }
    if (ownerProcessId != pid) {
      return true;
    }
    final createdAt = DateTime.parse(rawCreatedAt as String);
    // Dart's advisory file locks are process-level on macOS/Linux, so another
    // isolate in this process could still own a same-PID marker. Only consider
    // such a marker stale after a conservative interval; fresh work is never
    // removed merely because its name matches our namespace.
    return createdAt.isBefore(
      _timestampProvider().toUtc().subtract(const Duration(hours: 24)),
    );
  }

  bool _isStructurallyValidRestoreJournal(Map<String, dynamic> object) {
    if (object['schemaVersion'] != 1 ||
        object['previousCatalogSha256'] is! String ||
        object['nextCatalogSha256'] is! String ||
        !RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(object['previousCatalogSha256'] as String) ||
        !RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(object['nextCatalogSha256'] as String) ||
        object['createdMedia'] is! List<dynamic>) {
      return false;
    }
    final names = <String>{};
    for (final value in object['createdMedia'] as List<dynamic>) {
      if (value is! String ||
          !RegExp(r'^backup-[0-9a-f]{64}\.(jpg|png|webp)$').hasMatch(value) ||
          !names.add(value) ||
          names.length > _limits.maxMediaFiles) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _directoryTreeContainsNoLinks(Directory directory) async {
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (await FileSystemEntity.type(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          return false;
        }
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<T> _guarded<T>(
    Future<T> Function() action, {
    required BackupRestoreErrorCode fallbackCode,
    required String fallbackMessage,
  }) async {
    try {
      return await action();
    } on BackupRestoreException {
      rethrow;
    } on Object {
      throw BackupRestoreException(fallbackCode, fallbackMessage);
    }
  }

  Future<Directory> _createWorkspace(Directory parent, String purpose) async {
    await _requireSafeDirectory(parent, create: true);
    for (var attempt = 0; attempt < 1000; attempt++) {
      final directory = Directory(
        _join(parent.path, '.wujian-$purpose-${_nonce()}-$attempt'),
      );
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      await directory.create(recursive: false);
      final marker = File(_join(directory.path, _workspaceMarkerName));
      try {
        await _writeOwnedMarker(marker, <String, dynamic>{
          'schemaVersion': 1,
          'kind': 'wujian-backup-workspace',
          'purpose': purpose,
          'directoryName': _basename(directory.path),
        });
        return directory;
      } catch (_) {
        await _deleteDirectoryBestEffort(directory);
        rethrow;
      }
    }
    throw const BackupRestoreException(
      BackupRestoreErrorCode.writeFailed,
      '无法创建唯一的备份临时目录。',
    );
  }

  Future<void> _writeOwnedMarker(
    File marker,
    Map<String, dynamic> fields,
  ) async {
    final payload = utf8.encode(
      jsonEncode(<String, dynamic>{
        ...fields,
        'ownerProcessId': pid,
        'createdAt': _timestampProvider().toUtc().toIso8601String(),
      }),
    );
    await marker.writeAsBytes(payload, flush: true);
    await _fileSystem.syncFile(marker);
  }

  Future<void> _requireSafeDirectory(
    Directory directory, {
    required bool create,
  }) async {
    var type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await directory.create(recursive: true);
      type = await FileSystemEntity.type(directory.path, followLinks: false);
    }
    if (type == FileSystemEntityType.link) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.symbolicLink,
        '备份工作目录不能是软链接。',
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.writeFailed,
        '备份工作目录不可用。',
      );
    }
  }

  Future<void> _ensureBackupStorageCapacity(
    Directory backupsDirectory,
    int estimatedPackageBytes,
  ) async {
    final directoryType = await FileSystemEntity.type(
      backupsDirectory.path,
      followLinks: false,
    );
    if (directoryType == FileSystemEntityType.notFound) {
      return;
    }
    if (directoryType == FileSystemEntityType.link) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.symbolicLink,
        '备份目录不能是软链接。',
      );
    }
    if (directoryType != FileSystemEntityType.directory) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.writeFailed,
        '备份目录不可用。',
      );
    }
    var storedBytes = 0;
    var storedPackages = 0;
    await for (final entity in backupsDirectory.list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      final name = _basename(entity.path);
      final isFinalPackage = name.endsWith('.wujian-backup');
      if (type == FileSystemEntityType.file) {
        final length = await File(entity.path).length();
        storedBytes += length;
        if (isFinalPackage) {
          storedPackages++;
        }
        continue;
      }
      if (isFinalPackage && type != FileSystemEntityType.notFound) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.symbolicLink,
          '备份目录包含类型异常的备份包，已停止写入。',
        );
      }
    }
    if (storedPackages >= _limits.maxStoredBackupFiles ||
        estimatedPackageBytes >
            _limits.maxStoredBackupBytes -
                math.min(storedBytes, _limits.maxStoredBackupBytes)) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.storageLimitExceeded,
        '本地备份保留空间已达上限，请先安全转移现有备份。',
      );
    }
  }

  Future<String> _hashFile(File file) async {
    return (await sha256.bind(file.openRead()).first).toString();
  }

  /// Strictly parses ZIP metadata with bounded reads before any extraction.
  ///
  /// The archive package's decoder materializes the full central directory
  /// before callers can inspect its entry count. This parser instead verifies
  /// the EOCD, every central header, its matching local header, and all data
  /// ranges without loading the central directory into memory.
  Future<List<_ZipEntryMetadata>> _readZipDirectory(File file) async {
    const endRecordLength = 22;
    const centralHeaderLength = 46;
    const localHeaderLength = 30;
    const maxCentralDirectoryBytes = 64 * 1024 * 1024;
    const maxArchivePathBytes = 1024;
    const maxExtraFieldBytes = 4096;
    final length = await file.length();
    if (length < endRecordLength) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidArchive,
        '备份包 ZIP 尾部结构缺失。',
      );
    }
    final handle = await file.open();
    try {
      final endRecord = await _readExact(
        handle,
        length - endRecordLength,
        endRecordLength,
      );
      if (_uint32(endRecord, 0) != 0x06054b50 || _uint16(endRecord, 20) != 0) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidArchive,
          '备份包必须使用无注释的标准 ZIP 结束记录。',
        );
      }
      final diskNumber = _uint16(endRecord, 4);
      final directoryDisk = _uint16(endRecord, 6);
      final diskEntries = _uint16(endRecord, 8);
      final totalEntries = _uint16(endRecord, 10);
      final directorySize = _uint32(endRecord, 12);
      final directoryOffset = _uint32(endRecord, 16);
      if (diskNumber != 0 ||
          directoryDisk != 0 ||
          diskEntries != totalEntries) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidArchive,
          '不支持分卷备份包。',
        );
      }
      if (totalEntries == 0 ||
          totalEntries == 0xffff ||
          directorySize == 0xffffffff ||
          directoryOffset == 0xffffffff) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.entryLimitExceeded,
          '备份包条目数量或目录范围超过支持范围。',
        );
      }
      if (totalEntries > _limits.maxEntries) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.entryLimitExceeded,
          '备份包条目数量超过限制。',
        );
      }
      if (directorySize > maxCentralDirectoryBytes ||
          directorySize < totalEntries * centralHeaderLength ||
          directoryOffset + directorySize != length - endRecordLength) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidArchive,
          '备份包中央目录大小或边界无效。',
        );
      }

      final entries = <_ZipEntryMetadata>[];
      final occupiedRanges = <_ZipOccupiedRange>[];
      final directoryEnd = directoryOffset + directorySize;
      var centralPosition = directoryOffset;
      for (var index = 0; index < totalEntries; index++) {
        if (centralPosition + centralHeaderLength > directoryEnd) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包中央目录条目被截断。',
          );
        }
        final central = await _readExact(
          handle,
          centralPosition,
          centralHeaderLength,
        );
        if (_uint32(central, 0) != 0x02014b50) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包中央目录签名无效。',
          );
        }
        final versionMadeBy = _uint16(central, 4);
        final flags = _uint16(central, 8);
        final compressionMethod = _uint16(central, 10);
        final crc32 = _uint32(central, 16);
        final compressedSize = _uint32(central, 20);
        final uncompressedSize = _uint32(central, 24);
        final nameLength = _uint16(central, 28);
        final extraLength = _uint16(central, 30);
        final commentLength = _uint16(central, 32);
        final diskStart = _uint16(central, 34);
        final externalAttributes = _uint32(central, 38);
        final localOffset = _uint32(central, 42);
        if (nameLength <= 0 ||
            nameLength > maxArchivePathBytes ||
            extraLength > maxExtraFieldBytes ||
            commentLength != 0 ||
            diskStart != 0 ||
            compressedSize == 0xffffffff ||
            uncompressedSize == 0xffffffff ||
            localOffset == 0xffffffff ||
            (flags & ~0x0800) != 0 ||
            (compressionMethod != ZipFile.zipCompressionStore &&
                compressionMethod != ZipFile.zipCompressionDeflate)) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包中央目录字段不受支持或超过限制。',
          );
        }
        final centralRecordLength =
            centralHeaderLength + nameLength + extraLength + commentLength;
        if (centralPosition + centralRecordLength > directoryEnd) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包中央目录可变字段越界。',
          );
        }
        final centralName = await _readExact(
          handle,
          centralPosition + centralHeaderLength,
          nameLength,
        );
        final path = _decodeZipPath(centralName, utf8Encoded: flags != 0);

        if (localOffset + localHeaderLength > directoryOffset) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包本地文件头越界。',
          );
        }
        final local = await _readExact(handle, localOffset, localHeaderLength);
        final localNameLength = _uint16(local, 26);
        final localExtraLength = _uint16(local, 28);
        if (_uint32(local, 0) != 0x04034b50 ||
            _uint16(local, 6) != flags ||
            _uint16(local, 8) != compressionMethod ||
            _uint32(local, 14) != crc32 ||
            _uint32(local, 18) != compressedSize ||
            _uint32(local, 22) != uncompressedSize ||
            localNameLength != nameLength ||
            localExtraLength > maxExtraFieldBytes) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包本地文件头与中央目录不一致。',
          );
        }
        final localName = await _readExact(
          handle,
          localOffset + localHeaderLength,
          localNameLength,
        );
        if (!_bytesEqual(localName, centralName)) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包本地与中央目录文件名不一致。',
          );
        }
        final dataOffset =
            localOffset +
            localHeaderLength +
            localNameLength +
            localExtraLength;
        final dataEnd = dataOffset + compressedSize;
        if (dataEnd > directoryOffset || dataOffset < localOffset) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包压缩数据范围越界。',
          );
        }
        entries.add(
          _ZipEntryMetadata(
            path: path,
            versionMadeBy: versionMadeBy,
            externalFileAttributes: externalAttributes,
            compressionMethod: compressionMethod,
            crc32: crc32,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            dataOffset: dataOffset,
          ),
        );
        occupiedRanges.add(_ZipOccupiedRange(localOffset, dataEnd));
        centralPosition += centralRecordLength;
      }
      if (centralPosition != directoryEnd || entries.length != totalEntries) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidArchive,
          '备份包中央目录计数或长度不一致。',
        );
      }
      occupiedRanges.sort((left, right) => left.start.compareTo(right.start));
      if (occupiedRanges.isEmpty || occupiedRanges.first.start != 0) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidArchive,
          '备份包在首个受管条目之前包含未声明数据。',
        );
      }
      for (var index = 1; index < occupiedRanges.length; index++) {
        if (occupiedRanges[index].start != occupiedRanges[index - 1].end) {
          throw const BackupRestoreException(
            BackupRestoreErrorCode.invalidArchive,
            '备份包本地文件数据范围重叠或包含未声明间隙。',
          );
        }
      }
      if (occupiedRanges.last.end != directoryOffset) {
        throw const BackupRestoreException(
          BackupRestoreErrorCode.invalidArchive,
          '备份包本地条目与中央目录之间包含未声明数据。',
        );
      }
      return entries;
    } finally {
      await handle.close();
    }
  }

  Future<Uint8List> _readExact(
    RandomAccessFile handle,
    int offset,
    int length,
  ) async {
    if (offset < 0 || length < 0) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidArchive,
        '备份包读取范围无效。',
      );
    }
    await handle.setPosition(offset);
    final bytes = await handle.read(length);
    if (bytes.length != length) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidArchive,
        '备份包在声明范围内被截断。',
      );
    }
    return bytes;
  }

  int _uint16(Uint8List bytes, int offset) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  }

  int _uint32(Uint8List bytes, int offset) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }

  String _decodeZipPath(Uint8List bytes, {required bool utf8Encoded}) {
    try {
      return utf8Encoded ? utf8.decode(bytes) : latin1.decode(bytes);
    } on FormatException {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.unsafePath,
        '备份包文件名编码无效。',
      );
    }
  }

  bool _bytesEqual(Uint8List left, Uint8List right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> _decodeObject(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      return decoded;
    } on Object {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '备份 JSON 结构无效。',
      );
    }
  }

  List<dynamic> _decodeArray(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! List<dynamic>) {
        throw const FormatException();
      }
      return decoded;
    } on Object {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '旧版备份 JSON 结构无效。',
      );
    }
  }

  Map<String, dynamic> _asObject(dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        '备份清单对象结构无效。',
      );
    }
    return value;
  }

  int _positiveInt(dynamic value, String message) {
    if (value is! int || value <= 0) {
      throw BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        message,
      );
    }
    return value;
  }

  int _positiveOrZeroInt(dynamic value, String message) {
    if (value is! int || value < 0) {
      throw BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        message,
      );
    }
    return value;
  }

  String _shaString(dynamic value) {
    if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidSchema,
        'SHA-256 字段格式无效。',
      );
    }
    return value;
  }

  File _entryFile(Directory root, String archivePath) {
    var path = root.path;
    for (final segment in archivePath.split('/')) {
      path = _join(path, segment);
    }
    return File(path);
  }

  String _extensionOf(String path) => path.substring(path.lastIndexOf('.') + 1);

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }

  String _join(String parent, String child) {
    return '$parent${Platform.pathSeparator}${child.replaceAll('/', Platform.pathSeparator)}';
  }

  bool _isPathWithin(String candidate, String root) {
    final normalizedCandidate = _normalizedPath(candidate);
    final normalizedRoot = _normalizedPath(root);
    return normalizedCandidate.startsWith(
      '$normalizedRoot${Platform.pathSeparator}',
    );
  }

  String _normalizedAbsolute(String path) {
    return _normalizedPath(File(path).absolute.path);
  }

  String _normalizedPath(String path) {
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  String _nonce() {
    final sequence = _globalSequence++;
    return '${_timestampProvider().toUtc().microsecondsSinceEpoch}-$sequence';
  }

  Future<void> _fault(BackupRestoreFaultPoint point) async {
    await _faultInjector?.call(point);
  }

  Future<void> _deleteFileBestEffort(File file) async {
    try {
      await _fileSystem.deleteFile(file);
    } catch (_) {
      // Only narrowly scoped temporary files are passed here. A later run can
      // safely retry cleanup without hiding the primary operation result.
    }
  }

  Future<void> _deleteWorkspaceBestEffort(Directory directory) async {
    await _markWorkspaceCleanupPendingBestEffort(directory);
    await _deleteDirectoryBestEffort(directory);
  }

  Future<void> _markWorkspaceCleanupPendingBestEffort(
    Directory directory,
  ) async {
    try {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      final owner = await _readSmallJsonObject(
        File(_join(directory.path, _workspaceMarkerName)),
        maxBytes: 4096,
      );
      if (owner == null ||
          owner.length != 6 ||
          owner['schemaVersion'] != 1 ||
          owner['kind'] != 'wujian-backup-workspace' ||
          owner['directoryName'] != _basename(directory.path) ||
          owner['ownerProcessId'] != pid ||
          !_isValidMarkerTimestamp(owner['createdAt'])) {
        return;
      }
      final marker = File(_join(directory.path, _workspaceCleanupMarkerName));
      if (await FileSystemEntity.type(marker.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return;
      }
      await _writeOwnedMarker(marker, <String, dynamic>{
        'schemaVersion': 1,
        'kind': 'wujian-backup-cleanup-pending',
        'directoryName': _basename(directory.path),
      });
    } on Object {
      // The workspace deletion below is still attempted. If both marking and
      // deletion fail, the intact active marker makes the next operation busy
      // instead of allowing unbounded same-PID workspace accumulation.
    }
  }

  Future<void> _deleteDirectoryBestEffort(Directory directory) async {
    try {
      await _fileSystem.deleteDirectory(directory);
    } catch (_) {
      // Only the unique operation workspace is eligible for this cleanup.
    }
  }
}

class _PreparedExport {
  const _PreparedExport(this.snapshot, this.media);

  final CatalogSnapshot snapshot;
  final List<_ValidatedMedia> media;
}

class _PreparedMediaPublication {
  const _PreparedMediaPublication(this.temporary, this.target, this.entry);

  final File temporary;
  final File target;
  final BackupMediaManifestEntry entry;
}

class _RestoreMediaPlan {
  const _RestoreMediaPlan(this.media, this.target);

  final _ValidatedMedia media;
  final File target;
}

class _ZipEntryMetadata {
  const _ZipEntryMetadata({
    required this.path,
    required this.versionMadeBy,
    required this.externalFileAttributes,
    required this.compressionMethod,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.dataOffset,
  });

  final String path;
  final int versionMadeBy;
  final int externalFileAttributes;
  final int compressionMethod;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int dataOffset;
}

class _ZipOccupiedRange {
  const _ZipOccupiedRange(this.start, this.end);

  final int start;
  final int end;
}

class _ValidatedPackage {
  const _ValidatedPackage(this.snapshot, this.inspection, this.media);

  final CatalogSnapshot snapshot;
  final BackupPackageInspection inspection;
  final Map<String, _ValidatedMedia> media;
}

class _ValidatedMedia {
  const _ValidatedMedia(this.entry, this.file);

  final BackupMediaManifestEntry entry;
  final File file;
}

class _ExtractionBudget {
  _ExtractionBudget(this.limit);

  final int limit;
  int used = 0;

  void add(int count) {
    if (count < 0 || used + count > limit) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.expandedSizeExceeded,
        '备份包实际展开大小超过限制。',
      );
    }
    used += count;
  }
}

class _BoundedFileOutput extends OutputStreamBase {
  _BoundedFileOutput(
    String path, {
    required this.entryLimit,
    required this.budget,
  }) : _delegate = OutputFileStream(path);

  final int entryLimit;
  final _ExtractionBudget budget;
  final OutputFileStream _delegate;
  final Crc32 _crc = Crc32();
  var _length = 0;
  var _closed = false;

  @override
  int get length => _length;

  int get crc32 => _crc.hash;

  @override
  void flush() => _delegate.flush();

  void closeSync() {
    if (_closed) {
      return;
    }
    _closed = true;
    _delegate.closeSync();
  }

  @override
  void writeByte(int value) {
    _write(Uint8List.fromList(<int>[value & 0xff]));
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    final actualLength = len ?? bytes.length;
    if (actualLength < 0 || actualLength > bytes.length) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.invalidArchive,
        '备份解压数据长度无效。',
      );
    }
    if (actualLength == bytes.length) {
      _write(bytes);
    } else {
      _write(bytes.sublist(0, actualLength));
    }
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    const chunkSize = 64 * 1024;
    while (!stream.isEOS) {
      final count = math.min(chunkSize, stream.length);
      if (count <= 0) {
        break;
      }
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  @override
  void writeUint16(int value) {
    writeBytes(<int>[value & 0xff, (value >> 8) & 0xff]);
  }

  @override
  void writeUint32(int value) {
    writeBytes(<int>[
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ]);
  }

  @override
  void writeUint64(int value) {
    writeBytes(<int>[
      for (var shift = 0; shift < 64; shift += 8) (value >> shift) & 0xff,
    ]);
  }

  void _write(List<int> bytes) {
    if (_closed) {
      throw StateError('output is closed');
    }
    if (_length + bytes.length > entryLimit) {
      throw const BackupRestoreException(
        BackupRestoreErrorCode.expandedSizeExceeded,
        '单个备份条目实际展开大小超过限制。',
      );
    }
    budget.add(bytes.length);
    _delegate.writeBytes(bytes);
    _crc.add(bytes);
    _length += bytes.length;
  }
}

class _CleanupResult {
  const _CleanupResult(this.deleted, this.retained);

  final int deleted;
  final int retained;
}
