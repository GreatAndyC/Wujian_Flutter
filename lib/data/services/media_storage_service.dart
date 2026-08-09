import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/storage_usage_summary.dart';
import 'storage_mutation_coordinator.dart';

typedef StorageDirectoryProvider = Future<Directory> Function();
typedef StorageTimestampProvider = DateTime Function();

const _maxSourceImageDimension = 4096;
const _maxSourceImagePixels = 16 * 1024 * 1024;

class MediaStorageService {
  MediaStorageService({
    StorageDirectoryProvider? documentsDirectoryProvider,
    StorageDirectoryProvider? temporaryDirectoryProvider,
    StorageTimestampProvider? timestampProvider,
  }) : _documentsDirectoryProvider =
           documentsDirectoryProvider ?? getApplicationDocumentsDirectory,
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _timestampProvider = timestampProvider ?? DateTime.now;

  static const _maxRetainedExports = 6;
  static const _automaticCacheRetention = Duration(hours: 1);

  final StorageDirectoryProvider _documentsDirectoryProvider;
  final StorageDirectoryProvider _temporaryDirectoryProvider;
  final StorageTimestampProvider _timestampProvider;
  Future<void> _storageMutation = Future.value();
  var _exportSequence = 0;

  /// Runs a catalog-and-media mutation under one shared documents-root lock.
  ///
  /// Calls to this service or to a coordinated catalog repository from inside
  /// [action] re-enter the same Zone-owned coordinator slot. The method
  /// deliberately does not take the instance-only media gate itself, because
  /// an inner [persistImage] or [optimizeStorage] call owns that narrower gate.
  Future<T> runStorageTransaction<T>(Future<T> Function() action) {
    return StorageMutationCoordinator.shared.runWithRootProvider(
      _documentsDirectoryProvider,
      (_) => action(),
      rejectWhenExclusive: true,
    );
  }

  Future<File> persistImage(File source, {bool deleteTemporarySource = true}) {
    return _coordinateMutation((canonicalRoot) async {
      if (!await source.exists()) {
        throw const FileSystemException('拍摄的临时图片不存在');
      }

      try {
        final sourceBytes = await source.readAsBytes();
        if (sourceBytes.isEmpty) {
          throw const FormatException('拍摄的图片内容为空');
        }
        final prepared = await _preparePersistedImageInBackground(sourceBytes);
        final imagesDirectory = await _imagesDirectory(canonicalRoot);
        final target = await _resolveTarget(
          imagesDirectory,
          prepared.bytes,
          prepared.candidateDigest,
          prepared.collisionDigest,
        );

        if (await target.exists()) {
          if (deleteTemporarySource) {
            await _cleanupSource(source, target.path);
          }
          return target;
        }

        await _writeBytesAtomically(target, prepared.bytes);
        if (deleteTemporarySource) {
          await _cleanupSource(source, target.path);
        }
        return target;
      } catch (_) {
        // A failed camera capture is safe to remove only when it lives under
        // the app's temporary directory. Never touch arbitrary user files.
        if (deleteTemporarySource) {
          try {
            await _cleanupSource(source, '');
          } catch (_) {
            // Preserve the original persistence error.
          }
        }
        rethrow;
      }
    });
  }

  Future<void> deleteTransientSource(File source) {
    return _coordinateMutation((_) => _cleanupSource(source, ''));
  }

  Future<StorageUsageSummary> computeUsage() {
    return StorageMutationCoordinator.shared.runWithRootProvider(
      _documentsDirectoryProvider,
      (canonicalRoot) async {
        final imagesDirectory = await _imagesDirectory(canonicalRoot);
        final tempDirectory = await _temporaryDirectory();
        final tempExports = await _requiredDirectoryNoFollow(
          Directory('${tempDirectory.path}${Platform.pathSeparator}exports'),
          errorMessage: '临时导出目录不可用',
        );
        final legacyExportsDirectory = await _optionalDirectoryNoFollow(
          Directory('${canonicalRoot.path}${Platform.pathSeparator}exports'),
        );

        final imageFiles = (await _listFiles(
          imagesDirectory,
        )).where(_isSupportedImageFile).toList();
        final cachedExports = await _listFiles(tempExports);
        final legacyExports = legacyExportsDirectory == null
            ? const <File>[]
            : await _listFiles(legacyExportsDirectory);
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
      },
      rejectWhenExclusive: true,
    );
  }

