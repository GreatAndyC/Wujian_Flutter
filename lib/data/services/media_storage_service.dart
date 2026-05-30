import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../../domain/entities/storage_usage_summary.dart';

class MediaStorageService {
  static const _maxRetainedExports = 6;
  static const _maxImageDimension = 2048;
  static const _jpegQuality = 82;

  Future<File> persistImage(File source) async {
    final imagesDirectory = await _imagesDirectory();
    final extension = _preferredOutputExtension(source.path);
    final target = File(
      '${imagesDirectory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    final bytes = await source.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      final copied = await source.copy(target.path);
      await _cleanupSource(source, copied.path);
      return copied;
    }

    final resized = _resizeIfNeeded(decoded);
    final encoded = img.encodeJpg(resized, quality: _jpegQuality);
    await target.writeAsBytes(encoded, flush: true);
    await _cleanupSource(source, target.path);
    return target;
  }

  Future<StorageUsageSummary> computeUsage() async {
    final imagesDirectory = await _imagesDirectory();
    final tempDirectory = await getTemporaryDirectory();
    final legacyDocumentsDirectory = await getApplicationDocumentsDirectory();

    final imageFiles = await _listFiles(imagesDirectory);
    final cachedExports = await _listFiles(
      Directory('${tempDirectory.path}${Platform.pathSeparator}exports'),
    );
    final legacyExports = await _listFiles(
      Directory(
        '${legacyDocumentsDirectory.path}${Platform.pathSeparator}exports',
      ),
    );
    final allExports = [...cachedExports, ...legacyExports];

    return StorageUsageSummary(
      imageCount: imageFiles.length,
      imageBytes: _sumFileSizes(imageFiles),
      exportCount: allExports.length,
      exportBytes: _sumFileSizes(allExports),
    );
  }

  Future<void> optimizeStorage({
    required Iterable<String> referencedImagePaths,
  }) async {
    final referenced = referencedImagePaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();

    final imagesDirectory = await _imagesDirectory();
    final imageFiles = await _listFiles(imagesDirectory);
    for (final file in imageFiles) {
      if (!referenced.contains(file.path)) {
        await _safeDelete(file);
      }
    }

    await pruneExports();
  }

  Future<void> pruneExports() async {
    final tempDirectory = await getTemporaryDirectory();
    final tempExports = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}exports',
    );
    await tempExports.create(recursive: true);

    final legacyDocumentsDirectory = await getApplicationDocumentsDirectory();
    final legacyExports = Directory(
      '${legacyDocumentsDirectory.path}${Platform.pathSeparator}exports',
    );

    final tempFiles = await _listFiles(tempExports);
    if (tempFiles.length > _maxRetainedExports) {
      final sorted = [
        ...tempFiles,
      ]..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      for (final file in sorted.skip(_maxRetainedExports)) {
        await _safeDelete(file);
      }
    }

    final oldFiles = await _listFiles(legacyExports);
    for (final file in oldFiles) {
      await _safeDelete(file);
    }
  }

  Future<void> clearTransientCache() async {
    final tempDirectory = await getTemporaryDirectory();
    final tempFiles = await _listFiles(tempDirectory);
    for (final file in tempFiles) {
      final name = file.uri.pathSegments.isEmpty ? '' : file.uri.pathSegments.last;
      if (name.startsWith('capture-') && name.endsWith('.jpg')) {
        await _safeDelete(file);
      }
    }
    await pruneExports();
  }

  Future<Directory> exportsDirectory() async {
    final tempDirectory = await getTemporaryDirectory();
    final directory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}exports',
    );
    await directory.create(recursive: true);
    return directory;
  }

  String _preferredOutputExtension(String path) {
    return 'jpg';
  }

  img.Image _resizeIfNeeded(img.Image image) {
    final width = image.width;
    final height = image.height;
    final maxDimension = width > height ? width : height;
    if (maxDimension <= _maxImageDimension) {
      return image;
    }
    if (width >= height) {
      final targetHeight = (height * _maxImageDimension / width).round();
      return img.copyResize(
        image,
        width: _maxImageDimension,
        height: targetHeight,
        interpolation: img.Interpolation.average,
      );
    }
    final targetWidth = (width * _maxImageDimension / height).round();
    return img.copyResize(
      image,
      width: targetWidth,
      height: _maxImageDimension,
      interpolation: img.Interpolation.average,
    );
  }

  Future<Directory> _imagesDirectory() async {
    final root = await getApplicationDocumentsDirectory();
    final directory = Directory('${root.path}${Platform.pathSeparator}images');
    await directory.create(recursive: true);
    return directory;
  }

  Future<List<File>> _listFiles(Directory directory) async {
    if (!await directory.exists()) {
      return const [];
    }

    final result = <File>[];
    await for (final entity in directory.list()) {
      if (entity is File) {
        result.add(entity);
      }
    }
    return result;
  }

  int _sumFileSizes(List<File> files) {
    var total = 0;
    for (final file in files) {
      total += file.statSync().size;
    }
    return total;
  }

  Future<void> _safeDelete(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _cleanupSource(File source, String persistedPath) async {
    final sourcePath = source.path;
    if (sourcePath == persistedPath) {
      return;
    }
    final tempDirectory = await getTemporaryDirectory();
    if (sourcePath.startsWith(tempDirectory.path)) {
      await _safeDelete(source);
    }
  }
}
