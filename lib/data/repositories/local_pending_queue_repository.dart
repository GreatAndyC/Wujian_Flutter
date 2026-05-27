import '../../domain/entities/item_record.dart';
import '../../domain/repositories/pending_queue_repository.dart';
import 'local_item_repository.dart';

class LocalPendingQueueRepository implements PendingQueueRepository {
  final LocalItemFileStore _store = const LocalItemFileStore(
    'pending_items.json',
  );

  @override
  Future<List<ItemRecord>> loadPendingItems() => _store.load();

  @override
  Future<void> savePendingItems(List<ItemRecord> items) => _store.save(items);
}