  /// Resolves a catalog image reference without trusting the process working
  /// directory. Relative references are anchored to the canonical documents
  /// root and must remain inside it after lexical and symbolic-link resolution.
  Future<File?> resolveImageReference(String imagePath) {
    return StorageMutationCoordinator.shared.runWithRootProvider(
      _documentsDirectoryProvider,
      (canonicalRoot) => _resolveImageReference(canonicalRoot, imagePath),
      rejectWhenExclusive: true,
    );
  }

  Future<void> optimizeStorage({
    required Iterable<String> referencedImagePaths,
  }) {
    final rawReferences = referencedImagePaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();
    return _coordinateMutation((canonicalRoot) async {
      final referenced = <String>{};
      for (final path in rawReferences) {
        final resolved = await _resolveImageReference(canonicalRoot, path);
        if (resolved != null) {
          referenced.add(_normalizedAbsolute(resolved.path));
        }
      }
      final imagesDirectory = await _imagesDirectory(canonicalRoot);
      final imageFiles = await _listFiles(imagesDirectory);
      for (final file in imageFiles) {
        if (_isManagedImageFile(file) &&
            !referenced.contains(_normalizedAbsolute(file.path))) {
          await _safeDelete(file);
        }
      }

      await _pruneTransientCaptureCache(olderThan: _automaticCacheRetention);
      await _pruneExports(canonicalRoot);
    });
  }

  Future<void> pruneExports({Iterable<String> protectedPaths = const []}) {
    final protected = protectedPaths.map(_normalizedAbsolute).toSet();
    return _coordinateMutation(
      (canonicalRoot) =>
          _pruneExports(canonicalRoot, protectedPaths: protected),
    );
  }

  Future<void> clearTransientCache() {
    return _coordinateMutation((canonicalRoot) async {
      await _pruneTransientCaptureCache();
      await _pruneExports(canonicalRoot);
    });
  }

  Future<Directory> exportsDirectory() async {
    final tempDirectory = await _temporaryDirectory();
    return _requiredDirectoryNoFollow(
      Directory('${tempDirectory.path}${Platform.pathSeparator}exports'),
      errorMessage: '临时导出目录不可用',
    );
  }

