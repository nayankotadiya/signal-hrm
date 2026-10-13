import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:n_ui/n_ui.dart';

import 'helpers.dart';

void main() {
  testWidgets('NDataTable: aligned table on desktop, label/value cards on mobile', (tester) async {
    Widget table() => const SizedBox(
          width: 900,
          child: NDataTable(
            columns: [NColumn('Name'), NColumn('Status')],
            rows: [
              [Text('Meera'), Text('Active')],
            ],
          ),
        );
    await pumpN(tester, table(), size: const Size(1280, 800));
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Meera'), findsOneWidget);

    await pumpN(tester, const SingleChildScrollView(child: NDataTable(columns: [NColumn('Name'), NColumn('Status')], rows: [[Text('Meera'), Text('Active')]])), size: const Size(375, 800));
    await tester.pumpAndSettle();
    expect(find.text('Meera'), findsOneWidget);
    expect(find.text('Status'), findsOneWidget); // label shown next to the value on the card
    expect(tester.takeException(), isNull);
  });

  testWidgets('NEmptyState offers the next step', (tester) async {
    var tapped = false;
    await pumpN(tester, NEmptyState(title: 'No tasks', message: 'Create one', actionLabel: 'New task', onAction: () => tapped = true));
    await tester.tap(find.text('New task'));
    expect(tapped, isTrue);
  });

  testWidgets('NErrorState shows the reference and retries', (tester) async {
    var retried = 0;
    await pumpN(tester, NErrorState(message: 'Server unavailable', correlationId: 'abc-123', onRetry: () => retried++));
    expect(find.textContaining('abc-123'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('showNConfirm with a required reason keeps Confirm disabled until a reason is typed', (tester) async {
    NConfirmResult? result;
    await pumpN(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showNConfirm(context, title: 'Decline?', message: 'Tell them why.', confirmLabel: 'Decline', reasonLabel: 'Reason'),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    expect(result, isNull, reason: 'disabled without a reason');
    await tester.enterText(find.byType(TextFormField), 'Busy week');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    expect(result?.confirmed, isTrue);
    expect(result?.reason, 'Busy week');
  });

  testWidgets('charts expose their values to screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpN(tester, const SizedBox(width: 400, child: NBars(semanticLabel: 'Leads', data: [NDatum('New', 4), NDatum('Won', 2)])));
    expect(find.bySemanticsLabel(RegExp('Leads.*New: 4.*Won: 2')), findsOneWidget);
    await pumpN(tester, const NDonut(semanticLabel: 'Spend', data: [NDatum('Food', 0)]));
    expect(find.text('No data yet'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('NSelect shows options and reports the chosen value', (tester) async {
    String? v;
    await pumpN(tester, SizedBox(width: 300, child: StatefulBuilder(builder: (context, set) => NSelect<String>(label: 'Type', value: v, options: const [NOption('a', 'Alpha'), NOption('b', 'Beta')], onChanged: (x) => set(() => v = x)))));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Beta').last);
    await tester.pumpAndSettle();
    expect(v, 'b');
  });

  testWidgets('NMonthCalendar marks days and starts the week on Monday', (tester) async {
    await pumpN(tester, SizedBox(width: 380, child: NMonthCalendar(month: DateTime(2026, 10), onMonthChanged: (_) {}, marks: const {'2026-10-12': [NCalendarMark(color: Colors.green, label: 'Present')]})));
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('Mon'), findsOneWidget);
    expect(find.text('31'), findsOneWidget);
  });

  testWidgets('NKanban offers a keyboard-accessible Move to menu', (tester) async {
    String? moved;
    await pumpN(
      tester,
      SizedBox(
        width: 1000,
        height: 600,
        child: NKanban<String>(
          columns: const [NKanbanColumn(id: 'todo', title: 'To do', items: ['Write script']), NKanbanColumn(id: 'done', title: 'Done', items: [])],
          itemId: (s) => s,
          itemBuilder: (context, item, menu) => Row(children: [Expanded(child: Text(item)), menu]),
          onMove: (item, to) => moved = '$item→$to',
        ),
      ),
    );
    await tester.tap(find.byTooltip('Move to'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to Done'));
    await tester.pumpAndSettle();
    expect(moved, 'Write script→done');
  });
}
