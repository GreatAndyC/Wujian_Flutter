import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icheck/domain/entities/backup_restore.dart';
import 'package:icheck/domain/repositories/catalog_repository.dart';
import 'package:icheck/features/backup/backup_restore_controller.dart';

void main() {
  late Directory root;
  late File packageFile;
  late _FakeBackupRestoreOperations operations;
  late BackupRestoreController controller;

  final inspection = BackupPackageInspection(
    formatVersion: 1,
    createdAt: _createdAt,
    itemCount: 2,
    pendingItemCount: 1,
    mediaCount: 2,
    mediaBytes: 4096,
    legacyMigrated: false,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'wujian-backup-controller-test-',
    );
    packageFile = File('${root.path}/synthetic-backup.zip');
    await packageFile.writeAsBytes(const [1, 2, 3]);
    operations = _FakeBackupRestoreOperations();
    controller = BackupRestoreController(operations: operations);
  });

  tearDown(() async {
    controller.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('create 成功暴露运行和完成状态并保留结果', () async {
    final createResult = BackupCreateResult(
      file: packageFile,
      inspection: inspection,
      packageBytes: 2048,
    );
    operations.createResult = createResult;
    final observed = <BackupRestoreStatus>[];
    controller.addListener(() => observed.add(controller.status));

    final result = await controller.create(baseName: 'synthetic');

    expect(result, same(createResult));
    expect(operations.lastBaseName, 'synthetic');
    expect(controller.status, BackupRestoreStatus.succeeded);
    expect(controller.operation, BackupRestoreOperation.create);
    expect(controller.lastCreateResult, same(createResult));
    expect(controller.lastInspection, same(inspection));
    expect(controller.lastError, isNull);
    expect(observed, [
      BackupRestoreStatus.running,
      BackupRestoreStatus.succeeded,
    ]);
  });

  test('validate 成功更新最近校验结果', () async {
    operations.validationResult = inspection;

    final result = await controller.validate(packageFile);

    expect(result, same(inspection));
    expect(operations.lastValidatedFile, same(packageFile));
    expect(controller.status, BackupRestoreStatus.succeeded);
    expect(controller.operation, BackupRestoreOperation.validate);
    expect(controller.lastInspection, same(inspection));
    expect(controller.lastError, isNull);
  });

  test('restore 成功传递 merge 模式并保留恢复摘要', () async {
    const snapshot = CatalogSnapshot.empty();
    final restoreResult = BackupRestoreResult(
      snapshot: snapshot,
      inspection: inspection,
      mode: BackupRestoreMode.merge,
      createdMediaCount: 2,
      deletedOrphanCount: 1,
      retainedOrphanCount: 0,
    );
    operations.restoreResult = restoreResult;

    final result = await controller.restore(
      packageFile,
      mode: BackupRestoreMode.merge,
    );

    expect(result, same(restoreResult));
    expect(operations.lastRestoredFile, same(packageFile));
    expect(operations.lastRestoreMode, BackupRestoreMode.merge);
    expect(controller.status, BackupRestoreStatus.succeeded);
    expect(controller.operation, BackupRestoreOperation.restore);
    expect(controller.lastRestoreResult, same(restoreResult));
    expect(controller.lastInspection, same(inspection));
    expect(controller.lastError, isNull);
  });

  test('结构化失败保留错误码和安全消息', () async {
    const failure = BackupRestoreException(
      BackupRestoreErrorCode.hashMismatch,
      '备份包完整性校验失败。',
    );
    operations.validationError = failure;

    final result = await controller.validate(packageFile);

    expect(result, isNull);
    expect(controller.status, BackupRestoreStatus.failed);
    expect(controller.operation, BackupRestoreOperation.validate);
    expect(controller.lastError, same(failure));
    expect(controller.lastError!.code, BackupRestoreErrorCode.hashMismatch);
    expect(controller.lastError.toString(), failure.message);
  });

  test('未知异常映射为 writeFailed 且不回显异常值', () async {
    const sensitiveValue = '/private/synthetic/secret-token-value';
    operations.restoreError = StateError(sensitiveValue);

    final result = await controller.restore(packageFile);

    expect(result, isNull);
    expect(controller.status, BackupRestoreStatus.failed);
    expect(controller.lastError!.code, BackupRestoreErrorCode.writeFailed);
    expect(controller.lastError!.message, isNot(contains(sensitiveValue)));
    expect(controller.lastError.toString(), isNot(contains(sensitiveValue)));
  });

  test('运行中拒绝并发调用且不触发后端', () async {
    final pendingCreate = Completer<BackupCreateResult>();
    operations.pendingCreate = pendingCreate;
    final createFuture = controller.create();

    expect(controller.isBusy, isTrue);
    expect(controller.operation, BackupRestoreOperation.create);

    final rejectedResult = await controller.validate(packageFile);

    expect(rejectedResult, isNull);
    expect(operations.validateCalls, 0);
    expect(controller.status, BackupRestoreStatus.running);
    expect(controller.operation, BackupRestoreOperation.create);
    expect(controller.lastError!.code, BackupRestoreErrorCode.busy);

    final createResult = BackupCreateResult(
      file: packageFile,
      inspection: inspection,
      packageBytes: 1024,
    );
    pendingCreate.complete(createResult);

    expect(await createFuture, same(createResult));
    expect(controller.status, BackupRestoreStatus.succeeded);
    expect(controller.lastError, isNull);
  });
}

final _createdAt = DateTime.utc(2026, 8, 9, 12);

class _FakeBackupRestoreOperations implements BackupRestoreOperations {
  BackupCreateResult? createResult;
  BackupPackageInspection? validationResult;
  BackupRestoreResult? restoreResult;
  Object? createError;
  Object? validationError;
  Object? restoreError;
  Completer<BackupCreateResult>? pendingCreate;

  int createCalls = 0;
  int validateCalls = 0;
  int restoreCalls = 0;
  String? lastBaseName;
  File? lastValidatedFile;
  File? lastRestoredFile;
  BackupRestoreMode? lastRestoreMode;

  @override
  Future<BackupCreateResult> createBackup({
    String baseName = 'wujian-backup',
  }) async {
    createCalls++;
    lastBaseName = baseName;
    final error = createError;
    if (error != null) {
      throw error;
    }
    final pending = pendingCreate;
    if (pending != null) {
      return pending.future;
    }
    return createResult!;
  }

  @override
  Future<BackupPackageInspection> validateBackup(File file) async {
    validateCalls++;
    lastValidatedFile = file;
    final error = validationError;
    if (error != null) {
      throw error;
    }
    return validationResult!;
  }

  @override
  Future<BackupRestoreResult> restoreBackup(
    File file, {
    BackupRestoreMode mode = BackupRestoreMode.replace,
  }) async {
    restoreCalls++;
    lastRestoredFile = file;
    lastRestoreMode = mode;
    final error = restoreError;
    if (error != null) {
      throw error;
    }
    return restoreResult!;
  }
}