  Future<File> writeExportBytes({
    required String baseName,
    required String extension,
    required List<int> bytes,
  }) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(baseName)) {
      throw ArgumentError.value(baseName, 'baseName', '导出文件基名不安全');
    }
    final lowerCaseExtension = extension.toLowerCase();
    final normalizedExtension = lowerCaseExtension.startsWith('.')
        ? lowerCaseExtension.substring(1)
        : lowerCaseExtension;
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(normalizedExtension)) {
      throw ArgumentError.value(extension, 'extension', '导出文件扩展名不安全');
    }
    final payload = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    return _coordinateMutation((canonicalRoot) async {
      final directory = await exportsDirectory();
      final timestamp = _timestampProvider().toUtc().microsecondsSinceEpoch;
      for (var attempt = 0; attempt < 1000; attempt++) {
        final sequence = _exportSequence++;
        final file = File(
          '${directory.path}${Platform.pathSeparator}'
          '$baseName-$timestamp-$sequence.$normalizedExtension',
        );
        if (await file.exists()) {
          continue;
        }
        await _writeBytesAtomically(file, payload);
        await _pruneExports(
          canonicalRoot,
          protectedPaths: {_normalizedAbsolute(file.path)},
        );
        return file;
      }
      throw const FileSystemException('无法为导出文件分配唯一名称');
    });
  }

  Future<void> _pruneExports(
    Directory canonicalRoot, {
    Set<String> protectedPaths = const {},
  }) async {
    final tempDirectory = await _temporaryDirectory();
    final tempExports = await _requiredDirectoryNoFollow(
      Directory('${tempDirectory.path}${Platform.pathSeparator}exports'),
      errorMessage: '临时导出目录不可用',
    );
    final legacyExports = await _optionalDirectoryNoFollow(
      Directory('${canonicalRoot.path}${Platform.pathSeparator}exports'),
    );

    final tempFiles = await _listFiles(tempExports);
    if (tempFiles.length > _maxRetainedExports) {
      final filesWithStats = await Future.wait(
        tempFiles.map((file) async => (file: file, stat: await file.stat())),
      );
      filesWithStats.sort((left, right) {
        final leftProtected = protectedPaths.contains(
          _normalizedAbsolute(left.file.path),
        );
        final rightProtected = protectedPaths.contains(
          _normalizedAbsolute(right.file.path),
        );
        if (leftProtected != rightProtected) {
          return leftProtected ? -1 : 1;
        }
        return right.stat.modified.compareTo(left.stat.modified);
      });
      for (final entry in filesWithStats.skip(_maxRetainedExports)) {
        await _safeDelete(entry.file);
      }
    }

    if (legacyExports != null) {
      final oldFiles = await _listFiles(legacyExports);
      for (final file in oldFiles) {
        await _safeDelete(file);
      }
    }
  }

  Future<void> _pruneTransientCaptureCache({Duration? olderThan}) async {
    final tempDirectory = await _temporaryDirectory();
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

  Future<Directory> _imagesDirectory(Directory canonicalRoot) {
    return _requiredDirectoryNoFollow(
      Directory('${canonicalRoot.path}${Platform.pathSeparator}images'),
      errorMessage: '图片存储目录不可用',
    );
  }

  Future<Directory> _temporaryDirectory() async {
    try {
      final supplied = await _temporaryDirectoryProvider();
      if (await FileSystemEntity.type(supplied.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FileSystemException('临时存储目录不可用');
      }
      return supplied;
    } on Object {
      throw const FileSystemException('临时存储目录不可用');
    }
  }

  Future<Directory> _requiredDirectoryNoFollow(
    Directory directory, {
    required String errorMessage,
  }) async {
    try {
      var type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) {
        await directory.create();
        type = await FileSystemEntity.type(directory.path, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException(errorMessage);
      }
      return directory;
    } on Object {
      throw FileSystemException(errorMessage);
    }
  }

  Future<Directory?> _optionalDirectoryNoFollow(Directory directory) async {
    try {
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      return type == FileSystemEntityType.directory ? directory : null;
    } on Object {
      return null;
    }
  }

  Future<File?> _resolveImageReference(
    Directory canonicalRoot,
    String imagePath,
  ) async {
    final trimmed = imagePath.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      final supplied = File(trimmed);
      final isRelative = !supplied.isAbsolute;
      final candidatePath = isRelative
          ? _normalizedAbsolute(
              '${canonicalRoot.path}${Platform.pathSeparator}$trimmed',
            )
          : _normalizedAbsolute(trimmed);
      final canonicalRootPath = _normalizedAbsolute(canonicalRoot.path);
      if (isRelative && !_isPathWithin(candidatePath, canonicalRootPath)) {
        return null;
      }
      if (await FileSystemEntity.type(candidatePath, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final resolved = _normalizedPath(
        await File(candidatePath).resolveSymbolicLinks(),
      );
      if (isRelative && !_isPathWithin(resolved, canonicalRootPath)) {
        return null;
      }
      return File(resolved);
    } on Object {
      return null;
    }
  }

  Future<List<File>> _listFiles(
    Directory directory, {
    bool recursive = false,
  }) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
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
    try {
      if (source.path == persistedPath || !await source.exists()) {
        return;
      }
      final tempDirectory = await _temporaryDirectoryProvider();
      final resolvedTempRoot = await tempDirectory.resolveSymbolicLinks();
      final resolvedSource = await source.resolveSymbolicLinks();
      if (persistedPath.isNotEmpty) {
        final persisted = File(persistedPath);
        if (await persisted.exists() &&
            await persisted.resolveSymbolicLinks() == resolvedSource) {
          return;
        }
      }
      if (_isPathWithin(resolvedSource, resolvedTempRoot)) {
        await _safeDelete(source);
      }
    } catch (_) {
      // Cleanup is best effort. If paths cannot be canonicalized, refusing
      // deletion is safer and must not turn a successful persistence into a
      // reported failure.
    }
  }

  bool _isPathWithin(String candidate, String root) {
    final normalizedCandidate = _normalizedPath(candidate);
    final normalizedRoot = _normalizedPath(root);
    return normalizedCandidate.startsWith(
      '$normalizedRoot${Platform.pathSeparator}',
    );
  }

  String _normalizedAbsolute(String path) {
    final absolute = File(path).absolute.uri.normalizePath().toFilePath();
    return _normalizedPath(absolute);
  }

  String _normalizedPath(String path) {
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  bool _isSupportedImageFile(File file) {
    final lowerPath = file.path.toLowerCase();
    return lowerPath.endsWith('.jpg') ||
        lowerPath.endsWith('.jpeg') ||
        lowerPath.endsWith('.png') ||
        lowerPath.endsWith('.webp') ||
        lowerPath.endsWith('.heic');
  }

  bool _isManagedImageFile(File file) {
    if (_isSupportedImageFile(file)) {
      return true;
    }
    final fileName = file.uri.pathSegments.last.toLowerCase();
    return RegExp(
      r'^(?:v2-)?[0-9a-f]{64}\.(?:jpe?g|png|webp|heic)\.tmp-[a-z0-9_-]+$',
    ).hasMatch(fileName);
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

  Future<File> _resolveTarget(
    Directory imagesDirectory,
    Uint8List encoded,
    String candidateDigest,
    String collisionDigest,
  ) async {
    final exactDigest = sha256.convert(encoded).toString();
    for (var attempt = 0; attempt < 32; attempt++) {
      final digest = switch (attempt) {
        0 => candidateDigest,
        1 => collisionDigest,
        2 => exactDigest,
        _ => sha256.convert([...exactDigest.codeUnits, attempt]).toString(),
      };
      final target = File(
        '${imagesDirectory.path}${Platform.pathSeparator}v2-$digest.jpg',
      );
      if (!await target.exists()) {
        return target;
      }
      if (await _imagesAreVisuallyEquivalent(target, encoded)) {
        return target;
      }
    }
    throw const FileSystemException('无法为图片分配安全的存储文件名');
  }

  Future<bool> _imagesAreVisuallyEquivalent(
    File existing,
    Uint8List candidate,
  ) async {
    try {
      final existingBytes = await existing.readAsBytes();
      if (existingBytes.isEmpty) {
        return false;
      }
      return Isolate.run(
        () => _arePreparedImagesVisuallyEquivalent(existingBytes, candidate),
      );
    } on FileSystemException {
      return false;
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

  Future<T> _coordinateMutation<T>(
    Future<T> Function(Directory canonicalRoot) action,
  ) {
    return StorageMutationCoordinator.shared.runWithRootProvider(
      _documentsDirectoryProvider,
      (canonicalRoot) => _serializeMutation(() => action(canonicalRoot)),
      rejectWhenExclusive: true,
    );
  }
}

Future<({Uint8List bytes, String candidateDigest, String collisionDigest})>
_preparePersistedImageInBackground(Uint8List sourceBytes) {
  return Isolate.run(() {
    final encoded = _preparePersistedJpeg(
      sourceBytes,
      maxImageDimension: 2048,
      maxSourceImageDimension: _maxSourceImageDimension,
      maxSourceImagePixels: _maxSourceImagePixels,
      jpegQuality: 82,
    );
    final digests = _preparedImageDigests(encoded);
    return (
      bytes: encoded,
      candidateDigest: digests.candidate,
      collisionDigest: digests.collision,
    );
  });
}

({String candidate, String collision}) _preparedImageDigests(
  Uint8List encoded,
) {
  final decoded = img.decodeImage(encoded);
  if (decoded == null) {
    final fallback = sha256.convert(encoded).toString();
    return (candidate: fallback, collision: fallback);
  }

  final candidateSignature = <int>[
    ..._uint32Bytes(decoded.width),
    ..._uint32Bytes(decoded.height),
  ];
  final collisionSignature = <int>[
    ..._uint32Bytes(decoded.width),
    ..._uint32Bytes(decoded.height),
  ];
  final collisionThumbnail = img.copyResize(
    decoded,
    width: 64,
    height: 64,
    interpolation: img.Interpolation.average,
  );
  final hashThumbnail = img.copyResize(
    collisionThumbnail,
    width: 8,
    height: 8,
    interpolation: img.Interpolation.average,
  );
  final luminance = <int>[
    for (final pixel in hashThumbnail) _pixelLuminance(pixel),
  ];
  final average =
      luminance.reduce((left, right) => left + right) / luminance.length;
  for (var offset = 0; offset < luminance.length; offset += 8) {
    var value = 0;
    for (var bit = 0; bit < 8; bit++) {
      if (luminance[offset + bit] >= average) {
        value |= 1 << bit;
      }
    }
    candidateSignature.add(value);
  }
  for (final pixel in collisionThumbnail) {
    collisionSignature
      ..add(_channelByte(pixel.r))
      ..add(_channelByte(pixel.g))
      ..add(_channelByte(pixel.b));
  }

  return (
    candidate: sha256.convert(candidateSignature).toString(),
    collision: sha256.convert(collisionSignature).toString(),
  );
}

bool _arePreparedImagesVisuallyEquivalent(
  Uint8List firstBytes,
  Uint8List secondBytes,
) {
  try {
    final first = img.decodeImage(firstBytes);
    final second = img.decodeImage(secondBytes);
    if (first == null ||
        second == null ||
        first.width != second.width ||
        first.height != second.height) {
      return false;
    }

    const comparisonDimension = 64;
    final firstThumbnail = img.copyResize(
      first,
      width: comparisonDimension,
      height: comparisonDimension,
      interpolation: img.Interpolation.average,
    );
    final secondThumbnail = img.copyResize(
      second,
      width: comparisonDimension,
      height: comparisonDimension,
      interpolation: img.Interpolation.average,
    );
    var absoluteDifference = 0.0;
    var squaredDifference = 0.0;
    var changedPixels = 0;
    var firstRed = 0.0;
    var firstGreen = 0.0;
    var firstBlue = 0.0;
    var secondRed = 0.0;
    var secondGreen = 0.0;
    var secondBlue = 0.0;

    for (var y = 0; y < comparisonDimension; y++) {
      for (var x = 0; x < comparisonDimension; x++) {
        final firstPixel = firstThumbnail.getPixel(x, y);
        final secondPixel = secondThumbnail.getPixel(x, y);
        final redDifference =
            (_channelByte(firstPixel.r) - _channelByte(secondPixel.r)).abs();
        final greenDifference =
            (_channelByte(firstPixel.g) - _channelByte(secondPixel.g)).abs();
        final blueDifference =
            (_channelByte(firstPixel.b) - _channelByte(secondPixel.b)).abs();
        absoluteDifference += redDifference + greenDifference + blueDifference;
        squaredDifference +=
            redDifference * redDifference +
            greenDifference * greenDifference +
            blueDifference * blueDifference;
        if (redDifference > 16 || greenDifference > 16 || blueDifference > 16) {
          changedPixels++;
        }
        firstRed += _channelByte(firstPixel.r);
        firstGreen += _channelByte(firstPixel.g);
        firstBlue += _channelByte(firstPixel.b);
        secondRed += _channelByte(secondPixel.r);
        secondGreen += _channelByte(secondPixel.g);
        secondBlue += _channelByte(secondPixel.b);
      }
    }

    const pixelCount = comparisonDimension * comparisonDimension;
    const channelCount = pixelCount * 3;
    final meanAbsoluteDifference = absoluteDifference / channelCount;
    final meanSquaredDifference = squaredDifference / channelCount;
    final changedFraction = changedPixels / pixelCount;
    final averageRedDifference = (firstRed - secondRed).abs() / pixelCount;
    final averageGreenDifference =
        (firstGreen - secondGreen).abs() / pixelCount;
    final averageBlueDifference = (firstBlue - secondBlue).abs() / pixelCount;

    return meanAbsoluteDifference <= 3.5 &&
        meanSquaredDifference <= 25 &&
        changedFraction <= 0.02 &&
        averageRedDifference <= 2 &&
        averageGreenDifference <= 2 &&
        averageBlueDifference <= 2;
  } catch (_) {
    return false;
  }
}

List<int> _uint32Bytes(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

int _pixelLuminance(img.Pixel pixel) {
  return ((299 * _channelByte(pixel.r) +
              587 * _channelByte(pixel.g) +
              114 * _channelByte(pixel.b)) /
          1000)
      .round();
}

int _channelByte(num value) => value.round().clamp(0, 255).toInt();

Uint8List _preparePersistedJpeg(
  Uint8List sourceBytes, {
  required int maxImageDimension,
  required int maxSourceImageDimension,
  required int maxSourceImagePixels,
  required int jpegQuality,
}) {
  img.Image? decoded;
  try {
    final decoder = img.findDecoderForData(sourceBytes);
    final info = decoder?.startDecode(sourceBytes);
    if (decoder == null ||
        info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width > maxSourceImageDimension ||
        info.height > maxSourceImageDimension ||
        info.width * info.height > maxSourceImagePixels) {
      throw const FormatException('拍摄的图片尺寸不安全');
    }
    decoded = decoder.decodeFrame(0);
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('无法解码拍摄的图片');
  }
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
