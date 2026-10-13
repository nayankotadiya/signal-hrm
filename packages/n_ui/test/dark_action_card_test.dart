import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:n_ui/n_ui.dart';

import 'helpers.dart';

const _requests = [
  NActionItem(id: 'lr-1', title: 'Asha: casual leave', subtitle: 'Thu 15 Oct'),
  NActionItem(id: 'lr-2', title: 'Ravi: sick leave', subtitle: 'Today'),
];

void main() {
  testWidgets('approve: row leaves, toast offers Undo, request is sent after 5s with a key', (tester) async {
    final sent = <(String, NDecision, String)>[];
    await pumpN(
      tester,
      SizedBox(
        width: 380,
        child: NDarkActionCard.approve(
          title: 'Leave approvals',
          items: _requests,
          commit: (item, d, key) async => sent.add((item.id, d, key)),
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget); // badge
    await tester.tap(find.bySemanticsLabel('Approve Asha: casual leave'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Asha: casual leave'), findsNothing);
    expect(find.textContaining('Approved'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(sent, isEmpty, reason: 'held during the Undo window');
    await tester.pump(const Duration(seconds: 5));
    expect(sent.single.$1, 'lr-1');
    expect(sent.single.$2, NDecision.approve);
    expect(sent.single.$3, hasLength(36));
    await tester.pumpAndSettle();
  });

  testWidgets('Undo brings the row back and nothing is sent', (tester) async {
    var calls = 0;
    await pumpN(
      tester,
      SizedBox(
        width: 380,
        child: NDarkActionCard.approve(title: 'Leave approvals', items: _requests, commit: (_, __, ___) async => calls++),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Decline Ravi: sick leave'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ravi: sick leave'), findsNothing);
    await tester.pumpAndSettle(); // let the toast finish sliding in (well inside the 5s window)
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('Ravi: sick leave'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(calls, 0);
  });

  testWidgets('a rejected decision returns the row with the explanation', (tester) async {
    await pumpN(
      tester,
      SizedBox(
        width: 380,
        child: NDarkActionCard.approve(
          title: 'Leave approvals',
          items: _requests,
          commit: (_, __, ___) async => throw Exception('conflict'),
          describeError: (_) => 'Already decided by HR. Refresh to see the latest status.',
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Approve Asha: casual leave'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Asha: casual leave'), findsOneWidget);
    expect(find.text('Already decided by HR. Refresh to see the latest status.'), findsOneWidget);
  });

  testWidgets('decisions that need a comment skip held commit', (tester) async {
    NDecision? asked;
    var calls = 0;
    await pumpN(
      tester,
      SizedBox(
        width: 380,
        child: NDarkActionCard.approve(
          title: 'Leave approvals',
          items: _requests,
          commit: (_, __, ___) async => calls++,
          needsConfirmation: (_, d) => d == NDecision.decline,
          onConfirmRequired: (_, d) => asked = d,
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Decline Asha: casual leave'));
    await tester.pumpAndSettle();
    expect(asked, NDecision.decline);
    expect(find.text('Asha: casual leave'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(calls, 0);
  });

  testWidgets('check mode toggles optimistically and shows progress', (tester) async {
    final toggled = <String, bool>{};
    await pumpN(
      tester,
      SizedBox(
        width: 380,
        child: NDarkActionCard.check(
          title: 'My tasks',
          items: const [
            NActionItem(id: 't1', title: 'Upload PAN card', done: true),
            NActionItem(id: 't2', title: 'Read leave policy'),
          ],
          onToggle: (item, done) => toggled[item.id] = done,
        ),
      ),
    );
    expect(find.text('1/2 done · 50%'), findsOneWidget);
    await tester.tap(find.text('Read leave policy'));
    await tester.pumpAndSettle();
    expect(toggled, {'t2': true});
    expect(find.text('2/2 done · 100%'), findsOneWidget);
  });
}
