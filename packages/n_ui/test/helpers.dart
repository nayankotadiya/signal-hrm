import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:n_ui/n_ui.dart';

/// Pumps [child] inside a themed app with the toast host and a breakpoint scope.
Future<void> pumpN(
  WidgetTester tester,
  Widget child, {
  NPreferences prefs = const NPreferences(),
  Brightness brightness = Brightness.light,
  Size size = const Size(1280, 800),
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: NTheme.build(prefs, brightness),
      home: Directionality(
        textDirection: direction,
        child: NToastHost(
          child: NBreakpointBuilder(
            builder: (context, bp) => Scaffold(
              backgroundColor: Colors.transparent,
              body: Center(child: child),
            ),
          ),
        ),
      ),
    ),
  );
}
