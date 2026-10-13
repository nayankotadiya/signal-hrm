import 'package:flutter_test/flutter_test.dart';
import 'package:n_ui/n_ui.dart';

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void main() {
  test('idempotency keys are unique UUID v4 strings', () {
    final keys = {for (var i = 0; i < 500; i++) newIdempotencyKey()};
    expect(keys.length, 500);
    expect(keys.every(_uuid.hasMatch), isTrue);
  });

  // testWidgets gives a fake clock, so the 5 s window runs instantly.
  testWidgets('sends once, with its idempotency key, when the window ends', (tester) async {
    final sent = <String>[];
    final q = NHeldCommitQueue(window: const Duration(seconds: 5));
    final c = q.hold('leave-1', (key) async => sent.add(key));
    await tester.pump(const Duration(milliseconds: 4900));
    expect(sent, isEmpty);
    expect(q.isPending('leave-1'), isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(sent, [c.idempotencyKey]);
    expect(q.isPending('leave-1'), isFalse);
    q.dispose();
  });

  testWidgets('Undo inside the window cancels: nothing is ever sent', (tester) async {
    var calls = 0;
    final q = NHeldCommitQueue();
    q.hold('exp-9', (_) async => calls++);
    await tester.pump(const Duration(seconds: 2));
    expect(q.undo('exp-9'), isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(calls, 0);
    q.dispose();
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('Undo is refused once the request is on its way', (tester) async {
    final q = NHeldCommitQueue();
    q.hold('a', (_) => Future<void>.delayed(const Duration(seconds: 3)));
    await tester.pump(const Duration(seconds: 5)); // window over, request in flight
    expect(q.statusOf('a'), NHeldStatus.sending);
    expect(q.undo('a'), isFalse);
    await tester.pump(const Duration(seconds: 3));
    q.dispose();
  });

  testWidgets('a server rejection reports the error so the row can return', (tester) async {
    Object? failure;
    String? failedId;
    final q = NHeldCommitQueue(onFailed: (id, e) {
      failedId = id;
      failure = e;
    });
    q.hold('tr-4', (_) async => throw StateError('LEAVE_BALANCE_INSUFFICIENT'));
    await tester.pump(const Duration(seconds: 5));
    expect(failedId, 'tr-4');
    expect(failure, isA<StateError>());
    expect(q.isPending('tr-4'), isFalse);
    q.dispose();
  });

  testWidgets('flushAll sends immediately (leaving the screen)', (tester) async {
    final sent = <String>[];
    final q = NHeldCommitQueue();
    q.hold('x', (_) async => sent.add('x'));
    q.hold('y', (_) async => sent.add('y'));
    await q.flushAll();
    expect(sent, unorderedEquals(['x', 'y']));
    await tester.pump(const Duration(seconds: 6));
    expect(sent.length, 2, reason: 'the timers must not send a second time');
    q.dispose();
  });

  testWidgets('dispose flushes holding decisions', (tester) async {
    final sent = <String>[];
    final q = NHeldCommitQueue();
    q.hold('z', (_) async => sent.add('z'));
    q.dispose();
    await tester.pump();
    expect(sent, ['z']);
  });

  testWidgets('re-holding the same id restarts the window and sends once', (tester) async {
    final keys = <String>[];
    final q = NHeldCommitQueue();
    q.hold('r', (k) async => keys.add(k));
    await tester.pump(const Duration(seconds: 3));
    q.hold('r', (k) async => keys.add(k));
    await tester.pump(const Duration(seconds: 3));
    expect(keys, isEmpty);
    await tester.pump(const Duration(seconds: 3));
    expect(keys.length, 1);
    q.dispose();
  });
}
