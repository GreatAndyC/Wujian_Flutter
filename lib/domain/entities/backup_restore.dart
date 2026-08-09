import 'dart:io';

import '../repositories/catalog_repository.dart';

enum BackupRestoreMode { replace, merge }

enum BackupRestoreOperation { create, validate, restore }

enum BackupRestoreStatus { idle, running, succeeded, failed }

enum BackupRestoreErrorCode {
  busy,
  invalidFileName,
  sourceMissing,
  invalidArchive,
  unsupportedVersion,
  invalidSchema,
  unsafePath,
  symbolicLink,
  duplicateEntry,
  entryLimitExceeded,
  expandedSizeExceeded,
  storageLimitExceeded,
  compressionRatioExceeded,
  missingMedia,
  invalidReference,
  sizeMismatch,
  hashMismatch,
  invalidMedia,
  writeFailed,
  rollbackFailed,
}

class BackupRestoreException implements Exception {
  const BackupRestoreException(this.code, this.message);

  final BackupRestoreErrorCode code;
  final String message;

  @override
  String toString() => message;
}

class BackupRestoreLimits {
  const BackupRestoreLimits({
    this.maxArchiveBytes = 512 * 1024 * 1024,
    this.maxEntries = 10000,
    this.maxSingleEntryBytes = 32 * 1024 * 1024,
    this.maxExpandedBytes = 1024 * 1024 * 1024,
    this.maxCompressionRatio = 200,
    this.maxCatalogBytes = 16 * 1024 * 1024,
    this.maxMediaFiles = 9998,
    this.maxImageDimension = 4096,
    this.maxImagePixels = 16 * 1024 * 1024,
    this.maxStoredBackupBytes = 1024 * 1024 * 1024,
    this.maxStoredBackupFiles = 8,
  }) : assert(maxArchiveBytes > 0),
       assert(maxEntries > 0),
       assert(maxSingleEntryBytes > 0),
       assert(maxExpandedBytes > 0),
       assert(maxCompressionRatio > 0),
       assert(maxCatalogBytes > 0),
       assert(maxMediaFiles > 0),
       assert(maxImageDimension > 0),
       assert(maxImagePixels > 0),
       assert(maxStoredBackupBytes > 0),
       assert(maxStoredBackupFiles > 0);

  final int maxArchiveBytes;
  final int maxEntries;
  final int maxSingleEntryBytes;
  final int maxExpandedBytes;
  final double maxCompressionRatio;
  final int maxCatalogBytes;
  final int maxMediaFiles;
  final int maxImageDimension;
  final int maxImagePixels;
  final int maxStoredBackupBytes;
  final int maxStoredBackupFiles;
}

class BackupMediaManifestEntry {
  const BackupMediaManifestEntry({
    required this.path,
    required this.byteLength,
    required this.sha256,
  });

  final String path;
  final int byteLength;
  final String sha256;
}

class BackupPackageInspection {
  const BackupPackageInspection({
    required this.formatVersion,
    required this.createdAt,
    required this.itemCount,
    required this.pendingItemCount,
    required this.mediaCount,
    required this.mediaBytes,
    required this.legacyMigrated,
  });

  final int formatVersion;
  final DateTime createdAt;
  final int itemCount;
  final int pendingItemCount;
  final int mediaCount;
  final int mediaBytes;
  final bool legacyMigrated;
}

class BackupCreateResult {
  const BackupCreateResult({
    required this.file,
    required this.inspection,
    required this.packageBytes,
  });

  final File file;
  final BackupPackageInspection inspection;
  final int packageBytes;
}

class BackupRestoreResult {
  const BackupRestoreResult({
    required this.snapshot,
    required this.inspection,
    required this.mode,
    required this.createdMediaCount,
    required this.deletedOrphanCount,
    required this.retainedOrphanCount,
  });

  final CatalogSnapshot snapshot;
  final BackupPackageInspection inspection;
  final BackupRestoreMode mode;
  final int createdMediaCount;
  final int deletedOrphanCount;
  final int retainedOrphanCount;
}

abstract interface class BackupRestoreOperations {
  Future<BackupCreateResult> createBackup({String baseName = 'wujian-backup'});

  Future<BackupPackageInspection> validateBackup(File file);

  Future<BackupRestoreResult> restoreBackup(
    File file, {
    BackupRestoreMode mode = BackupRestoreMode.replace,
  });
}
