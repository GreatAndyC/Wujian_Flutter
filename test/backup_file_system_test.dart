import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/data/services/backup_file_system.dart';

void main() {
  late Directory root;
  late LocalBackupFileSystem fileSystem;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wujian-backup-fs-test-');
    fileSystem = LocalBackupFileSystem();
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('流式复制完成后落盘完整字节', () async {
    final source = File('${root.path}/source.bin');
    final destination = File('${root.path}/nested/destination.bin');
    final bytes = List<int>.generate(4096, (index) => index % 251);
    await source.writeAsBytes(bytes, flush: true);

    await fileSystem.copyAndSync(source, destination);

    expect(await destination.readAsBytes(), bytes);
    expect(
      await FileSystemEntity.type(destination.path, followLinks: false),
      FileSystemEntityType.file,
    );
  });

  test('复制拒绝覆盖已存在的目标', () async {
    final source = File('${root.path}/source.bin');
    final destination = File('${root.path}/destination.bin');
    await source.writeAsBytes(const [1, 2, 3], flush: true);
    await destination.writeAsBytes(const [9, 8, 7], flush: true);

    await expectLater(
      fileSystem.copyAndSync(source, destination),
      throwsA(isA<FileSystemException>()),
    );

    expect(await destination.readAsBytes(), const [9, 8, 7]);
  });

  test('复制拒绝跟随源软链接', () async {
    final realSource = File('${root.path}/real-source.bin');
    final linkedSource = Link('${root.path}/linked-source.bin');
    final destination = File('${root.path}/destination.bin');
    await realSource.writeAsBytes(const [1, 2, 3], flush: true);

    try {
      await linkedSource.create(realSource.path);
    } on FileSystemException {
      return;
    }

    await expectLater(
      fileSystem.copyAndSync(File(linkedSource.path), destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(await destination.exists(), isFalse);
  });

  test('同目录发布保留完整字节并移除源文件', () async {
    final source = File('${root.path}/source.partial');
    final destination = File('${root.path}/backup.wujian-backup');
    await source.writeAsBytes(const [4, 5, 6], flush: true);

    final published = await fileSystem.renameNew(source, destination);

    expect(published.path, destination.path);
    expect(await source.exists(), isFalse);
    expect(await destination.readAsBytes(), const [4, 5, 6]);
  });

  test('发布拒绝覆盖已存在的目标', () async {
    final source = File('${root.path}/source.partial');
    final destination = File('${root.path}/backup.wujian-backup');
    await source.writeAsBytes(const [1, 2, 3], flush: true);
    await destination.writeAsBytes(const [9, 8, 7], flush: true);

    await expectLater(
      fileSystem.renameNew(source, destination),
      throwsA(isA<FileSystemException>()),
    );

    expect(await source.readAsBytes(), const [1, 2, 3]);
    expect(await destination.readAsBytes(), const [9, 8, 7]);
  });

  test('发布拒绝跨父目录重命名', () async {
    final sourceDirectory = Directory('${root.path}/source');
    final destinationDirectory = Directory('${root.path}/destination');
    await sourceDirectory.create();
    await destinationDirectory.create();
    final source = File('${sourceDirectory.path}/backup.partial');
    final destination = File('${destinationDirectory.path}/backup.final');
    await source.writeAsBytes(const [1, 2, 3], flush: true);

    await expectLater(
      fileSystem.renameNew(source, destination),
      throwsA(isA<FileSystemException>()),
    );

    expect(await source.readAsBytes(), const [1, 2, 3]);
    expect(await destination.exists(), isFalse);
  });

  test('删除不存在的文件与目录保持幂等', () async {
    await fileSystem.deleteFile(File('${root.path}/missing.bin'));
    await fileSystem.deleteDirectory(Directory('${root.path}/missing-dir'));
  });

  test('只删除显式传入的文件与临时目录', () async {
    final kept = File('${root.path}/kept.bin');
    final removed = File('${root.path}/removed.bin');
    final temporary = Directory('${root.path}/temporary');
    final nested = File('${temporary.path}/nested.bin');
    await kept.writeAsBytes(const [1]);
    await removed.writeAsBytes(const [2]);
    await temporary.create();
    await nested.writeAsBytes(const [3]);

    await fileSystem.deleteFile(removed);
    await fileSystem.deleteDirectory(temporary);

    expect(await kept.exists(), isTrue);
    expect(await removed.exists(), isFalse);
    expect(await temporary.exists(), isFalse);
  });
}
