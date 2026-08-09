import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../domain/entities/backup_restore.dart';

class BackupRestoreController extends ChangeNotifier {
  BackupRestoreController({required BackupRestoreOperations operations})
    : _operations = operations;

  final BackupRestoreOperations _operations;

  BackupRestoreStatus _status = BackupRestoreStatus.idle;
  BackupRestoreOperation? _operation;
  BackupRestoreException? _lastError;
  BackupCreateResult? _lastCreateResult;
  BackupPackageInspection? _lastInspection;
  BackupRestoreResult? _lastRestoreResult;

  BackupRestoreStatus get status => _status;
  BackupRestoreOperation? get operation => _operation;
  BackupRestoreException? get lastError => _lastError;
  BackupCreateResult? get lastCreateResult => _lastCreateResult;
  BackupPackageInspection? get lastInspection => _lastInspection;
  BackupRestoreResult? get lastRestoreResult => _lastRestoreResult;
  bool get isBusy => _status == BackupRestoreStatus.running;

  Future<BackupCreateResult?> create({
    String baseName = 'wujian-backup',
  }) async {
    if (_rejectWhenBusy()) {
      return null;
    }
    _start(BackupRestoreOperation.create);
    try {
      final result = await _operations.createBackup(baseName: baseName);
      _lastCreateResult = result;
      _lastInspection = result.inspection;
      _succeed();
      return result;
    } on BackupRestoreException catch (error) {
      _fail(error);
      return null;
    } catch (_) {
      _fail(_unknownFailure());
      return null;
    }
  }

  Future<BackupPackageInspection?> validate(File file) async {
    if (_rejectWhenBusy()) {
      return null;
    }
    _start(BackupRestoreOperation.validate);
    try {
      final inspection = await _operations.validateBackup(file);
      _lastInspection = inspection;
      _succeed();
      return inspection;
    } on BackupRestoreException catch (error) {
      _fail(error);
      return null;
    } catch (_) {
      _fail(_unknownFailure());
      return null;
    }
  }

  Future<BackupRestoreResult?> restore(
    File file, {
    BackupRestoreMode mode = BackupRestoreMode.replace,
  }) async {
    if (_rejectWhenBusy()) {
      return null;
    }
    _start(BackupRestoreOperation.restore);
    try {
      final result = await _operations.restoreBackup(file, mode: mode);
      _lastRestoreResult = result;
      _lastInspection = result.inspection;
      _succeed();
      return result;
    } on BackupRestoreException catch (error) {
      _fail(error);
      return null;
    } catch (_) {
      _fail(_unknownFailure());
      return null;
    }
  }

  bool _rejectWhenBusy() {
    if (!isBusy) {
      return false;
    }
    _lastError = const BackupRestoreException(
      BackupRestoreErrorCode.busy,
      '备份或恢复操作正在进行，请稍后重试。',
    );
    notifyListeners();
    return true;
  }

  void _start(BackupRestoreOperation operation) {
    _status = BackupRestoreStatus.running;
    _operation = operation;
    _lastError = null;
    notifyListeners();
  }

  void _succeed() {
    _status = BackupRestoreStatus.succeeded;
    _lastError = null;
    notifyListeners();
  }

  void _fail(BackupRestoreException error) {
    _status = BackupRestoreStatus.failed;
    _lastError = error;
    notifyListeners();
  }

  BackupRestoreException _unknownFailure() {
    return const BackupRestoreException(
      BackupRestoreErrorCode.writeFailed,
      '备份或恢复操作失败，请重试。',
    );
  }
}
