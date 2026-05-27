import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/entities/item_record.dart';
import '../../domain/repositories/item_repository.dart';

class LocalItemRepository implements ItemRepository {
  final LocalItemFileStore _store = const LocalItemFileStore('items.json');

  @override
  Future<List<ItemRecord>> loadItems() => _store.load();

  @override
  Future<void> saveItems(List<ItemRecord> items) => _store.save(items);
}

class LocalItemFileStore {
  const LocalItemFileStore(this.fileName);

  final String fileName;

  Future<List<ItemRecord>> load() async {
    final file = await _itemsFile();
    if (!await file.exists()) {
      return const [];
    }

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const [];
    }

    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((entry) => ItemRecord.fromJson(entry as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Future<void> save(List<ItemRecord> items) async {
    final file = await _itemsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
  }

  Future<File> _itemsFile() async {
    final root = await getApplicationDocumentsDirectory();
    return File('${root.path}${Platform.pathSeparator}$fileName');
  }
}
