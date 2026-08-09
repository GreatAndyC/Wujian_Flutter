import 'dart:async';
import 'dart:io';

/// Coordinates mutations that target the same application documents root.
///
/// The coordinator is isolate-local. Every caller uses the canonical root as
/// its key, so separate repository and service instances still share the same
/// queue. An exclusive owner can reserve a root for backup or restore work;
/// ordinary mutations that opt into [rejectWhenExclusive] then fail instead
/// of queueing stale state behind that operation.
class StorageMutationCoordinator {
  StorageMutationCoordinator._();

  static final StorageMutationCoordinator shared =
      StorageMutationCoordinator._();

  static final Object _zoneOwnershipKey = Object();

  final Map<String, _RootMutationState> _states =
      <String, _RootMutationState>{};
  Future<void> _admissionTail = Future<void>.value();

  /// Runs [action] while holding the mutation slot for [root].
  ///
  /// The root is created, validated, and resolved before it is used as a lock
  /// key. Calls for different canonical roots can run concurrently.
  ///
  /// When [exclusive] is true, the call reserves the root as soon as it joins
  /// the queue. New calls with [rejectWhenExclusive] then throw
  /// [StorageMutationBusyException]. When [failIfBusy] is true, this call
  /// itself throws immediately if any owner or waiter already exists.
  ///
  /// A call made from the same asynchronous Zone while that Zone already owns
  /// the same canonical root executes directly. This permits an exclusive
  /// backup/restore operation to call the catalog or media services without
  /// deadlocking on its own outer lock.
  Future<T> run<T>(
    Directory root,
    Future<T> Function(Directory canonicalRoot) action, {
    bool exclusive = false,
    bool failIfBusy = false,
    bool rejectWhenExclusive = false,
  }) {
    final admission = _admit();
    return _runAdmitted(
      admission,
      () async => root,
      action,
      exclusive: exclusive,
      failIfBusy: failIfBusy,
      rejectWhenExclusive: rejectWhenExclusive,
    );
  }

  /// Equivalent to [run], but issues the ordering ticket before awaiting the
  /// asynchronous [rootProvider]. Repository and service entry points use this
  /// form so provider and canonicalization latency cannot reorder calls that
  /// were made synchronously.
  Future<T> runWithRootProvider<T>(
    Future<Directory> Function() rootProvider,
    Future<T> Function(Directory canonicalRoot) action, {
    bool exclusive = false,
    bool failIfBusy = false,
    bool rejectWhenExclusive = false,
  }) {
    final admission = _admit();
    return _runAdmitted(
      admission,
      rootProvider,
      action,
      exclusive: exclusive,
      failIfBusy: failIfBusy,
      rejectWhenExclusive: rejectWhenExclusive,
    );
  }

  _MutationAdmission _admit() {
    final gate = Completer<void>();
    final admission = _MutationAdmission(previous: _admissionTail, gate: gate);
    _admissionTail = gate.future;
    return admission;
  }

  Future<T> _runAdmitted<T>(
    _MutationAdmission admission,
    Future<Directory> Function() rootProvider,
    Future<T> Function(Directory canonicalRoot) action, {
    required bool exclusive,
    required bool failIfBusy,
    required bool rejectWhenExclusive,
  }) async {
    late final Directory canonicalRoot;
    try {
      final root = await rootProvider();
      canonicalRoot = await _canonicalizeRoot(root);
    } on FileSystemException {
      await admission.previous.catchError((Object _) {});
      admission.release();
      throw const FileSystemException('应用数据目录不可用');
    } catch (error, stackTrace) {
      await admission.previous.catchError((Object _) {});
      admission.release();
      Error.throwWithStackTrace(error, stackTrace);
    }

    // Canonicalization is allowed to overlap, but registration into the root
    // queue follows synchronous call order. The ticket is released as soon as
    // registration is complete; actions for different roots remain parallel.
    await admission.previous.catchError((Object _) {});
    final key = _rootKey(canonicalRoot.path);
    final inheritedOwnership =
        Zone.current[_zoneOwnershipKey] as _ZoneRootOwnership?;
    if (inheritedOwnership?.owns(key) ?? false) {
      admission.release();
      return action(canonicalRoot);
    }

    late final _RootMutationState state;
    late final Future<void> previous;
    late final Completer<void> gate;
    try {
      state = _states.putIfAbsent(key, _RootMutationState.new);
      if (failIfBusy && state.pendingCount > 0) {
        _removeUnusedState(key, state);
        throw const StorageMutationBusyException();
      }
      if (rejectWhenExclusive && state.exclusiveCount > 0) {
        _removeUnusedState(key, state);
        throw const StorageMutationBusyException();
      }

      previous = state.tail;
      gate = Completer<void>();
      state
        ..tail = gate.future
        ..pendingCount = state.pendingCount + 1;
      if (exclusive) {
        state.exclusiveCount++;
      }
      admission.release();
    } catch (error, stackTrace) {
      admission.release();
      Error.throwWithStackTrace(error, stackTrace);
    }

    await previous.catchError((Object _) {});
    final ownership = _ZoneRootOwnership(
      rootKey: key,
      parent: inheritedOwnership,
    );
    try {
      return await runZoned(
        () => action(canonicalRoot),
        zoneValues: <Object, Object>{_zoneOwnershipKey: ownership},
      );
    } finally {
      ownership.isActive = false;
      if (exclusive) {
        state.exclusiveCount--;
      }
      state.pendingCount--;
      gate.complete();
      _removeUnusedState(key, state);
    }
  }

  Future<Directory> _canonicalizeRoot(Directory root) async {
    await root.create(recursive: true);
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.link) {
      throw const FileSystemException('应用数据目录不可用');
    }
    final resolved = await root.resolveSymbolicLinks();
    final resolvedType = await FileSystemEntity.type(
      resolved,
      followLinks: false,
    );
    if (resolvedType != FileSystemEntityType.directory) {
      throw const FileSystemException('应用数据目录不是文件夹');
    }
    return Directory(resolved);
  }

  String _rootKey(String path) {
    var normalized = path;
    while (normalized.length > 1 &&
        (normalized.endsWith('/') || normalized.endsWith('\\'))) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  void _removeUnusedState(String key, _RootMutationState state) {
    if (state.pendingCount == 0 && identical(_states[key], state)) {
      _states.remove(key);
    }
  }
}

class StorageMutationBusyException implements Exception {
  const StorageMutationBusyException();

  @override
  String toString() => '同一数据目录已有互斥操作正在进行。';
}

class _RootMutationState {
  Future<void> tail = Future<void>.value();
  int pendingCount = 0;
  int exclusiveCount = 0;
}

class _MutationAdmission {
  _MutationAdmission({required this.previous, required this.gate});

  final Future<void> previous;
  final Completer<void> gate;

  void release() {
    if (!gate.isCompleted) {
      gate.complete();
    }
  }
}

class _ZoneRootOwnership {
  _ZoneRootOwnership({required this.rootKey, required this.parent});

  final String rootKey;
  final _ZoneRootOwnership? parent;
  bool isActive = true;

  bool owns(String candidate) {
    for (
      _ZoneRootOwnership? current = this;
      current != null;
      current = current.parent
    ) {
      if (current.isActive && current.rootKey == candidate) {
        return true;
      }
    }
    return false;
  }
}
