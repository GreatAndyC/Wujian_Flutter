import 'dart:io';

import 'package:excel/excel.dart';

import 'media_storage_service.dart';
import '../../domain/entities/export_grouping.dart';
import '../../domain/entities/item_record.dart';

class ExcelExportService {
  ExcelExportService(this._mediaStorageService);

  final MediaStorageService _mediaStorageService;

  Future<File> exportItems({
    required List<ItemRecord> items,
    required ExportGrouping grouping,
  }) async {
    final excel = Excel.createExcel();
    excel.delete('Sheet1');

    final groupedItems = _groupItems(items, grouping);
    final summary = excel['概览'];
    summary.appendRow([
      TextCellValue('物见导出清单'),
      TextCellValue(grouping.label),
      TextCellValue('条目数'),
      IntCellValue(items.length),
      TextCellValue('导出时间'),
      TextCellValue(DateTime.now().toIso8601String()),
    ]);
    summary.appendRow([
      TextCellValue('名称'),
      TextCellValue('分类'),
      TextCellValue('房间'),
      TextCellValue('箱号'),
      TextCellValue('数量'),
      TextCellValue('状态'),
      TextCellValue('详情'),
    ]);

    for (final item in items) {
      summary.appendRow(_rowForItem(item));
    }

    for (final entry in groupedItems.entries) {
      final sheet = excel[_safeSheetName(entry.key)];
      sheet.appendRow([
        TextCellValue(entry.key),
        TextCellValue(grouping.label),
        TextCellValue('条目数'),
        IntCellValue(entry.value.length),
      ]);
      sheet.appendRow([
        TextCellValue('名称'),
        TextCellValue('分类'),
        TextCellValue('房间'),
        TextCellValue('箱号'),
        TextCellValue('数量'),
        TextCellValue('状态'),
        TextCellValue('详情'),
      ]);
      for (final item in entry.value) {
        sheet.appendRow(_rowForItem(item));
      }
    }

    final bytes = excel.encode();
    if (bytes == null) {
      throw const FileSystemException('Excel 导出失败');
    }

    final directory = await _mediaStorageService.exportsDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}wujian-${grouping.name}-${DateTime.now().millisecondsSinceEpoch}.xlsx',
    );
    await file.writeAsBytes(bytes, flush: true);
    await _mediaStorageService.pruneExports();
    return file;
  }

  List<CellValue> _rowForItem(ItemRecord item) {
    return [
      TextCellValue(item.name),
      TextCellValue(item.category),
      TextCellValue(item.room.trim().isEmpty ? '未分配' : item.room),
      TextCellValue(item.box.trim().isEmpty ? '未分配' : item.box),
      IntCellValue(item.quantity),
      TextCellValue(item.status.label),
      TextCellValue(item.description),
    ];
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

  String _safeSheetName(String input) {
    final cleaned = input.replaceAll(RegExp(r'[\\/*?:\[\]]'), '_');
    return cleaned.isEmpty
        ? '未命名分组'
        : cleaned.substring(0, cleaned.length.clamp(0, 31));
  }
}
