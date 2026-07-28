import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/storage_usage_summary.dart';

typedef StorageDirectoryProvider = Future<Directory> Function();

class MediaStorageService {
  MediaStorageService({
    StorageDirectoryProvider? documentsDirectoryProvider,
    StorageDirectoryProvider? temporaryDirectoryProvider,
  }) : _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory,
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory;

  static const _maxRetainedExports = 6;
  static const _automaticCacheRetention = Duration(hours: 1);

  final StorageDirectoryProvider _documentsDirectoryProvider;
  final StorageDirectoryProvider _temporaryDirectoryProvider;
  Future<void> _storageMutation = Future.value();

  Future<File> persistImage(File source) {
    return _serializeMutation(() async {
      if (!await source.exists()) {
        throw const FileSystemException('拍摄的临时图片不存在');
      }

      final sourceBytes = await source.readAsBytes();
      if (sourceBytes.isEmpty) {
        throw const FormatException('拍摄的图片内容为空');
      }
      final encoded = await _preparePersistedJpegInBackground(sourceBytes);
      final digest = sha256.convert(encoded).toString();
      final imagesDirectory = await _imagesDirectory();
      final target = File(
        '${imagesDirectory.path}${Platform.pathSeparator}$digest.jpg',
      );

      if (await target.exists()) {
        await _cleanupSource(source, target.path);
        return target;
      }

      await _writeBytesAtomically(target, encoded);
      await _cleanupSource(source, target.path);
      return target;
    });
  }

  Future<StorageUsageSummary> computeUsage() async {
    final imagesDirectory = await _imagesDirectory();
    final tempDirectory = await _temporaryDirectoryProvider();
    final legacyDocumentsDirectory = await _documentsDirectoryProvider();

    final imageFiles = await _listFiles(imagesDirectory);
    final cachedExports = await _listFiles(
      Directory('${tempDirectory.path}${Platform.pathSeparator}exports'),
    );
    final legacyExports = await _listFiles(
      Directory(
        '${legacyDocumentsDirectory.path}${Platform.pathSeparator}exports',
      ),
    );
    final captureCacheFiles = await _captureCacheFiles(tempDirectory);
    final allExports = [...cachedExports, ...legacyExports];

    return StorageUsageSummary(
      imageCount: imageFiles.length,
      imageBytes: await _sumFileSizes(imageFiles),
      captureCacheCount: captureCacheFiles.length,
      captureCacheBytes: await _sumFileSizes(captureCacheFiles),
      exportCount: allExports.length,
      exportBytes: await _sumFileSizes(allExports),
    );
  }

  Future<void> optimizeStorage({
    required Iterable<String> referencedImagePaths,
  }) {
    final referenced = referencedImagePaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();
    return _serializeMutation(() async {
      final imagesDirectory = await _imagesDirectory();
      final imageFiles = await _listFiles(imagesDirectory);
      for (final file in imageFiles) {
        if (!referenced.contains(file.path)) {
          await _safeDelete(file);
        }
      }

      await _pruneTransientCaptureCache(olderThan: _automaticCacheRetention);
      await _pruneExports();
    });
  }

  Future<void> pruneExports() {
    return _serializeMutation(_pruneExports);
  }

  Future<void> clearTransientCache() {
    return _serializeMutation(() async {
      await _pruneTransientCaptureCache();
      await _pruneExports();
    });
  }

