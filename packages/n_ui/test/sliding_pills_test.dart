import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:n_ui/n_ui.dart';

import 'helpers.dart';

const _items = [NPillItem(label: 'Today'), NPillItem(label: 'Week'), NPillItem(label: 'Month')];

Finder get _indicator => find.byKey(const ValueKey('n-sliding-pills-indicator'));

/// The pill container for a label (nearest Container above the label text).
Rect _labelRect(WidgetTester tester, String label) =>
    tester.getRect(find.ancestor(of: find.text(label), matching: find.byType(Container)).first);

class _Host extends StatefulWidget {
  const _Host({this.items = _items, this.expand = false, this.width});
  final List<NPillItem> items;
  final bool expand;
  final double? width;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int selected = 0;
  void update(VoidCallback fn) => setState(fn);
  @override
  Widget build(BuildContext context) {
    final pills = NSlidingPills(
      items: widget.items,
      selectedIndex: selected,
      expand: widget.expand,
      semanticLabel: 'Period',
      onChanged: (i) => setState(() => selected = i),
    );
    return widget.width == null ? pills : SizedBox(width: widget.width, child: pills);
  }
}

void main() {
  testWidgets('first layout places the indicator under the selected label without animating', (tester) async {
    await pumpN(tester, const _Host());
    await tester.pump(); // post-frame measure
    await tester.pump();
    final ind = tester.getRect(_indicator);
    final today = _labelRect(tester, 'Today');
    expect(ind.left, closeTo(today.left, 0.5));
    expect(ind.width, closeTo(today.width, 0.5));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('the indicator travels to the tapped label', (tester) async {
    await pumpN(tester, const _Host());
    await tester.pumpAndSettle();
    final start = tester.getRect(_indicator).left;
    await tester.tap(find.text('Month'));
    await tester.pump(); // rebuild with the new selection, controller starts
    await tester.pump(); // first tick reports 0 elapsed
    await tester.pump(const Duration(milliseconds: 120));
    final mid = tester.getRect(_indicator).left;
    final month = _labelRect(tester, 'Month');
    expect(mid, greaterThan(start), reason: 'moving');
    expect(mid, lessThan(month.left), reason: 'not there yet');
    await tester.pumpAndSettle();
    expect(tester.getRect(_indicator).left, closeTo(month.left, 0.5));
    expect(tester.getRect(_indicator).width, closeTo(month.width, 0.5));
  });

  testWidgets('one indicator only: it is never recreated per tab', (tester) async {
    await pumpN(tester, const _Host());
    await tester.pumpAndSettle();
    expect(_indicator, findsOneWidget);
    await tester.tap(find.text('Week'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(_indicator, findsOneWidget);
  });

  testWidgets('reduced motion jumps the indicator instantly', (tester) async {
    await pumpN(tester, const _Host(), prefs: const NPreferences(reducedMotion: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Month'));
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(_indicator).left, closeTo(_labelRect(tester, 'Month').left, 0.5));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('re-measures when the available width changes (expand mode)', (tester) async {
    await pumpN(tester, const _Host(expand: true, width: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Week'));
    await tester.pumpAndSettle();
    final before = tester.getRect(_indicator).width;
    await pumpN(tester, const _Host(expand: true, width: 600));
    await tester.pumpAndSettle();
    final week = _labelRect(tester, 'Week');
    expect(tester.getRect(_indicator).width, greaterThan(before));
    expect(tester.getRect(_indicator).left, closeTo(week.left, 0.5));
  });

  testWidgets('re-measures when text scale changes', (tester) async {
    await pumpN(tester, const _Host());
    await tester.pumpAndSettle();
    final before = tester.getRect(_indicator).width;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(tester.getRect(_indicator).width, greaterThan(before));
    expect(tester.getRect(_indicator).width, closeTo(_labelRect(tester, 'Today').width, 0.5));
  });

  testWidgets('overflowing labels scroll inside the track and the active one scrolls to center', (tester) async {
    final many = [for (var i = 0; i < 12; i++) NPillItem(label: 'Section number $i')];
    await pumpN(tester, _Host(items: many, width: 360), size: const Size(390, 800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'no overflow errors');
    final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView)).controller!;
    expect(scroll.offset, 0);
    final state = tester.state<_HostState>(find.byType(_Host));
    state.update(() => state.selected = 8);
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    final active = _labelRect(tester, 'Section number 8');
    expect(active.center.dx, closeTo(viewport.center.dx, 2), reason: 'active label centered');
    expect(tester.getRect(_indicator).left, closeTo(active.left, 0.5));
  });

  testWidgets('screen readers hear "label, tab n of m" and the selected state', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpN(tester, const _Host());
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Week, tab 2 of 3'), findsOneWidget);
    final node = tester.getSemantics(find.bySemanticsLabel('Today, tab 1 of 3'));
    expect(node, isSemantics(isSelected: true));
    handle.dispose();
  });

  testWidgets('arrow keys, Home and End move the selection', (tester) async {
    await pumpN(tester, const _Host());
    await tester.pumpAndSettle();
    final state = tester.state<_HostState>(find.byType(_Host));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // focus lands on the selected item
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(state.selected, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(state.selected, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pumpAndSettle();
    expect(state.selected, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // wraps
    await tester.pumpAndSettle();
    expect(state.selected, 2);
  });

  testWidgets('RTL: arrow right moves toward the start', (tester) async {
    await pumpN(tester, const _Host(), direction: TextDirection.rtl);
    await tester.pumpAndSettle();
    final state = tester.state<_HostState>(find.byType(_Host));
    state.update(() => state.selected = 1);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(state.selected, 0);
    expect(tester.getRect(_indicator).left, closeTo(_labelRect(tester, 'Today').left, 0.5));
  });

  testWidgets('follows a linked PageView while swiping', (tester) async {
    final pc = PageController();
    addTearDown(pc.dispose);
    var selected = 0;
    await pumpN(
      tester,
      StatefulBuilder(
        builder: (context, setState) => SizedBox(
          width: 400,
          height: 400,
          child: Column(children: [
            NSlidingPills(
              items: _items,
              selectedIndex: selected,
              pageController: pc,
              onChanged: (i) {
                setState(() => selected = i);
                pc.animateToPage(i, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
              },
            ),
            Expanded(
              child: PageView(
                controller: pc,
                onPageChanged: (i) => setState(() => selected = i),
                children: const [Text('A'), Text('B'), Text('C')],
              ),
            ),
          ]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final today = _labelRect(tester, 'Today');
    final week = _labelRect(tester, 'Week');
    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await gesture.moveBy(const Offset(-100, 0)); // a quarter of the way to page 2
    await tester.pump();
    final left = tester.getRect(_indicator).left;
    expect(left, greaterThan(today.left + 1));
    expect(left, lessThan(week.left));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(_indicator).left, closeTo(today.left, 0.5), reason: 'snapped back to page 1');
  });
}
