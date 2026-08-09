import 'dart:io';

/// The small set of durable file operations needed by local backup flows.
///
/// Callers are responsible for mapping filesystem errors to safe domain errors
/// and for passing only narrowly scoped staging/output paths.
abstract interface class BackupFileSystem {
  Future<void> copyAndSync(File source, File destination);

  Future<void> syncFile(File file);

  Future<File> renameNew(File source, File destination);

  Future<void> deleteFile(File file);

  Future<void> deleteDirectory(Directory directory);
}

class LocalBackupFileSystem implements BackupFileSystem {
  @override
  Future<void> copyAndSync(File source, File destination) async {
    await _requireRegularFile(source, operation: '备份源文件不可用');

    var destinationCreated = false;
    IOSink? sink;
    try {
      await destination.parent.create(recursive: true);
      await destination.create(exclusive: true);
      destinationCreated = true;

      sink = destination.openWrite(mode: FileMode.writeOnly);
      await for (final chunk in source.openRead()) {
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;

      await syncFile(destination);
    } catch (error, stackTrace) {
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {
          // Preserve the original copy error.
        }
      }
      if (destinationCreated) {
        try {
          await deleteFile(destination);
        } catch (_) {
          // Preserve the original copy error.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<void> syncFile(File file) async {
    await _requireRegularFile(file, operation: '待同步文件不可用');

    RandomAccessFile? handle;
    try {
      // Append mode grants the write access required by fsync on every target
      // platform without truncating or otherwise changing the file.
      handle = await file.open(mode: FileMode.append);
      await handle.flush();
    } finally {
      await handle?.close();
    }
  }

  @override
  Future<File> renameNew(File source, File destination) async {
    await _requireRegularFile(source, operation: '待发布文件不可用');
    await _requireMissing(destination.path, operation: '发布目标已存在');

    final sourceParent = await source.parent.resolveSymbolicLinks();
    final destinationParent = await destination.parent.resolveSymbolicLinks();
    if (!_samePath(sourceParent, destinationParent)) {
      throw const FileSystemException('只允许在同一目录内原子发布文件');
    }

    // Recheck immediately before rename. Dart does not expose POSIX
    // RENAME_NOREPLACE/RENAME_EXCL portably, so the backup service also relies
    // on its isolate-local root coordinator and unique names for app-local
    // races. An uncooperative external process can still win the narrow
    // lstat-to-rename window; callers verify source disappearance and target
    // content before treating an ambiguous error as a committed publication.
    await _requireMissing(destination.path, operation: '发布目标已存在');
    return source.rename(destination.path);
  }

  @override
  Future<void> deleteFile(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return;
    }
    await file.delete();
  }

  @override
  Future<void> deleteDirectory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      return;
    }
    if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('待清理目标不是目录');
    }
    await directory.delete(recursive: true);
  }

  Future<void> _requireRegularFile(
    File file, {
    required String operation,
  }) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(operation);
    }
  }

  Future<void> _requireMissing(String path, {required String operation}) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      throw FileSystemException(operation);
    }
  }

  bool _samePath(String left, String right) {
    if (Platform.isWindows) {
      return left.toLowerCase() == right.toLowerCase();
    }
    return left == right;
  }
}