  Future<Directory> exportsDirectory() async {
    final tempDirectory = await _temporaryDirectoryProvider();
    final directory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}exports',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _pruneExports() async {
    final tempDirectory = await _temporaryDirectoryProvider();
    final tempExports = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}exports',
    );
    await tempExports.create(recursive: true);

    final legacyDocumentsDirectory = await _documentsDirectoryProvider();
    final legacyExports = Directory(
      '${legacyDocumentsDirectory.path}${Platform.pathSeparator}exports',
    );

    final tempFiles = await _listFiles(tempExports);
    if (tempFiles.length > _maxRetainedExports) {
      final filesWithStats = await Future.wait(
        tempFiles.map((file) async => (file: file, stat: await file.stat())),
      );
      filesWithStats.sort(
        (left, right) => right.stat.modified.compareTo(left.stat.modified),
      );
      for (final entry in filesWithStats.skip(_maxRetainedExports)) {
        await _safeDelete(entry.file);
      }
    }

    final oldFiles = await _listFiles(legacyExports);
    for (final file in oldFiles) {
      await _safeDelete(file);
    }
  }

  Future<void> _pruneTransientCaptureCache({Duration? olderThan}) async {
    final tempDirectory = await _temporaryDirectoryProvider();
    final files = await _captureCacheFiles(tempDirectory);
    final cutoff = olderThan == null
        ? null
        : DateTime.now().subtract(olderThan);
    for (final file in files) {
      if (cutoff != null) {
        final stat = await file.stat();
        if (!stat.modified.isBefore(cutoff)) {
          continue;
        }
      }
      await _safeDelete(file);
    }
  }

  Future<List<File>> _captureCacheFiles(Directory tempDirectory) async {
    final exportsPath =
        '${tempDirectory.path}${Platform.pathSeparator}exports${Platform.pathSeparator}';
    final files = await _listFiles(tempDirectory, recursive: true);
    return files.where((file) {
      final lowerPath = file.path.toLowerCase();
      if (lowerPath.startsWith(exportsPath.toLowerCase())) {
        return false;
      }
      return lowerPath.endsWith('.jpg') ||
          lowerPath.endsWith('.jpeg') ||
          lowerPath.endsWith('.png') ||
          lowerPath.endsWith('.webp') ||
          lowerPath.endsWith('.heic');
    }).toList();
  }

  Future<Directory> _imagesDirectory() async {
    final root = await _documentsDirectoryProvider();
    final directory = Directory('${root.path}${Platform.pathSeparator}images');
    await directory.create(recursive: true);
    return directory;
  }

  Future<List<File>> _listFiles(
    Directory directory, {
    bool recursive = false,
  }) async {
    if (!await directory.exists()) {
      return const [];
    }

    final result = <File>[];
    await for (final entity in directory.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is File) {
        result.add(entity);
      }
    }
    return result;
  }

  Future<int> _sumFileSizes(List<File> files) async {
    var total = 0;
    for (final file in files) {
      try {
        total += (await file.stat()).size;
      } on FileSystemException {
        // The cache can change while it is being measured.
      }
    }
    return total;
  }

  Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Cache cleanup is best effort; a later optimization pass can retry.
    }
  }

  Future<void> _cleanupSource(File source, String persistedPath) async {
    final sourcePath = source.path;
    if (sourcePath == persistedPath) {
      return;
    }
    final tempDirectory = await _temporaryDirectoryProvider();
    final normalizedTempRoot =
        '${tempDirectory.absolute.path}${Platform.pathSeparator}';
    final normalizedSource = source.absolute.path;
    if (normalizedSource.startsWith(normalizedTempRoot)) {
      await _safeDelete(source);
    }
  }

  Future<void> _writeBytesAtomically(File target, Uint8List bytes) async {
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (await target.exists()) {
        await temporary.delete();
        return;
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  Future<T> _serializeMutation<T>(Future<T> Function() action) async {
    final previous = _storageMutation;
    final gate = Completer<void>();
    _storageMutation = gate.future;
    await previous.catchError((_) {});
    try {
      return await action();
    } finally {
      gate.complete();
    }
  }
}

Future<Uint8List> _preparePersistedJpegInBackground(Uint8List sourceBytes) {
  return Isolate.run(
    () => _preparePersistedJpeg(
      sourceBytes,
      maxImageDimension: 2048,
      jpegQuality: 82,
    ),
  );
}

Uint8List _preparePersistedJpeg(
  Uint8List sourceBytes, {
  required int maxImageDimension,
  required int jpegQuality,
}) {
  final decoded = img.decodeImage(sourceBytes);
  if (decoded == null) {
    throw const FormatException('无法解码拍摄的图片');
  }
  final oriented = img.bakeOrientation(decoded);
  final width = oriented.width;
  final height = oriented.height;
  final maxDimension = width > height ? width : height;
  final resized = maxDimension <= maxImageDimension
      ? oriented
      : width >= height
      ? img.copyResize(
          oriented,
          width: maxImageDimension,
          height: (height * maxImageDimension / width).round(),
          interpolation: img.Interpolation.average,
        )
      : img.copyResize(
          oriented,
          width: (width * maxImageDimension / height).round(),
          height: maxImageDimension,
          interpolation: img.Interpolation.average,
        );
  return img.encodeJpg(resized, quality: jpegQuality);
}
