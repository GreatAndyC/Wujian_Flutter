enum ExportGrouping {
  category('按分类'),
  box('按箱子');

  const ExportGrouping(this.label);

  final String label;

  String resolveGroupName(String rawValue) {
    final trimmed = rawValue.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
    return switch (this) {
      ExportGrouping.category => '未分类',
      ExportGrouping.box => '未分箱',
    };
  }
}
