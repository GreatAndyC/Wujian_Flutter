enum ItemStatus {
  pending('待确认'),
  cataloged('已归档'),
  boxed('已装箱'),
  moved('已搬走');

  const ItemStatus(this.label);

  final String label;
}

enum QueueRecognitionState {
  queued('排队中'),
  processing('识别中'),
  ready('可确认'),
  failed('识别失败');

  const QueueRecognitionState(this.label);

  final String label;
}

class ItemRecord {
  const ItemRecord({
    required this.id,
    required this.name,
    required this.category,
    required this.quantity,
    required this.status,
    required this.imagePath,
    required this.description,
    required this.parameters,
    required this.notes,
    required this.room,
    required this.box,
    required this.brand,
    required this.model,
    required this.color,
    required this.material,
    required this.createdAt,
    required this.updatedAt,
    this.queueState = QueueRecognitionState.ready,
    this.recognitionError = '',
  });

  final String id;
  final String name;
  final String category;
  final int quantity;
  final ItemStatus status;
  final String imagePath;
  final String description;
  final Map<String, String> parameters;
  final String notes;
  final String room;
  final String box;
  final String brand;
  final String model;
  final String color;
  final String material;
  final DateTime createdAt;
  final DateTime updatedAt;
  final QueueRecognitionState queueState;
  final String recognitionError;

  ItemRecord copyWith({
    String? id,
    String? name,
    String? category,
    int? quantity,
    ItemStatus? status,
    String? imagePath,
    String? description,
    Map<String, String>? parameters,
    String? notes,
    String? room,
    String? box,
    String? brand,
    String? model,
    String? color,
    String? material,
    DateTime? createdAt,
    DateTime? updatedAt,
    QueueRecognitionState? queueState,
    String? recognitionError,
  }) {
    return ItemRecord(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      quantity: quantity ?? this.quantity,
      status: status ?? this.status,
      imagePath: imagePath ?? this.imagePath,
      description: description ?? this.description,
      parameters: parameters ?? this.parameters,
      notes: notes ?? this.notes,
      room: room ?? this.room,
      box: box ?? this.box,
      brand: brand ?? this.brand,
      model: model ?? this.model,
      color: color ?? this.color,
      material: material ?? this.material,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      queueState: queueState ?? this.queueState,
      recognitionError: recognitionError ?? this.recognitionError,
    );
  }

  factory ItemRecord.fromJson(Map<String, dynamic> json) {
    return ItemRecord(
      id: json['id'] as String,
      name: json['name'] as String? ?? '未命名物品',
      category: json['category'] as String? ?? '待分类',
      quantity: json['quantity'] as int? ?? 1,
      status: ItemStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => ItemStatus.pending,
      ),
      imagePath: json['imagePath'] as String? ?? '',
      description: json['description'] as String? ?? '',
      parameters: Map<String, String>.from(
        json['parameters'] as Map? ?? <String, String>{},
      ),
      notes: json['notes'] as String? ?? '',
      room: json['room'] as String? ?? '',
      box: json['box'] as String? ?? '',
      brand: json['brand'] as String? ?? '',
      model: json['model'] as String? ?? '',
      color: json['color'] as String? ?? '',
      material: json['material'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      queueState: QueueRecognitionState.values.firstWhere(
        (value) => value.name == json['queueState'],
        orElse: () => QueueRecognitionState.ready,
      ),
      recognitionError: json['recognitionError'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'category': category,
      'quantity': quantity,
      'status': status.name,
      'imagePath': imagePath,
      'description': description,
      'parameters': parameters,
      'notes': notes,
      'room': room,
      'box': box,
      'brand': brand,
      'model': model,
      'color': color,
      'material': material,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'queueState': queueState.name,
      'recognitionError': recognitionError,
    };
  }
}
