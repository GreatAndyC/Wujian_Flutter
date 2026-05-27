import 'item_record.dart';

class RecognitionResult {
  const RecognitionResult({
    required this.name,
    required this.category,
    required this.quantity,
    required this.description,
    required this.parameters,
    required this.room,
    required this.box,
    required this.brand,
    required this.model,
    required this.color,
    required this.material,
    required this.notes,
    required this.status,
    required this.rawResponse,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });

  final String name;
  final String category;
  final int quantity;
  final String description;
  final Map<String, String> parameters;
  final String room;
  final String box;
  final String brand;
  final String model;
  final String color;
  final String material;
  final String notes;
  final ItemStatus status;
  final String rawResponse;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  ItemRecord toItem({
    required String id,
    required String imagePath,
    required DateTime now,
  }) {
    return ItemRecord(
      id: id,
      name: name,
      category: category,
      quantity: quantity,
      status: status,
      imagePath: imagePath,
      description: description,
      parameters: {
        ...parameters,
        if (rawResponse.isNotEmpty) 'rawResponse': rawResponse,
      },
      notes: notes,
      room: room,
      box: box,
      brand: brand,
      model: model,
      color: color,
      material: material,
      createdAt: now,
      updatedAt: now,
      queueState: QueueRecognitionState.ready,
      recognitionError: '',
    );
  }
}
