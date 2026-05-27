import '../entities/item_record.dart';

abstract interface class PendingQueueRepository {
  Future<List<ItemRecord>> loadPendingItems();

  Future<void> savePendingItems(List<ItemRecord> items);
}
