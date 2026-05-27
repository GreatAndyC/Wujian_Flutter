import '../entities/item_record.dart';

abstract interface class ItemRepository {
  Future<List<ItemRecord>> loadItems();

  Future<void> saveItems(List<ItemRecord> items);
}
