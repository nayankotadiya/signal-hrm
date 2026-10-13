// Golden tests for N UI components. Baselines must be recorded on your machine first:
//   flutter test test_goldens --update-goldens
// then commit test_goldens/goldens/*.png and run `flutter test test_goldens` in CI.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:n_ui/n_ui.dart';

Future<void> _loadOutfit() async {
  final loader = FontLoader(NType.family);
  for (final w in ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) {
    final bytes = File('assets/fonts/Outfit-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

Widget _sample() => Builder(builder: (context) {
      final t = NTokens.of(context);
      return NPageBackground(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: NPanel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const NHeroRow(
                greeting: NGreeting(lead: 'Welcome in,', bold: 'Priya'),
                meters: [
                  NMeter(label: 'Present', valueText: '42', fraction: 0.7, highlighted: true),
                  NMeter(label: 'Remote', valueText: '6', fraction: 0.2),
                  NMeter(label: 'On leave', valueText: '3', fraction: 0.15),
                  NMeter(label: 'Late', valueText: '2', fraction: 0.12),
                ],
                kpis: [
                  NKpi(label: 'Headcount', value: 53),
                  NKpi(label: 'Pending', value: 7),
                  NKpi(label: 'Overdue', value: 2),
                ],
              ),
              SizedBox(height: t.gap),
              NSlidingPills(
                items: const [NPillItem(label: 'Today'), NPillItem(label: 'Week'), NPillItem(label: 'Month')],
                selectedIndex: 1,
                onChanged: (_) {},
              ),
              SizedBox(height: t.gap),
              const Wrap(spacing: 8, runSpacing: 8, children: [
                NStatusChip.health(NHealth.healthy),
                NStatusChip.health(NHealth.degraded),
                NStatusChip.health(NHealth.unavailable),
                NStatusChip.health(NHealth.unknown),
              ]),
              SizedBox(height: t.gap + 9),
              NDarkActionCard.check(
                title: 'My tasks',
                items: const [
                  NActionItem(id: '1', title: 'Upload PAN card', done: true),
                  NActionItem(id: '2', title: 'Read leave policy'),
                ],
                onToggle: (_, __) {},
              ),
            ]),
          ),
        ),
      );
    });

void main() {
  setUpAll(_loadOutfit);

  for (final style in NThemeStyle.values) {
    for (final brightness in Brightness.values) {
      for (final size in const [Size(390, 900), Size(1280, 800)]) {
        final name = '${style.name}_${brightness.name}_${size.width.toInt()}';
        testWidgets('components $name', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: NTheme.build(NPreferences(themeStyle: style, reducedMotion: true), brightness),
            home: NToastHost(child: NBreakpointBuilder(builder: (_, __) => _sample())),
          ));
          await tester.pumpAndSettle();
          await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
        });
      }
    }
  }
}
