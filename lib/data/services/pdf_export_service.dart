import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'media_storage_service.dart';
import '../../domain/entities/export_grouping.dart';
import '../../domain/entities/item_record.dart';

class PdfExportService {
  PdfExportService(this._mediaStorageService);

  static const _fontAssetPath = 'assets/fonts/simhei.ttf';
  final MediaStorageService _mediaStorageService;

  Future<File> exportItems({
    required List<ItemRecord> items,
    required ExportGrouping grouping,
  }) async {
    final fontData = await rootBundle.load(_fontAssetPath);
    final baseFont = pw.Font.ttf(fontData);
    final boldFont = pw.Font.ttf(fontData);
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: baseFont, bold: boldFont),
    );
    final groupedItems = _groupItems(items, grouping);
    final imageAssets = await _loadImageAssets(items);
    final generatedAt = DateTime.now();

    document.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          margin: const pw.EdgeInsets.all(28),
          theme: pw.ThemeData.withFont(base: baseFont, bold: boldFont),
        ),
        build: (context) => [
          _buildCover(items, grouping, generatedAt),
          ...groupedItems.entries.expand(
            (entry) => [
              pw.SizedBox(height: 18),
              _buildGroupHeader(entry.key, entry.value),
              pw.SizedBox(height: 10),
              _buildTable(entry.value),
              pw.SizedBox(height: 14),
              _buildImageCards(entry.value, imageAssets),
            ],
          ),
        ],
      ),
    );

    final outputDirectory = await _mediaStorageService.exportsDirectory();
    final fileName =
        'wujian-${grouping.name}-${generatedAt.millisecondsSinceEpoch}.pdf';
    final file = File(
      '${outputDirectory.path}${Platform.pathSeparator}$fileName',
    );
    await file.writeAsBytes(await document.save());
    await _mediaStorageService.pruneExports();
    return file;
  }

  pw.Widget _buildCover(
    List<ItemRecord> items,
    ExportGrouping grouping,
    DateTime generatedAt,
  ) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(24),
      decoration: pw.BoxDecoration(
        borderRadius: pw.BorderRadius.circular(20),
        gradient: const pw.LinearGradient(
          colors: [PdfColor.fromInt(0xFF14342D), PdfColor.fromInt(0xFF255748)],
        ),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            '物见导出清单',
            style: pw.TextStyle(
              color: PdfColors.white,
              fontSize: 28,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            '${grouping.label} · ${items.length} 件物品',
            style: const pw.TextStyle(color: PdfColors.white, fontSize: 13),
          ),
          pw.SizedBox(height: 10),
          pw.Text(
            '导出时间 ${_formatDateTime(generatedAt)}',
            style: const pw.TextStyle(color: PdfColors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildGroupHeader(String title, List<ItemRecord> items) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromInt(0xFFF1ECE2),
        borderRadius: pw.BorderRadius.circular(16),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(
              fontSize: 18,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromInt(0xFF11211E),
            ),
          ),
          pw.Text(
            '${items.length} 项',
            style: pw.TextStyle(
              fontSize: 12,
              color: PdfColor.fromInt(0xFF1E6B57),
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildTable(List<ItemRecord> items) {
    return pw.TableHelper.fromTextArray(
      border: null,
      cellAlignment: pw.Alignment.centerLeft,
      headerDecoration: const pw.BoxDecoration(
        color: PdfColor.fromInt(0xFFE5F0EA),
      ),
      headerStyle: pw.TextStyle(
        fontWeight: pw.FontWeight.bold,
        color: PdfColor.fromInt(0xFF14342D),
        fontSize: 11,
      ),
      cellStyle: const pw.TextStyle(fontSize: 10),
      cellPadding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      headers: const ['名称', '分类', '房间', '箱号', '数量', '状态'],
      data: items
          .map(
            (item) => [
              item.name,
              item.category,
              item.room.trim().isEmpty ? '未分配' : item.room,
              item.box.trim().isEmpty ? '未分配' : item.box,
              '${item.quantity}',
              item.status.label,
            ],
          )
          .toList(),
    );
  }

  pw.Widget _buildImageCards(
    List<ItemRecord> items,
    Map<String, pw.MemoryImage> imageAssets,
  ) {
    return pw.Wrap(
      spacing: 12,
      runSpacing: 12,
      children: items
          .take(12)
          .map((item) => _buildImageCard(item, imageAssets[_imageKey(item)]))
          .toList(),
    );
  }

  pw.Widget _buildImageCard(ItemRecord item, pw.MemoryImage? image) {
    return pw.Container(
      width: 168,
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColor.fromInt(0xFFE3E0D8)),
        borderRadius: pw.BorderRadius.circular(14),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _buildPreviewImage(image),
          pw.SizedBox(height: 8),
          pw.Text(
            item.name,
            maxLines: 1,
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            item.description.trim().isEmpty ? '暂无描述' : item.description,
            maxLines: 2,
            style: const pw.TextStyle(fontSize: 9),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildPreviewImage(pw.MemoryImage? image) {
    if (image == null) {
      return pw.Container(
        height: 90,
        width: 148,
        decoration: pw.BoxDecoration(
          color: PdfColor.fromInt(0xFFE8F2EC),
          borderRadius: pw.BorderRadius.circular(12),
        ),
        alignment: pw.Alignment.center,
        child: pw.Text(
          '无图片',
          style: pw.TextStyle(
            color: PdfColor.fromInt(0xFF1E6B57),
            fontSize: 12,
          ),
        ),
      );
    }

    return pw.ClipRRect(
      horizontalRadius: 12,
      verticalRadius: 12,
      child: pw.Image(image, height: 90, width: 148, fit: pw.BoxFit.cover),
    );
  }

  Future<Map<String, pw.MemoryImage>> _loadImageAssets(
    List<ItemRecord> items,
  ) async {
    final result = <String, pw.MemoryImage>{};
    for (final item in items) {
      final key = _imageKey(item);
      if (key.isEmpty || result.containsKey(key)) {
        continue;
      }

      final bytes = await _readImageBytes(key);
      if (bytes == null) {
        continue;
      }
      result[key] = pw.MemoryImage(bytes);
    }
    return result;
  }

  Future<Uint8List?> _readImageBytes(String imagePath) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        return null;
      }
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on FileSystemException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  String _imageKey(ItemRecord item) => item.imagePath.trim();

  String _formatDateTime(DateTime value) {
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
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

    final sortedKeys = map.keys.toList()..sort();
    return {
      for (final key in sortedKeys)
        key: (map[key]!..sort((a, b) => a.name.compareTo(b.name))),
    };
  }
}
