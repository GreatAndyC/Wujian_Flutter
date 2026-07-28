import '../entities/item_record.dart';

class CatalogSnapshot {
  const CatalogSnapshot({required this.items, required this.pendingItems});

  const CatalogSnapshot.empty() : items = const [], pendingItems = const [];

  final List<ItemRecord> items;
  final List<ItemRecord> pendingItems;
}

abstract interface class CatalogRepository {
  Future<CatalogSnapshot> loadCatalog();

  Future<void> saveCatalog(CatalogSnapshot snapshot);
}
