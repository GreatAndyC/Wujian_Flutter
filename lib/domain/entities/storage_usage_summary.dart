class StorageUsageSummary {
  const StorageUsageSummary({
    required this.imageCount,
    required this.imageBytes,
    required this.exportCount,
    required this.exportBytes,
  });

  const StorageUsageSummary.empty()
    : imageCount = 0,
      imageBytes = 0,
      exportCount = 0,
      exportBytes = 0;

  final int imageCount;
  final int imageBytes;
  final int exportCount;
  final int exportBytes;

  int get totalBytes => imageBytes + exportBytes;
}
