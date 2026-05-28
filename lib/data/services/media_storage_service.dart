import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/entities/storage_usage_summary.dart';

class MediaStorageService {
  static const _maxRetainedExports = 6;

  Future<File> persistImage(File source) async {
    final imagesDirectory = await _imagesDirectory();
    final extension = _normalizedExtension(source.path);
    final target = File(
      '${imagesDirectory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    return source.copy(target.path);
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

  Future<Directory> exportsDirectory() async {
    final tempDirectory = await getTemporaryDirectory();
    final directory = Directory(
      '${tempDirectory.path}${Platform.pathSeparator}exports',
    );
    await directory.create(recursive: true);
    return directory;
  }

  String _normalizedExtension(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'png';
    }
    if (lower.endsWith('.webp')) {
      return 'webp';
    }
    if (lower.endsWith('.jpeg')) {
      return 'jpeg';
    }
    return 'jpg';
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
}
