# n_ui

**N UI — Defined & Developed by Nayan.** The Signal HRM design system for Flutter.

```dart
import 'package:n_ui/n_ui.dart';

MaterialApp(
  theme: NTheme.build(prefs, Brightness.light),
  darkTheme: NTheme.build(prefs, Brightness.dark),
  builder: (context, child) => NBreakpointBuilder(
    builder: (context, bp) => NToastHost(child: child!),
  ),
);

final t = NTokens.of(context);   // colors, radii, spacing, durations, curves, type
```

Rules: widgets read `NTokens`, never hardcoded values; `NSlidingPills` is the only tab control;
one `NDarkActionCard` per screen; health uses exactly four states (`NHealth`).

Tests: `flutter test` · goldens: `flutter test test_goldens --update-goldens` (first run).
Outfit font: SIL Open Font License, see `assets/fonts/OFL.txt`.
