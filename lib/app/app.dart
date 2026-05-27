import 'package:flutter/material.dart';

import '../data/repositories/local_item_repository.dart';
import '../data/repositories/local_pending_queue_repository.dart';
import '../data/repositories/local_settings_repository.dart';
import '../data/repositories/local_token_usage_repository.dart';
import '../data/repositories/volcengine_recognition_repository.dart';
import '../data/services/excel_export_service.dart';
import '../data/services/markdown_export_service.dart';
import '../data/services/media_storage_service.dart';
import '../data/services/pdf_export_service.dart';
import '../features/shell/app_controller.dart';
import '../features/shell/app_scope.dart';
import '../features/shell/main_shell.dart';
import 'theme/app_theme.dart';

class WujianApp extends StatelessWidget {
  const WujianApp({super.key, required this.controller});

  final AppController controller;

  static Future<WujianApp> bootstrap() async {
    final mediaStorageService = MediaStorageService();
    final controller = AppController(
      settingsRepository: LocalSettingsRepository(),
      itemRepository: LocalItemRepository(),
      pendingQueueRepository: LocalPendingQueueRepository(),
      recognitionRepository: VolcengineRecognitionRepository(),
      tokenUsageRepository: LocalTokenUsageRepository(),
      pdfExportService: PdfExportService(mediaStorageService),
      excelExportService: ExcelExportService(mediaStorageService),
      markdownExportService: MarkdownExportService(mediaStorageService),
      mediaStorageService: mediaStorageService,
    );
    await controller.initialize();
    return WujianApp(controller: controller);
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      child: MaterialApp(
        title: '物见',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme(),
        home: const MainShell(),
      ),
    );
  }
}
