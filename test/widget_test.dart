import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/domain/entities/item_record.dart';

void main() {
  test('ItemRecord serializes and deserializes queue state', () {
    final now = DateTime.parse('2026-05-28T12:00:00.000');
    final item = ItemRecord(
      id: 'item-1',
      name: '马克杯',
      category: '厨房',
      quantity: 2,
      status: ItemStatus.cataloged,
      imagePath: '/tmp/cup.jpg',
      description: '白色陶瓷马克杯',
      parameters: {'容量': '350ml'},
      notes: '节日礼物',
      room: '餐厅',
      box: 'A-01',
      brand: '无印良品',
      model: 'MUG-01',
      color: '白色',
      material: '陶瓷',
      createdAt: now,
      updatedAt: now,
      queueState: QueueRecognitionState.ready,
      recognitionError: '',
    );

    final decoded = ItemRecord.fromJson(item.toJson());

    expect(decoded.name, item.name);
    expect(decoded.category, item.category);
    expect(decoded.status, item.status);
    expect(decoded.queueState, QueueRecognitionState.ready);
    expect(decoded.parameters['容量'], '350ml');
  });
}
