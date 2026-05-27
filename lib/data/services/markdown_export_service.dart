import 'dart:io';

import 'media_storage_service.dart';
import '../../domain/entities/export_grouping.dart';
import '../../domain/entities/item_record.dart';

class MarkdownExportService {
  MarkdownExportService(this._mediaStorageService);

  final MediaStorageService _mediaStorageService;

  Future<File> exportItems({
    required List<ItemRecord> items,
    required ExportGrouping grouping,
  }) async {
    final groupedItems = _groupItems(items, grouping);
    final buffer = StringBuffer()
      ..writeln('# 物见导出清单')
      ..writeln()
      ..writeln('- 导出方式: ${grouping.label}')
      ..writeln('- 条目数量: ${items.length}')
      ..writeln('- 导出时间: ${DateTime.now().toIso8601String()}')
      ..writeln();

    for (final entry in groupedItems.entries) {
      buffer
        ..writeln('## ${entry.key}')
        ..writeln()
        ..writeln('| 名称 | 分类 | 房间 | 箱号 | 数量 | 状态 | 详情 |')
        ..writeln('| --- | --- | --- | --- | ---: | --- | --- |');

      for (final item in entry.value) {
        buffer.writeln(
          '| ${_escape(item.name)} | ${_escape(item.category)} | ${_escape(item.room.trim().isEmpty ? '未分配' : item.room)} | ${_escape(item.box.trim().isEmpty ? '未分配' : item.box)} | ${item.quantity} | ${_escape(item.status.label)} | ${_escape(item.description)} |',
        );
      }

      buffer.writeln();
    }

    final directory = await _mediaStorageService.exportsDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}wujian-${grouping.name}-${DateTime.now().millisecondsSinceEpoch}.md',
    );
    await file.writeAsString(buffer.toString(), flush: true);
    await _mediaStorageService.pruneExports();
    return file;
  }

  Map<String, List<ItemRecord>> _groupItems(
    List<ItemRecord> items,
    ExportGrouping grouping,
  ) {
    final map = <String, List<ItemRecord>>{};
    for (final item in items) {
      final groupName = switch (grouping) {
        ExportGrouping.category => grouping.resolveGroupName(item.category),
        ExportGrouping.box => grouping.resolveGroupName(item.box),
      };
      map.putIfAbsent(groupName, () => []).add(item);
    }
    final keys = map.keys.toList()..sort();
    return {for (final key in keys) key: map[key]!};
  }

  String _escape(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', '<br>');
}
