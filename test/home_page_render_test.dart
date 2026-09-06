import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/services/excel_export_service.dart';
import 'package:icheck/data/services/local_file_save_service.dart';
import 'package:icheck/data/services/markdown_export_service.dart';
import 'package:icheck/data/services/media_storage_service.dart';
import 'package:icheck/data/services/pdf_export_service.dart';
import 'package:icheck/domain/entities/app_settings.dart';
import 'package:icheck/domain/entities/app_settings_store.dart';
import 'package:icheck/domain/entities/recognition_result.dart';
import 'package:icheck/domain/entities/token_usage_stats.dart';
import 'package:icheck/domain/repositories/catalog_repository.dart';
import 'package:icheck/domain/repositories/recognition_repository.dart';
import 'package:icheck/domain/repositories/settings_repository.dart';
import 'package:icheck/domain/repositories/token_usage_repository.dart';
import 'package:icheck/features/home/home_page.dart';
import 'package:icheck/features/shell/app_controller.dart';
import 'package:icheck/features/shell/app_scope.dart';
import 'package:icheck/app/theme/app_theme.dart';

void main() {
  testWidgets('主页拍摄内容可以正常渲染', (tester) async {
    final mediaStorage = MediaStorageService();
    final controller = AppController(
      settingsRepository: _SettingsRepository(),
      catalogRepository: _CatalogRepository(),
      recognitionRepository: _RecognitionRepository(),
      tokenUsageRepository: _TokenUsageRepository(),
      pdfExportService: PdfExportService(mediaStorage),
      excelExportService: ExcelExportService(mediaStorage),
      markdownExportService: MarkdownExportService(mediaStorage),
      localFileSaveService: LocalFileSaveService(),
      mediaStorageService: mediaStorage,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(),
        home: Scaffold(
          body: AppScope(
            controller: controller,
            child: const HomePage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('物见工作区'), findsOneWidget);
    expect(find.text('拍下来，剩下的交给队列。'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-capture-button')), findsOneWidget);
  });
}

class _SettingsRepository implements SettingsRepository {
  @override
  Future<AppSettingsStore> loadSettingsStore() async =>
      AppSettingsStore.initial();

  @override
  Future<void> saveSettingsStore(AppSettingsStore store) async {}
}

class _CatalogRepository implements CatalogRepository {
  @override
  Future<CatalogSnapshot> loadCatalog() async => const CatalogSnapshot.empty();

  @override
  Future<void> saveCatalog(CatalogSnapshot snapshot) async {}
}

class _RecognitionRepository implements RecognitionRepository {
  @override
  Future<RecognitionResult> recognizeItem({
    required AppSettings settings,
    required List<int> imageBytes,
    required String mimeType,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> testConnection(AppSettings settings) async {}
}

class _TokenUsageRepository implements TokenUsageRepository {
  @override
  Future<Map<String, TokenUsageStats>> loadUsageStats() async => {};

  @override
  Future<void> saveUsageStats(
    Map<String, TokenUsageStats> statsByProfileId,
  ) async {}
}
