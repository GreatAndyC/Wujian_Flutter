import '../entities/app_settings.dart';
import '../entities/recognition_result.dart';

abstract interface class RecognitionRepository {
  Future<RecognitionResult> recognizeItem({
    required AppSettings settings,
    required List<int> imageBytes,
    required String mimeType,
  });

  Future<void> testConnection(AppSettings settings);
}
