import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:n_ui/n_ui.dart';

import 'helpers.dart';

class _Probe extends StatefulWidget {
  const _Probe(this.name);
  final String name;
  static final inits = <String, int>{};
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.inits.update(widget.name, (v) => v + 1, ifAbsent: () => 1);
  }

  @override
  Widget build(BuildContext context) => Text('View ${widget.name}');
}

class _Switch extends StatefulWidget {
  const _Switch({this.indexed = false});
  final bool indexed;
  @override
  State<_Switch> createState() => _SwitchState();
}

class _SwitchState extends State<_Switch> {
  int index = 0;
  void update(VoidCallback fn) => setState(fn);
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 300,
        height: 200,
        child: widget.indexed
            ? NViewSwitcher.indexed(index: index, children: const [_Probe('0'), _Probe('1'), _Probe('2')])
            : NViewSwitcher(index: index, child: _Probe('$index')),
      );
}

void main() {
  setUp(_Probe.inits.clear);

  testWidgets('waits for the exit before mounting the new view', (tester) async {
    await pumpN(tester, const _Switch());
    final s = tester.state<_SwitchState>(find.byType(_Switch));
    s.update(() => s.index = 1);
    await tester.pump();
    await tester.pump(); // first tick of a new ticker reports 0 elapsed
    await tester.pump(const Duration(milliseconds: 120)); // inside the 220ms exit
    expect(find.text('View 0'), findsOneWidget);
    expect(find.text('View 1'), findsNothing);
    final exitingX = tester.getTopLeft(find.text('View 0')).dx;
    await tester.pump(const Duration(milliseconds: 150)); // exit done, enter started
    expect(find.text('View 0'), findsNothing);
    expect(find.text('View 1'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(exitingX, isNot(equals(tester.getTopLeft(find.text('View 1')).dx)));
  });

  testWidgets('forward exits to the left and enters from the right', (tester) async {
    await pumpN(tester, const _Switch());
    final restX = tester.getTopLeft(find.text('View 0')).dx;
    final s = tester.state<_SwitchState>(find.byType(_Switch));
    s.update(() => s.index = 2);
    await tester.pump();
    await tester.pump(); // first tick of a new ticker reports 0 elapsed
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getTopLeft(find.text('View 0')).dx, lessThan(restX));
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getTopLeft(find.text('View 2')).dx, greaterThan(restX));
    await tester.pumpAndSettle();
  });

  testWidgets('going back reverses the direction', (tester) async {
    await pumpN(tester, const _Switch());
    final s = tester.state<_SwitchState>(find.byType(_Switch));
    s.update(() => s.index = 2);
    await tester.pumpAndSettle();
    final restX = tester.getTopLeft(find.text('View 2')).dx;
    s.update(() => s.index = 0);
    await tester.pump();
    await tester.pump(); // first tick of a new ticker reports 0 elapsed
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getTopLeft(find.text('View 2')).dx, greaterThan(restX));
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion swaps instantly', (tester) async {
    await pumpN(tester, const _Switch(), prefs: const NPreferences(reducedMotion: true));
    final s = tester.state<_SwitchState>(find.byType(_Switch));
    s.update(() => s.index = 1);
    await tester.pump();
    expect(find.text('View 1'), findsOneWidget);
    expect(find.text('View 0'), findsNothing);
  });

  testWidgets('indexed mode keeps visited views alive (state preserved)', (tester) async {
    await pumpN(tester, const _Switch(indexed: true));
    final s = tester.state<_SwitchState>(find.byType(_Switch));
    s.update(() => s.index = 1);
    await tester.pumpAndSettle();
    s.update(() => s.index = 0);
    await tester.pumpAndSettle();
    expect(_Probe.inits['0'], 1);
    expect(_Probe.inits['1'], 1);
    expect(_Probe.inits.containsKey('2'), isFalse, reason: 'unvisited views are not built');
  });

  testWidgets('the incoming view keeps its state when its entrance finishes', (tester) async {
    await pumpN(tester, const _Switch());
    final s = tester.state<_SwitchState>(find.byType(_Switch));
    s.update(() => s.index = 1);
    await tester.pumpAndSettle();
    expect(_Probe.inits['1'], 1);
  });
}
