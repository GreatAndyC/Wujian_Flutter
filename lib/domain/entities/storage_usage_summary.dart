class StorageUsageSummary {
  const StorageUsageSummary({
    required this.imageCount,
    required this.imageBytes,
    required this.captureCacheCount,
    required this.captureCacheBytes,
    required this.exportCount,
    required this.exportBytes,
  });

  const StorageUsageSummary.empty()
    : imageCount = 0,
      imageBytes = 0,
      captureCacheCount = 0,
      captureCacheBytes = 0,
      exportCount = 0,
      exportBytes = 0;

  final int imageCount;
  final int imageBytes;
  final int captureCacheCount;
  final int captureCacheBytes;
  final int exportCount;
  final int exportBytes;

  int get totalBytes => imageBytes + captureCacheBytes + exportBytes;
}
