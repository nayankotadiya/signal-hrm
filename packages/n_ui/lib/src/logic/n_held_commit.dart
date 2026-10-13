import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// A random UUID v4 for the `Idempotency-Key` header. Generated once per user decision, so a
/// retry of the same decision can never be processed twice by the backend.
String newIdempotencyKey([Random? random]) {
  final r = random ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40; // version 4
  b[8] = (b[8] & 0x3F) | 0x80; // RFC 4122 variant
  String hex(int from, int to) => b.sublist(from, to).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

enum NHeldStatus { holding, sending, committed, cancelled, failed }

/// One decision waiting out its Undo window.
class NHeldCommit {
  NHeldCommit._(this.id, this.idempotencyKey, this._send);

  final String id;
  final String idempotencyKey;
  final Future<void> Function(String idempotencyKey) _send;
  NHeldStatus status = NHeldStatus.holding;
  Object? error;
  Timer? _timer;
}

/// Held commit for audited business decisions (approve / decline from the dark action card).
///
/// The UI updates at once; the request is sent with an idempotency key when the window ends, when
/// [flushAll] is called (the user leaves the screen or the app is hidden), and never if the user
/// taps Undo first. If the server rejects it, [onFailed] fires so the row can return with the error.
///
/// Not for decisions that need a comment, a second factor or are irreversible (payroll finalize,
/// restore, role changes, Super Admin creation, offboarding): those use a confirmation dialog and a
/// visible pending state until the server confirms.
class NHeldCommitQueue extends ChangeNotifier {
  NHeldCommitQueue({this.window = const Duration(seconds: 5), this.onFailed, this.onCommitted, Random? random})
      : _random = random;

  final Duration window;
  void Function(String id, Object error)? onFailed;
  void Function(String id)? onCommitted;
  final Random? _random;
  final Map<String, NHeldCommit> _items = {};
  bool _disposed = false;

  /// Decisions still holding or in flight.
  Iterable<NHeldCommit> get pending => _items.values;
  bool isPending(String id) => _items.containsKey(id);
  NHeldStatus? statusOf(String id) => _items[id]?.status;

  /// Starts the Undo window for [id]. A second hold for the same id while one is still holding
  /// replaces it (same decision re-made); while sending, the existing request wins.
  NHeldCommit hold(String id, Future<void> Function(String idempotencyKey) send) {
    final existing = _items[id];
    if (existing != null && existing.status == NHeldStatus.sending) return existing;
    existing?._timer?.cancel();
    final c = NHeldCommit._(id, newIdempotencyKey(_random), send);
    c._timer = Timer(window, () => _commit(c));
    _items[id] = c;
    _notify();
    return c;
  }

  /// Cancels a decision that has not been sent yet. Returns false if it is already on its way.
  bool undo(String id) {
    final c = _items[id];
    if (c == null || c.status != NHeldStatus.holding) return false;
    c._timer?.cancel();
    c.status = NHeldStatus.cancelled;
    _items.remove(id);
    _notify();
    return true;
  }

  /// Sends every holding decision now (screen exit, app hidden, sign-out).
  Future<void> flushAll() async {
    final holding = _items.values.where((c) => c.status == NHeldStatus.holding).toList();
    await Future.wait(holding.map(_commit));
  }

  Future<void> _commit(NHeldCommit c) async {
    if (c.status != NHeldStatus.holding) return;
    c._timer?.cancel();
    c.status = NHeldStatus.sending;
    _notify();
    try {
      await c._send(c.idempotencyKey);
      c.status = NHeldStatus.committed;
      _items.remove(c.id);
      onCommitted?.call(c.id);
    } catch (e) {
      c.status = NHeldStatus.failed;
      c.error = e;
      _items.remove(c.id);
      onFailed?.call(c.id, e);
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Flushes pending decisions (fire-and-forget) before disposing: leaving the screen commits.
  @override
  void dispose() {
    _disposed = true;
    onFailed = null; // the screen is gone; failures surface through notifications on next load
    onCommitted = null;
    unawaited(flushAll());
    super.dispose();
  }
}
