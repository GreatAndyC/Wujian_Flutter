import 'dart:io';

import 'package:flutter/services.dart';

class LocalFileSaveService {
  static const _channel = MethodChannel('com.wujian.app.icheck/file_saver');

  Future<bool> saveFile(File file, {required String mimeType}) async {
    final saved = await _channel.invokeMethod<bool>('saveFile', {
      'path': file.path,
      'fileName': _fileName(file.path),
      'mimeType': mimeType,
    });
    return saved ?? false;
  }

  String mimeTypeFor(File file) {
    final lower = file.path.toLowerCase();
    if (lower.endsWith('.pdf')) {
      return 'application/pdf';
    }
    if (lower.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (lower.endsWith('.md')) {
      return 'text/markdown';
    }
    return 'application/octet-stream';
  }

  String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }
}
